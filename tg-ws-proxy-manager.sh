#!/data/data/com.termux/files/usr/bin/env bash
# tg-ws-proxy-manager.sh — менеджер Flowseal/tg-ws-proxy для Termux (Android)
# Документация: README.md и docs/ (установка, команды, конфиг, автозапуск, диагностика)

set -euo pipefail

readonly APP_NAME="tg-ws-proxy"
readonly SESSION_NAME="tgwsproxy"
readonly CONFIG_DIR="$HOME/.config/tg-ws-proxy"
readonly CONFIG_FILE="$CONFIG_DIR/tg-ws-proxy.conf"
readonly STATE_DIR="$HOME/.local/state/tg-ws-proxy"
readonly LOG_FILE="$STATE_DIR/proxy.log"
readonly NETINFO_PY="$STATE_DIR/netinfo.py"
readonly RUN_ARGS_FILE="$STATE_DIR/run.args"
# Маркер включённого резервного автозапуска: меню читает его, а не дёргает Termux:API
readonly JOB_MARK="$STATE_DIR/job.enabled"
# Любая команда Termux:API без установленного приложения ждёт ответа вечно
readonly API_TIMEOUT="6"

# Все числовые решения собраны здесь, а не размазаны по коду
readonly BOOT_JOB_ID="1443"          # id задачи в планировщике Android
readonly BOOT_JOB_PERIOD_MS="900005" # минимум Android — 15 мин; ровно 900000 часть прошивок отбрасывает
readonly BOOT_START_DELAY="15"       # пауза перед первым стартом после загрузки
readonly BOOT_RETRY_DELAY="20"       # пауза между повторными попытками
readonly START_WAIT="3"              # сколько ждём подъёма после tmux new-session
readonly TCP_TIMEOUT="3"             # таймаут проверки порта
readonly HTTP_TIMEOUT="12"           # таймаут HTTP-проверки домена

# Единый сокет tmux для всех точек входа (меню, Boot, JobScheduler, watchdog),
# иначе окружения разъедутся по разным сокетам и поднимется второй прокси. См. docs/autostart.md.
readonly TMUX_TMPDIR="${PREFIX:-/data/data/com.termux/files/usr}/tmp/tgws-sock"
export TMUX_TMPDIR
mkdir -p "$TMUX_TMPDIR" "${TMPDIR:-${PREFIX:-/tmp}/tmp}" 2>/dev/null || true

if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
	C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_CYAN=$'\033[1;36m'
	C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
	C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""; C_DIM=""; C_BOLD=""
fi

msg()  { printf '%s[*]%s %s\n' "$C_BLUE"   "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN"  "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[x]%s %s\n' "$C_RED"    "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s────────────────────────────────────────%s\n' "$C_DIM" "$C_RESET"; }
ask()  { local a; printf '%s [y/N]: ' "$1"; read -r a || true; case "$a" in y|Y|yes|да|Да) return 0 ;; *) return 1 ;; esac; }

# Очистка экрана без падения при TERM=dumb
cls() { clear 2>/dev/null || true; }

# Права на файлы с secret
chmod600() { chmod 600 "$1" 2>/dev/null || true; }

# Шебанг для генерируемых скриптов
# Генерация вспомогательных скриптов: write_script <файл> [права] <<'EOS'
# Шаблон читается со stdin как обычный bash-текст, подставляются метки @@ИМЯ@@.
# Так видно, какой именно скрипт получится, и не нужно тройное экранирование.
write_script() {
	local target="$1" mode="${2:-700}" tmp pfx self
	pfx="${PREFIX:-/data/data/com.termux/files/usr}"
	self="$(self_path)"
	mkdir -p "$(dirname "$target")"
	tmp="$(mk_tmp)" || return 1
	# в замене sed спецсимволы \&| ломают подстановку — экранируем
	esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }
	{
		printf '#!%s/bin/bash\n' "$pfx"
		printf '# Автогенерация %s — ручные правки затрутся\n' "$(date '+%Y-%m-%d %H:%M:%S')"
		sed -e "s|@@PREFIX@@|$(esc "$pfx")|g" \
			-e "s|@@HOME@@|$(esc "$HOME")|g" \
			-e "s|@@SELF@@|$(esc "$self")|g" \
			-e "s|@@SESSION@@|$(esc "$SESSION_NAME")|g" \
			-e "s|@@STATE@@|$(esc "$STATE_DIR")|g" \
			-e "s|@@BOOTLOG@@|$(esc "$STATE_DIR/boot.log")|g" \
			-e "s|@@APPDIR@@|$(esc "${APP_DIR:-$HOME/tg-ws-proxy}")|g" \
			-e "s|@@ARGSFILE@@|$(esc "$RUN_ARGS_FILE")|g" \
			-e "s|@@PYTHON@@|$(esc "$(python_bin)")|g" \
			-e "s|@@PORT@@|${PORT:-1443}|g" \
			-e "s|@@INTERVAL@@|${WATCHDOG_INTERVAL:-120}|g" \
			-e "s|@@WDLOG@@|$(esc "${WATCHDOG_LOG:-$STATE_DIR/watchdog.log}")|g" \
			-e "s|@@DELAY@@|$BOOT_START_DELAY|g" \
			-e "s|@@RETRY@@|$BOOT_RETRY_DELAY|g" \
			-e "s|@@RESTARTH@@|${RESTART_EVERY_H:-0}|g" \
			-e "s|@@WDMAXKB@@|512|g" \
			-e "s|@@TMUXTMPDIR@@|$(esc "$TMUX_TMPDIR")|g" \
			-e "s|@@STOPMARK@@|$(esc "${STOP_MARK:-$STATE_DIR/manual_stop}")|g"
	} > "$tmp"
	# сломанный скрипт не должен доезжать до боевого файла
	bash -n "$tmp" 2>/dev/null || { err "Сгенерированный скрипт $target с ошибкой"; return 1; }
	mv "$tmp" "$target"
	chmod "$mode" "$target" 2>/dev/null || true
	return 0
}

# Гарантированная установка пакета: ensure_pkg <команда> <пакет...>
ensure_pkg() {
	local cmd="$1"; shift
	command -v "$cmd" >/dev/null 2>&1 && return 0
	local pkgname
	for pkgname in "$@"; do
		msg "Ставлю $pkgname..."
		pkg install -y "$pkgname" >/dev/null 2>&1 || true
		command -v "$cmd" >/dev/null 2>&1 && { ok "$pkgname установлен"; return 0; }
	done
	warn "С первого раза не взлетело — обновляю списки пакетов"
	pkg update -y 2>&1 | tail -n 3 || true
	for pkgname in "$@"; do
		msg "Повторная попытка: $pkgname"
		pkg install -y "$pkgname" 2>&1 | tail -n 5 || true
		command -v "$cmd" >/dev/null 2>&1 && { ok "$pkgname установлен"; return 0; }
	done
	return 1
}

# hex из /proc/net/tcp —> точечный IP (включая IPv4-mapped IPv6)
hex_ip() {
	local h="$1" t
	case "${#h}" in
		8)  t="$h" ;;
		32) t="${h:24:8}" ;;
		*)  printf '%s' "$h"; return 0 ;;
	esac
	printf '%d.%d.%d.%d' "0x${t:6:2}" "0x${t:4:2}" "0x${t:2:2}" "0x${t:0:2}"
}

# IP, которые клиентами быть не могут: мы сами, Telegram, служебные
is_client_ip() {
	local ip="$1" rule
	case "$ip" in
		127.*|0.0.0.0|255.255.255.255|*.0) return 1 ;;
		149.154.*|91.108.*|95.161.*|185.76.15*) return 1 ;;
	esac
	[ "$ip" = "${LAN_IP:-}" ] && return 1
	for rule in "${DC_IP_RULES[@]:-}"; do
		[ "$ip" = "${rule#*:}" ] && return 1
	done
	return 0
}

# Вытащить IP клиентов из текста (лог или буфер tmux)
extract_client_ips() {
	local ip
	grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' 2>/dev/null | while read -r ip; do
		is_client_ip "$ip" && printf '%s\n' "$ip"
	done
}

# Что видно в окне tmux — точно то же, что и глазами при attach
tmux_buffer() {
	is_running || return 1
	tmux capture-pane -p -J -S -5000 -t "$SESSION_NAME" 2>/dev/null || true
}

# Соединения напрямую из ядра — без ss и netstat
proc_peers() {
	local ph f loc rem st rest
	ph="$(printf '%04X' "$PORT")"
	for f in /proc/net/tcp /proc/net/tcp6; do
		[ -r "$f" ] || continue
		while read -r _ loc rem st rest; do
			[ "$st" = "01" ] || continue
			case "$loc" in *:"$ph") ;; *) continue ;; esac
			printf '%s:%d\n' "$(hex_ip "${rem%%:*}")" "0x${rem##*:}"
		done < "$f"
	done
}

# Проверка TCP-порта: nc если есть, иначе встроенный /dev/tcp
tcp_open() {
	local host="$1" port="$2" wait="${3:-3}"
	if command -v nc >/dev/null 2>&1; then
		nc -z -w "$wait" "$host" "$port" >/dev/null 2>&1
		return $?
	fi
	if (exec 3<>"/dev/tcp/$host/$port") 2>/dev/null; then
		exec 3>&- 3<&- || true
		return 0
	fi
	return 1
}

# --- Защита меню от вылетов ------------------------------------
# Любой пункт выполняется в подоболочке: exit/die внутри команды
# убивает только её, а не весь скрипт.
run_item() { ( "$@" ) || true; }

# --- временные файлы с автоуборкой ---
TMP_FILES=()
cleanup_tmp() {
	local f
	for f in "${TMP_FILES[@]:-}"; do
		[ -n "$f" ] && rm -f "$f"
	done
	return 0
}
trap cleanup_tmp EXIT
mk_tmp() {
	local t
	t="$(mktemp "${TMPDIR:-${PREFIX:-/tmp}/tmp}/tgws.XXXXXX" 2>/dev/null || mktemp)" || return 1
	[ -n "$t" ] || return 1
	TMP_FILES+=("$t")
	printf '%s' "$t"
}

# --- вызов внешней команды с жёстким таймаутом (Termux:API без APK висит вечно) ---
# Код 124 = нет ответа. См. docs/troubleshooting.md.
run_timeout() {
	local secs="$1"; shift
	if command -v timeout >/dev/null 2>&1; then
		timeout -k 2 "$secs" "$@"
		return $?
	fi
	# timeout не установлен (нет coreutils) — сторожим своими руками
	"$@" &
	local pid=$! i=0
	while kill -0 "$pid" 2>/dev/null; do
		[ "$i" -ge "$secs" ] && { kill -9 "$pid" 2>/dev/null || true; wait "$pid" 2>/dev/null || true; return 124; }
		sleep 1; i=$((i+1))
	done
	wait "$pid" 2>/dev/null
}

# Команда Termux:API: есть в PATH и отвечает за отведённое время
api_call() {
	local cmd="$1"; shift
	command -v "$cmd" >/dev/null 2>&1 || return 127
	run_timeout "$API_TIMEOUT" "$cmd" "$@"
}

# --- wake-lock: без него Android усыпит прокси после блокировки экрана ---
wake_lock_on() {
	[ "${WAKE_LOCK:-1}" = "1" ] || return 0
	if command -v termux-wake-lock >/dev/null 2>&1; then
		local rc=0
		api_call termux-wake-lock >/dev/null 2>&1 || rc=$?
		case "$rc" in
			0)   ok "Wake-lock включён — система не усыпит прокси" ;;
			124) warn "Termux:API не ответил за ${API_TIMEOUT}с — пропускаю wake-lock"
			     msg "Нужно приложение Termux:API из F-Droid, а не только pkg install termux-api" ;;
			*)   warn "Wake-lock не включился" ;;
		esac
	else
		warn "Нет termux-wake-lock (pkg install termux-tools) — прокси может уснуть"
	fi
}
wake_lock_off() {
	api_call termux-wake-unlock >/dev/null 2>&1 || true
}

# Фон чаще убивает батарейный менеджер прошивки, а не сон (подробности — docs/troubleshooting.md).
check_battery_optimization() {
	command -v am >/dev/null 2>&1 || { warn "Нет 'am' — открой настройки батареи вручную"; return 1; }
	msg "Открываю настройки батареи Termux..."
	msg "Выбери «Без ограничений» / «Не оптимизировать» (формулировка зависит от прошивки)"
	if run_timeout "$API_TIMEOUT" am start -a android.settings.APPLICATION_DETAILS_SETTINGS \
		-d package:com.termux >/dev/null 2>&1; then
		ok "Настройки открыты"
	else
		warn "Не смог открыть автоматически — сделай вручную:"
		printf '  Настройки телефона → Приложения → Termux → Батарея → без ограничений\n'
	fi
	printf '  На части прошивок (Xiaomi/Huawei/Honor/Oppo/Vivo/Samsung) это отдельная\n'
	printf '  настройка "Автозапуск" / "Работа в фоне" — она обычно рядом, тоже включи.\n'
	printf '  То же самое стоит сделать и для Termux:Boot / Termux:API, если ставил их отдельно.\n'
	return 0
}

# Памятка MIUI: из shell не применяется, только руками (полный текст — docs/troubleshooting.md).
show_miui_help() {
	hr
	printf '%sMIUI 12.5: как не дать выгрузить Termux%s\n' "$C_BOLD" "$C_RESET"
	hr
	printf '  1) Настройки → Приложения → Все приложения → Termux → Батарея → Нет ограничений\n'
	printf '  2) Настройки → Приложения → Разрешения → Автозапуск → включить Termux\n'
	printf '  3) Недавние приложения → удержать Termux → нажать значок замка\n'
	printf '  4) Безопасность → Ускорение → Настройки → Закреплённые приложения → включить Termux\n'
	printf '  5) Повтори пункты 1–2 для Termux:Boot и Termux:API, если они установлены\n'
	printf '  6) Не скрывай постоянное уведомление Termux и не запускай Очистку памяти\n'
	printf '  7) В Termux выполни: tgws watchdog-on и tgws autostart-on\n'
	hr
	return 0
}

# Ctrl+C внутри меню — возврат в меню, а не выход в Termux
menu_guard_on()  { trap 'printf "\n"' INT; }
menu_guard_off() { trap - INT; }

pause_menu() { printf '\nEnter — далее...'; read -r _ || true; printf '\n'; }

# Чтение пункта меню. Код 1 = EOF: без проверки меню крутится вечно.
read_choice() {
	local __val
	if ! IFS= read -r __val; then
		printf '\n'
		return 1
	fi
	printf -v "$1" '%s' "$__val"
	return 0
}

check_termux() {
	[ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-/nope}/bin" ] || die "Это не Termux: \$PREFIX не задан."
	command -v pkg >/dev/null 2>&1 || die "Нет pkg. Скрипт рассчитан на Termux."
}

# Доступ к памяти телефона (нужен, если скрипт/файлы лежат в ~/storage)
ensure_storage() {
	[ -d "$HOME/storage" ] && return 0
	warn "Нет доступа к памяти телефона (~/storage отсутствует)."
	if ask "Выполнить termux-setup-storage?"; then
		if command -v termux-setup-storage >/dev/null 2>&1; then
			termux-setup-storage; sleep 2
			[ -d "$HOME/storage" ] && ok "Доступ выдан" || warn "Разрешение не получено"
		else
			warn "termux-setup-storage недоступен"
		fi
	fi
}

# ============================================================
#  Конфиг
# ============================================================

# Единственный источник дефолтов: новый конфиг + добивка старых. Все ключи — docs/config.md.
declare -A CONFIG_DEFAULTS=(
	[REPO_URL]="https://github.com/Flowseal/tg-ws-proxy.git"
		[REPO_BRANCH]="v1.10.2" # Фиксируем версию для защиты от supply chain attack
	[USE_VENV]="0"
	[BIND_MODE]="local"
	[PORT]="1443"
	[SECRET]=""
	[LAN_IP]=""
	[NET_IFACE]=""
	[CF_PROXY_ENABLED]="1"
	[FAKE_TLS_DOMAIN]=""
	[FORCE_TEST_DC]="0"
	[PROXY_PROTOCOL]="0"
	[WAKE_LOCK]="1"
	[CLIPBOARD_COPY]="1"
	[WATCHDOG_ENABLED]="0"
	[WATCHDOG_INTERVAL]="300"
	[RESTART_EVERY_H]="0"
	[VERBOSE]="0"
	[BUF_KB]="256"
	[POOL_SIZE]="4"
	[LOG_MAX_MB]="5"
	[LOG_BACKUPS]="1"
	[EXTRA_ARGS]=""
)

# Дефолтные маршруты на ДЦ Telegram (массивам нужен свой список)
readonly DEFAULT_DC_IPS=("2:149.154.167.220" "4:149.154.167.220")

write_default_config() {
	mkdir -p "$CONFIG_DIR"
	local tmpl key dc="" rule
	tmpl="$(cat <<'EOF'
# ============================================================
#  tg-ws-proxy — конфиг для Termux
#  Параметры соответствуют флагам proxy/tg_ws_proxy.py
# ============================================================

REPO_URL="@@REPO_URL@@"
REPO_BRANCH="@@REPO_BRANCH@@"
APP_DIR="$HOME/tg-ws-proxy"

# 1 = запускать в venv, 0 = системный python (ядру нужна только cryptography)
USE_VENV="@@USE_VENV@@"

# ---------- Сеть ----------
# local = 127.0.0.1 (только этот телефон)
# lan   = 0.0.0.0 (Wi-Fi/LAN или точка доступа)
BIND_MODE="@@BIND_MODE@@"
PORT="@@PORT@@"

# MTProto secret: РОВНО 32 hex-символа. Пусто -> сгенерируется сам.
SECRET="@@SECRET@@"

# IP для ссылки. Пусто = автоопределение.
# Для точки доступа обычно нужен IP интерфейса ap0 (192.168.x.1).
LAN_IP="@@LAN_IP@@"
# Предпочитаемый интерфейс: wlan0, ap0, rmnet_data0... Пусто = авто.
NET_IFACE="@@NET_IFACE@@"

# ---------- Датацентры Telegram (--dc-ip DC:IP) ----------
DC_IP_RULES=(
@@DC_IP_RULES@@)

# ---------- Cloudflare ----------
# 1 = CF-fallback включен, 0 = передать --no-cfproxy
CF_PROXY_ENABLED="@@CF_PROXY_ENABLED@@"

# Свои CF-домены (--cfproxy-domain, флаг повторяемый).
# Пусто = встроенный пул доменов ядра.
CF_CUSTOM_DOMAINS=(
)

# Cloudflare Worker домены (--cfproxy-worker-domain, флаг повторяемый).
# Пробуются РАНЬШЕ остальных способов fallback.
CF_WORKER_DOMAINS=(
)

# ---------- Маскировка и совместимость ----------
# Fake TLS: SNI-домен (--fake-tls-domain), напр. www.cloudflare.com
# При включении ссылка выдаётся с ee-secret вместо dd.
FAKE_TLS_DOMAIN="@@FAKE_TLS_DOMAIN@@"

# 1 = --force-test-dc (ТЕСТОВЫЕ ДЦ Telegram; обычным клиентам НЕ нужно)
FORCE_TEST_DC="@@FORCE_TEST_DC@@"

# 1 = --proxy-protocol (только если стоишь за nginx/haproxy)
PROXY_PROTOCOL="@@PROXY_PROTOCOL@@"

# ---------- Android ----------
# 1 = брать termux-wake-lock при старте (иначе система усыпит прокси)
WAKE_LOCK="@@WAKE_LOCK@@"

# 1 = копировать ссылку в буфер обмена (нужен Termux:API)
CLIPBOARD_COPY="@@CLIPBOARD_COPY@@"

# ---------- Watchdog ----------
# 1 = фоновая проверка и автоперезапуск упавшего прокси
WATCHDOG_ENABLED="@@WATCHDOG_ENABLED@@"
# интервал проверки в секундах
WATCHDOG_INTERVAL="@@WATCHDOG_INTERVAL@@"
# плановый перезапуск прокси каждые N часов (0 = не перезапускать)
RESTART_EVERY_H="@@RESTART_EVERY_H@@"

# ---------- Логи и производительность ----------
VERBOSE="@@VERBOSE@@"          # -v
BUF_KB="@@BUF_KB@@"         # --buf-kb
POOL_SIZE="@@POOL_SIZE@@"        # --pool-size
LOG_MAX_MB="@@LOG_MAX_MB@@"       # --log-max-mb
LOG_BACKUPS="@@LOG_BACKUPS@@"      # --log-backups

# Дополнительные флаги. Сверяй через пункт "Показать --help проекта".
EXTRA_ARGS="@@EXTRA_ARGS@@"
EOF
	)"

	for rule in "${DEFAULT_DC_IPS[@]}"; do dc+=$'\t'"\"$rule\""$'\n'; done
	tmpl="${tmpl//@@DC_IP_RULES@@/$dc}"
	for key in "${!CONFIG_DEFAULTS[@]}"; do
		tmpl="${tmpl//@@$key@@/${CONFIG_DEFAULTS[$key]}}"
	done

	printf '%s\n' "$tmpl" > "$CONFIG_FILE"
	chmod600 "$CONFIG_FILE"
	ok "Создан конфиг: $CONFIG_FILE"
}

# Производные пути: вычисляются из конфига, в самом конфиге не хранятся
derive_paths() {
	VENV_DIR="$APP_DIR/.venv"
	RUN_SCRIPT="$STATE_DIR/run.sh"
	BOOT_DIR="$HOME/.termux/boot"
	BOOT_SCRIPT="$BOOT_DIR/10-tg-ws-proxy.sh"
	BOOT_JOB_SCRIPT="$STATE_DIR/boot-job.sh"
	BOOT_LOG="$STATE_DIR/boot.log"
	WATCHDOG_SCRIPT="$STATE_DIR/watchdog.sh"
	WATCHDOG_LOG="$STATE_DIR/watchdog.log"
	WATCHDOG_SESSION="${SESSION_NAME}dog"
	PROFILE_DIR="$CONFIG_DIR/profiles"
	PROFILE_MARK="$CONFIG_DIR/current_profile"
	UPDATE_STATE="$STATE_DIR/update_state"
	# Флаг плановой остановки для pane-died-хука (см. docs/autostart.md).
	STOP_MARK="$STATE_DIR/manual_stop"
	PANE_DIED_SCRIPT="$STATE_DIR/pane-died.sh"
}

# Конфиг читается один раз за команду; load_config force — перечитать.
CONFIG_LOADED=0
load_config() {
	[ "${1:-}" = "force" ] && CONFIG_LOADED=0
	[ "$CONFIG_LOADED" = "1" ] && return 0

	[ -f "$CONFIG_FILE" ] || write_default_config
	# shellcheck disable=SC1090
	source "$CONFIG_FILE" || { err "Ошибка в конфиге: $CONFIG_FILE"; return 1; }

	# чего нет в старом конфиге — берётся из дефолтов
	local key
	for key in "${!CONFIG_DEFAULTS[@]}"; do
		[ -n "${!key+x}" ] || printf -v "$key" '%s' "${CONFIG_DEFAULTS[$key]}"
	done
	# одноразовая миграция пина ядра на новый благословлённый тег
	if [ "${REPO_BRANCH:-}" = "v1.10.0" ]; then
		set_config_value REPO_BRANCH "${CONFIG_DEFAULTS[REPO_BRANCH]}"
	fi
	APP_DIR="${APP_DIR:-$HOME/tg-ws-proxy}"

	# Совместимость со старым конфигом (одиночные домены)
	declare -p CF_CUSTOM_DOMAINS >/dev/null 2>&1 || CF_CUSTOM_DOMAINS=()
	declare -p CF_WORKER_DOMAINS >/dev/null 2>&1 || CF_WORKER_DOMAINS=()
	declare -p DC_IP_RULES       >/dev/null 2>&1 || DC_IP_RULES=("${DEFAULT_DC_IPS[@]}")
	if [ -n "${CF_CUSTOM_DOMAIN:-}" ] && [ "${#CF_CUSTOM_DOMAINS[@]}" -eq 0 ]; then
		CF_CUSTOM_DOMAINS=("$CF_CUSTOM_DOMAIN")
	fi
	if [ -n "${CF_WORKER_DOMAIN:-}" ] && [ "${#CF_WORKER_DOMAINS[@]}" -eq 0 ]; then
		CF_WORKER_DOMAINS=("$CF_WORKER_DOMAIN")
	fi

	derive_paths
	mkdir -p "$STATE_DIR"
	# в конфиге лежит secret — чужим не читать
	chmod600 "$CONFIG_FILE"
	CONFIG_LOADED=1
	return 0
}

# Значение попадёт в source-able конфиг в двойных кавычках — экранируем
cfg_escape() {
	local s="$1"
	s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$/\\\$}"; s="${s//\`/\\\`}"
	printf '%s' "$s"
}

set_config_value() {
	local key="$1" value="$2" tmp esc
	[ -f "$CONFIG_FILE" ] || write_default_config
	esc="$(cfg_escape "$value")"
	if grep -qE "^${key}=" "$CONFIG_FILE"; then
		tmp="$(mk_tmp)" || return 1
		awk -v k="$key" -v v="$esc" '$0 ~ "^" k "=" { printf "%s=\"%s\"\n", k, v; next } { print }' \
			"$CONFIG_FILE" > "$tmp" || return 1
		mv "$tmp" "$CONFIG_FILE" || return 1
	else
		printf '%s="%s"\n' "$key" "$esc" >> "$CONFIG_FILE"
	fi
	load_config force
}

# Перезапись bash-массива в конфиге: set_array_value ИМЯ элемент...
set_array_value() {
	local key="$1"; shift
	local tmp block="" it e
	for it in "$@"; do
		e="$(cfg_escape "$it")"
		block+=$'\t'"\"$e\""$'\n'
	done

	if ! grep -qE "^${key}=\(" "$CONFIG_FILE"; then
		{ printf '%s=(\n' "$key"; printf '%s' "$block"; printf ')\n'; } >> "$CONFIG_FILE"
		load_config force; return 0
	fi

	tmp="$(mk_tmp)"
	awk -v k="$key" -v block="$block" '
		$0 ~ "^" k "=\\(" { print k "=("; printf "%s", block; skip=1; next }
		skip && /^\)/      { print ")"; skip=0; next }
		skip               { next }
		{ print }
	' "$CONFIG_FILE" > "$tmp"
	mv "$tmp" "$CONFIG_FILE"
	load_config force
}

set_dc_rules() { set_array_value DC_IP_RULES "$@"; }

# ============================================================
#  Валидация и secret
# ============================================================

is_uint()   { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
is_float()  { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]]; }
is_ipv4()   { [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
is_secret() { [[ "${1:-}" =~ ^[0-9a-fA-F]{32}$ ]]; }

validate_config() {
	is_uint "$PORT" && [ "$PORT" -ge 1 ] && [ "$PORT" -le 65535 ] || die "PORT должен быть 1..65535"
	[ "$PORT" -lt 1024 ] && warn "Порт <1024 требует root — Android не даст его забиндить"
	case "$BIND_MODE" in local|lan) ;; *) die "BIND_MODE: только local или lan" ;; esac
	is_uint "$BUF_KB"      || die "BUF_KB должен быть числом"
	is_uint "$POOL_SIZE"   || die "POOL_SIZE должен быть числом"
	is_uint "${RESTART_EVERY_H:-0}" || die "RESTART_EVERY_H должен быть числом часов (0 = выкл)"
	is_uint "$LOG_BACKUPS" || die "LOG_BACKUPS должен быть числом"
	[ "$LOG_BACKUPS" -ge 1 ] 2>/dev/null || die "LOG_BACKUPS минимум 1 (требование ядра)"
	is_float "$LOG_MAX_MB" || die "LOG_MAX_MB должен быть числом"
	[ -z "${LAN_IP:-}" ] || is_ipv4 "$LAN_IP" || die "LAN_IP не похож на IPv4"
	local rule
	for rule in "${DC_IP_RULES[@]:-}"; do
		[ -z "$rule" ] && continue
		[[ "$rule" =~ ^[0-9]+:([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Правило DC неверно: '$rule'"
	done
}

generate_secret() {
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -hex 16
	else
		head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo
	fi
}

ensure_secret() {
	if [ -z "${SECRET:-}" ]; then
		local s; s="$(generate_secret)"
		set_config_value SECRET "$s"
		ok "Сгенерирован SECRET: $s"
	elif ! is_secret "$SECRET"; then
		die "SECRET должен быть ровно 32 hex-символа (ядро отклонит другой)"
	fi
}

# ============================================================
#  Сеть, интерфейсы, ссылки
# ============================================================

bind_host() { [ "$BIND_MODE" = "lan" ] && printf '0.0.0.0' || printf '127.0.0.1'; }

# Все не-loopback IPv4 в формате "iface<TAB>ip"
# Любой доступный python — нужен для определения адресов без root
py_bin() {
	command -v python 2>/dev/null || command -v python3 2>/dev/null || true
}

# Весь python для сети — в одном файле: один запуск интерпретатора вместо трёх
ensure_netinfo() {
	[ -s "$NETINFO_PY" ] && return 0
	mkdir -p "$STATE_DIR"
	cat > "$NETINFO_PY" <<'PYEOF'
"""Сетевые данные без root.

Android 11+ закрыл bind() netlink-сокета, поэтому `ip addr` требует root.
ioctl(SIOCGIFADDR) и UDP-connect таких прав не требуют.

Режимы: ifaces | outbound | wifi
"""
import sys, socket, struct, fcntl, json

SIOCGIFADDR = 0x8915
CANDIDATES = ['wlan0', 'wlan1', 'wlan2', 'ap0', 'ap1', 'swlan0', 'softap0',
              'eth0', 'usb0', 'rndis0', 'bt-pan', 'rmnet_data0', 'rmnet_data1',
              'rmnet_data2', 'rmnet0', 'tun0', 'wg0']


def iface_names():
    names = []
    try:
        names += [n for _, n in socket.if_nameindex()]
    except Exception:
        pass
    try:
        with open('/proc/net/dev') as fh:
            for line in fh:
                if ':' in line:
                    names.append(line.split(':')[0].strip())
    except Exception:
        pass
    return names + CANDIDATES


def iface_addr(name):
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        packed = struct.pack('256s', name.encode()[:15])
        addr = socket.inet_ntoa(fcntl.ioctl(sock.fileno(), SIOCGIFADDR, packed)[20:24])
        sock.close()
        return addr
    except Exception:
        return ''


def mode_ifaces():
    seen = set()
    for name in iface_names():
        if not name or name in seen:
            continue
        seen.add(name)
        addr = iface_addr(name)
        if not addr or addr.startswith('127.') or addr == '0.0.0.0':
            continue
        print(name + '\t' + addr)


def mode_outbound():
    # пакеты не отправляются: connect на UDP только выбирает маршрут
    for target in (('8.8.8.8', 53), ('1.1.1.1', 53), ('192.168.1.1', 53), ('10.0.0.1', 53)):
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.connect(target)
            addr = sock.getsockname()[0]
            sock.close()
        except Exception:
            continue
        if addr and not addr.startswith('127.'):
            print(addr)
            return


def mode_wifi():
    try:
        data = json.load(sys.stdin)
    except Exception:
        return
    addr = str(data.get('ip', '') or '')
    if addr and not addr.startswith('127.'):
        print(addr)


MODES = {'ifaces': mode_ifaces, 'outbound': mode_outbound, 'wifi': mode_wifi}
MODES.get(sys.argv[1] if len(sys.argv) > 1 else 'ifaces', mode_ifaces)()
PYEOF
	return 0
}

# net_query <режим> — единая точка вызова python-хелпера
net_query() {
	local py; py="$(py_bin)"; [ -n "$py" ] || return 1
	ensure_netinfo || return 1
	"$py" "$NETINFO_PY" "$1" 2>/dev/null || true
}

# Адрес от Termux:API, если он установлен
wifi_info_ip() {
	command -v termux-wifi-connectioninfo >/dev/null 2>&1 || return 1
	local py; py="$(py_bin)"; [ -n "$py" ] || return 1
	ensure_netinfo || return 1
	api_call termux-wifi-connectioninfo 2>/dev/null | "$py" "$NETINFO_PY" wifi 2>/dev/null || true
}

# Кэш на один вызов команды: без него python запускался до 4 раз подряд
IFACE_CACHE=""

# Интерфейсы и их IPv4 в виде "имя<TAB>ip". Ни один способ не требует root.
# list_interfaces fresh — перечитать, игнорируя кэш.
list_interfaces() {
	[ "${1:-}" = "fresh" ] && IFACE_CACHE=""
	if [ -n "$IFACE_CACHE" ]; then
		printf '%s\n' "$IFACE_CACHE"
		return 0
	fi

	local out
	# 1) ioctl через python — работает на всех версиях Android
	out="$(net_query ifaces || true)"

	# 2) iproute2 — только если система разрешает нетлинк
	if [ -z "$out" ] && command -v ip >/dev/null 2>&1; then
		out="$(ip -4 -o addr show 2>/dev/null \
			| awk '{split($4,a,"/"); if (a[1] !~ /^127\./) printf "%s\t%s\n", $2, a[1]}' || true)"
	fi

	# 3) net-tools
	if [ -z "$out" ] && command -v ifconfig >/dev/null 2>&1; then
		out="$(ifconfig 2>/dev/null | awk '
			/^[a-zA-Z0-9_]+:?/ { iface=$1; sub(":","",iface) }
			/inet /            { ip=$2; sub("addr:","",ip); if (ip !~ /^127\./) printf "%s\t%s\n", iface, ip }
		' || true)"
	fi

	# 4) Termux:API
	if [ -z "$out" ]; then
		local wip; wip="$(wifi_info_ip 2>/dev/null || true)"
		[ -n "$wip" ] && out="$(printf 'wifi\t%s' "$wip")"
	fi

	# 5) адрес активного маршрута
	if [ -z "$out" ]; then
		local oip; oip="$(net_query outbound || true)"
		[ -n "$oip" ] && out="$(printf 'сеть\t%s' "$oip")"
	fi

	IFACE_CACHE="$out"
	[ -n "$out" ] && printf '%s\n' "$out"
	return 0
}

# IP для ссылок. Список интерфейсов берётся РОВНО один раз.
detect_lan_ip() {
	local raw ip=""
	raw="$(list_interfaces)"

	# LAN_IP из конфига годится только если адрес реально есть на интерфейсах
	# (иначе после смены Wi-Fi выдавались бы старые ссылки)
	if [ -n "${LAN_IP:-}" ] \
		&& printf '%s\n' "$raw" | awk -F'\t' -v w="$LAN_IP" '$2==w {f=1} END{exit !f}'; then
		printf '%s' "$LAN_IP"; return 0
	fi

	# приоритет: выбранный интерфейс -> точка доступа -> Wi-Fi -> любой
	ip="$(printf '%s\n' "$raw" | awk -F'\t' -v i="${NET_IFACE:-}" '
		i != "" && $1 == i          { print $2; exit }
		$1 ~ /^(ap|swlan|softap)/   { ap = ap ? ap : $2 }
		$1 ~ /^wlan/                { wl = wl ? wl : $2 }
		$2 != ""                    { any = any ? any : $2 }
		END { if (ap) print ap; else if (wl) print wl; else print any }
	')"

	# крайний случай: интерфейсы не перечислились, но сеть есть
	[ -z "$ip" ] && ip="$(net_query outbound || true)"
	printf '%s' "$ip"
}

choose_interface() {
	load_config
	local lines=() line n=0 raw
	raw="$(list_interfaces fresh)"
	while IFS= read -r line; do [ -n "$line" ] && lines+=("$line"); done <<EOF
$raw
EOF

	if [ "${#lines[@]}" -eq 0 ]; then
		err "Сетевые интерфейсы с IPv4 не найдены"
		msg "Проверь, что телефон подключён к Wi-Fi или раздаёт точку доступа"
		msg "Рут не нужен: адрес берётся через python, а не через ip addr"
		msg "Если python ещё не стоит: pkg install python"
		return 1
	fi

	hr
	printf '%sДоступные интерфейсы:%s\n\n' "$C_BOLD" "$C_RESET"
	for line in "${lines[@]}"; do
		n=$((n+1))
		local iface ip hint=""
		iface="${line%%	*}"; ip="${line##*	}"
		case "$iface" in
			ap*)      hint="точка доступа" ;;
			wlan*)    hint="Wi-Fi" ;;
			rmnet*)   hint="мобильный интернет" ;;
			tun*|wg*) hint="VPN" ;;
		esac
		printf '  %d) %-12s %-16s %s%s%s\n' "$n" "$iface" "$ip" "$C_DIM" "$hint" "$C_RESET"
	done
	printf '  0) Автоопределение\n\nВыбор: '

	local ch; read_choice ch || { msg "Отменено"; return 0; }
	if [ "$ch" = "0" ]; then
		set_config_value NET_IFACE ""; set_config_value LAN_IP ""
		ok "Включено автоопределение"; return 0
	fi
	if is_uint "$ch" && [ "$ch" -ge 1 ] && [ "$ch" -le "${#lines[@]}" ]; then
		line="${lines[$((ch-1))]}"
		set_config_value NET_IFACE "${line%%	*}"
		set_config_value LAN_IP "${line##*	}"
		ok "Выбран ${line%%	*} -> ${line##*	}"
	else
		err "Неверный выбор"
	fi
}

# Строка в hex (для ee-secret в режиме Fake TLS)
hex_of() { printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }

# Secret для ссылки:
#   dd + secret                  — обычный random-padding
#   ee + secret + hex(домен)     — Fake TLS
link_secret() {
	if [ -n "${FAKE_TLS_DOMAIN:-}" ]; then
		printf 'ee%s%s' "$SECRET" "$(hex_of "$FAKE_TLS_DOMAIN")"
	else
		printf 'dd%s' "$SECRET"
	fi
}

# Копирование в буфер обмена Android (Termux:API)
copy_clip() {
	[ "${CLIPBOARD_COPY:-1}" = "1" ] || return 0
	[ -n "${1:-}" ] || return 0
	if command -v termux-clipboard-set >/dev/null 2>&1; then
		local tmp; tmp="$(mk_tmp)" || return 0
		printf '%s' "$1" > "$tmp"
			if run_timeout "$API_TIMEOUT" termux-clipboard-set <"$tmp" >/dev/null 2>&1; then
				ok "Ссылка скопирована в буфер обмена"
				warn "ВНИМАНИЕ: Ссылка содержит секрет. Другие приложения могут прочитать буфер обмена."
			else
			warn "Буфер обмена не ответил (нужно приложение Termux:API)"
		fi
	else
		msg "Для копирования ссылки: pkg install termux-api + приложение Termux:API"
	fi
}

proxy_link() {
	printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$1" "$PORT" "$(link_secret)"
}

# ============================================================
#  Команда запуска
# ============================================================

python_bin() {
	if [ "${USE_VENV:-0}" = "1" ] && [ -x "$VENV_DIR/bin/python" ]; then
		printf '%s' "$VENV_DIR/bin/python"
	else
		printf 'python'
	fi
}

build_run_args() {
	RUN_ARGS=(--host "$(bind_host)" --port "$PORT" --secret "$SECRET")

	local rule
	for rule in "${DC_IP_RULES[@]:-}"; do
		[ -n "$rule" ] && RUN_ARGS+=(--dc-ip "$rule")
	done

	RUN_ARGS+=(--buf-kb "$BUF_KB" --pool-size "$POOL_SIZE")
	local backups="$LOG_BACKUPS"
	[ "$backups" -lt 1 ] 2>/dev/null && backups=1
	RUN_ARGS+=(--log-file "$LOG_FILE" --log-max-mb "$LOG_MAX_MB" --log-backups "$backups")

	[ "${VERBOSE:-0}" = "1" ] && RUN_ARGS+=(-v)
	[ "${CF_PROXY_ENABLED:-1}" = "0" ] && RUN_ARGS+=(--no-cfproxy)

	local d
	for d in "${CF_CUSTOM_DOMAINS[@]:-}"; do
		[ -n "$d" ] && RUN_ARGS+=(--cfproxy-domain "$d")
	done
	for d in "${CF_WORKER_DOMAINS[@]:-}"; do
		[ -n "$d" ] && RUN_ARGS+=(--cfproxy-worker-domain "$d")
	done

	[ -n "${FAKE_TLS_DOMAIN:-}" ] && RUN_ARGS+=(--fake-tls-domain "$FAKE_TLS_DOMAIN")
	[ "${FORCE_TEST_DC:-0}" = "1" ] && RUN_ARGS+=(--force-test-dc)
	[ "${PROXY_PROTOCOL:-0}" = "1" ] && RUN_ARGS+=(--proxy-protocol)

	if [ -n "${EXTRA_ARGS:-}" ]; then
		# разбор с учётом кавычек: --foo "bar baz" останется одним аргументом
		local -a extra=()
		if eval "extra=($EXTRA_ARGS)" 2>/dev/null; then
			[ "${#extra[@]}" -gt 0 ] && RUN_ARGS+=("${extra[@]}")
		else
			warn "EXTRA_ARGS не разобрались (проверь кавычки) — пропускаю"
		fi
	fi
}

# Запуск через файлы: tmux — один аргумент, run.args — по строке на аргумент (пробелы не ломают).
write_runner() {
	mkdir -p "$STATE_DIR"
	printf '%s\n' "${RUN_ARGS[@]}" > "$RUN_ARGS_FILE"
	chmod600 "$RUN_ARGS_FILE"
	write_script "$RUN_SCRIPT" 700 <<'EOS'
cd "@@APPDIR@@" || exit 1
mapfile -t ARGS < "@@ARGSFILE@@" || exit 1
exec "@@PYTHON@@" -m proxy.tg_ws_proxy "${ARGS[@]}"
EOS
}

# pane-died-хук: мгновенный рестарт; при STOP_MARK молчит. См. docs/autostart.md.
write_pane_died_script() {
	write_script "$PANE_DIED_SCRIPT" 700 <<'EOS'
STOP_MARK="@@STOPMARK@@"
SELF="@@SELF@@"
LOG="@@BOOTLOG@@"
STATE_DIR="@@STATE@@"
RESTART_MARK="$STATE_DIR/pane-died.last"
MIN_RESTART_GAP=10
PANE_STATUS="${1:-?}"
export TMUX_TMPDIR="@@TMUXTMPDIR@@"

if [ -f "$STOP_MARK" ]; then
	rm -f "$STOP_MARK"
	exit 0
fi

# Когда MIUI убивает Python через SIGKILL, tmux обычно передаёт статус 137.
# Ограничение частоты не даёт высаживать батарею при моментальном цикле падений.
now="$(date +%s)"
last="$(cat "$RESTART_MARK" 2>/dev/null || printf '0')"
case "$last" in ''|*[!0-9]*) last=0 ;; esac
if [ $(( now - last )) -lt "$MIN_RESTART_GAP" ]; then
	printf '%s панель завершилась (код %s), повторный запуск через %sс\n' \
		"$(date '+%Y-%m-%d %H:%M:%S')" "$PANE_STATUS" "$MIN_RESTART_GAP" >> "$LOG"
	sleep $(( MIN_RESTART_GAP - (now - last) ))
fi
printf '%s' "$(date +%s)" > "$RESTART_MARK"
printf '%s панель завершилась (код %s) -> рестарт\n' \
	"$(date '+%Y-%m-%d %H:%M:%S')" "$PANE_STATUS" >> "$LOG"
bash "$SELF" start >> "$LOG" 2>&1 || true
EOS
}

show_command() {
	load_config; validate_config; ensure_secret; build_run_args
	local q="" a
	for a in "${RUN_ARGS[@]}"; do q+=" $(printf '%q' "$a")"; done
	printf 'cd %s && %s -m proxy.tg_ws_proxy%s\n' "$APP_DIR" "$(python_bin)" "$q"
}

# ============================================================
#  Установка
# ============================================================

install_deps() {
	msg "Обновляю пакеты..."
	pkg update -y >/dev/null 2>&1 || warn "pkg update с ошибкой, продолжаю"

	msg "Ставлю базовые пакеты..."
	pkg install -y git python tmux curl procps nano openssl-tool \
		|| pkg install -y git python tmux curl procps nano openssl \
		|| die "pkg install не удался"

	# cryptography через Rust собирается долго — берём системный пакет
	msg "Ставлю python-cryptography..."
	if ! pkg install -y python-cryptography; then
		warn "Пакета нет, попробую собрать через pip (потребуется rust)"
		pkg install -y rust binutils || warn "rust не установился"
	fi

	command -v nc >/dev/null 2>&1 || pkg install -y netcat-openbsd >/dev/null 2>&1 \
		|| warn "netcat не установлен — тесты портов пойдут через /dev/tcp"

	# необязательное, но удобное: QR и список подключений
	pkg install -y qrencode >/dev/null 2>&1 || true
	pkg install -y iproute2 >/dev/null 2>&1 || true
	ok "Зависимости готовы"
}

clone_or_pull() {
	if [ -d "$APP_DIR/.git" ]; then
		msg "Обновляю репозиторий..."
		git -C "$APP_DIR" fetch --all --prune || die "git fetch не удался"
		if [ -n "$(git -C "$APP_DIR" status --porcelain)" ]; then
			warn "Есть локальные изменения в $APP_DIR — git pull пропущен"
		else
			if git -C "$APP_DIR" checkout "${REPO_BRANCH:-v1.10.2}"; then
				ok "Обновлено до $(git -C "$APP_DIR" rev-parse --short HEAD)"
			else
				warn "Быстрое обновление невозможно (force-push или расхождение веток)"
				if ask "Сбросить локальную копию к ${REPO_BRANCH:-v1.10.2}?"; then
					git -C "$APP_DIR" reset --hard "${REPO_BRANCH:-v1.10.2}" || die "reset не удался"
					ok "Сброшено до $(git -C "$APP_DIR" rev-parse --short HEAD)"
				else
					die "Обновление отменено"
				fi
			fi
		fi
	else
		msg "Клонирую $REPO_URL ..."
		mkdir -p "$(dirname "$APP_DIR")"
		git clone "$REPO_URL" "$APP_DIR" || die "git clone не удался"
		git -C "$APP_DIR" checkout "${REPO_BRANCH:-v1.10.2}" || die "git checkout не удался"
		ok "Склонировано в $APP_DIR"
	fi
	printf '0\n' > "${UPDATE_STATE:-/dev/null}" 2>/dev/null || true
}

setup_python() {
	if [ "${USE_VENV:-0}" = "1" ]; then
		[ -d "$VENV_DIR" ] || { msg "Создаю venv (--system-site-packages)..."; \
			python -m venv --system-site-packages "$VENV_DIR" || die "venv не создался"; }
	fi

	local py; py="$(python_bin)"
	if "$py" -c "import cryptography" >/dev/null 2>&1; then
		ok "cryptography: $("$py" -c 'import cryptography;print(cryptography.__version__)')"
	else
		msg "Ставлю cryptography через pip (может быть долго)..."
		"$py" -m pip install --upgrade pip >/dev/null 2>&1 || true
		"$py" -m pip install cryptography || die "Не удалось поставить cryptography"
	fi
	ok "Python-окружение готово"
}

check_entrypoint() {
	[ -s "$APP_DIR/proxy/tg_ws_proxy.py" ] && return 0
	err "Не найден $APP_DIR/proxy/tg_ws_proxy.py"
	warn "Запусти установку (пункт 1) или переустановку (пункт 13)"
	return 1
}

# Защита от rm -rf по опасному пути (пустой, /, $HOME, $PREFIX и т.д.)
safe_app_dir() {
	case "${APP_DIR:-}" in
		""|"/"|"$HOME"|"${PREFIX:-/data/data/com.termux/files/usr}") ;;
		"$HOME"/tg-ws-proxy|"$HOME"/tg-ws-proxy/*) return 0 ;;
		*) ;;
	esac
	die "APP_DIR подозрительный (${APP_DIR:-<пусто>}) — удалять отказываюсь"
}

cmd_install() {
	check_termux; load_config
	install_deps; clone_or_pull; setup_python; ensure_secret
	ensure_storage
	cmd_alias_install || true
	check_entrypoint || true
	hr; ok "Установка завершена"; cmd_links
	hr
	warn "Чтобы прокси не убивало в фоне — 2 вещи, которые не делает ни одна прошивка сама:"
	if ask "Открыть настройки батареи и исключить Termux из оптимизации сейчас?"; then
		check_battery_optimization
	else
		msg "Сделать это позже: пункт «Диагностика» в меню"
	fi
	if command -v termux-job-scheduler >/dev/null 2>&1; then
		if ask "Включить резервный автозапуск через планировщик Android (переживает убийство приложения целиком)?"; then
			cmd_autostart_job_on || true
		fi
	else
		msg "Резервный автозапуск через планировщик Android: pkg install termux-api, потом пункт 15 в меню"
	fi
}

cmd_update() {
	check_termux; load_config
	check_update || true
	hr
	ask "Обновить проект?" || { msg "Отменено"; return 0; }
	local was=0
	is_running && { was=1; stop_proxy; }
	clone_or_pull; setup_python
	[ "$was" = "1" ] && { msg "Поднимаю обратно..."; start_proxy; }
	ok "Обновление завершено"
}

# Обновление самого менеджера (не ядра): git pull в клоне или скачивание raw-файла
cmd_self_update() {
	local self dir url tmp
	self="$(self_path)"
	dir="$(dirname "$self")"
	if [ -d "$dir/.git" ]; then
		msg "Обновляю менеджер из git..."
		if git -C "$dir" pull --ff-only 2>/dev/null; then
			chmod +x "$self" 2>/dev/null || true
			ok "Менеджер обновлён — перезапусти меню"
			return 0
		fi
		# pull не взлетел — обычно локальные правки в файле (например, копировали поверх клона)
		if [ -n "$(git -C "$dir" status --porcelain -- tg-ws-proxy-manager.sh 2>/dev/null)" ]; then
			warn "Локальные правки в файле блокируют обновление."
			if ask "Сбросить их и взять версию с GitHub? (настройки лежат вне репозитория, не пострадают)"; then
				git -C "$dir" fetch origin 2>/dev/null || true
				up="$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || echo origin/main)"
				git -C "$dir" reset --hard "$up" || { err "reset не удался"; return 1; }
				chmod +x "$self" 2>/dev/null || true
				ok "Менеджер обновлён — перезапусти меню"
				return 0
			fi
			msg "Отменено — локальные правки оставлены"
			return 0
		fi
		err "git pull не удался"
		return 1
	fi
	command -v curl >/dev/null 2>&1 || die "Нужен curl (pkg install curl)"
	url="https://raw.githubusercontent.com/afis297/tg-ws-proxy-manager/main/tg-ws-proxy-manager.sh"
	tmp="${self}.new"
	msg "Качаю свежий менеджер..."
	curl -fsSL --max-time 60 "$url" -o "$tmp" || { err "Не скачалось — проверь интернет"; rm -f "$tmp"; return 1; }
	[ -s "$tmp" ] || { err "Скачался пустой файл"; rm -f "$tmp"; return 1; }
	bash -n "$tmp" 2>/dev/null || { err "Скачанный файл битый — не ставлю"; rm -f "$tmp"; return 1; }
	mv "$tmp" "$self"
	chmod +x "$self" 2>/dev/null || true
	ok "Менеджер обновлён: $self"
	msg "Перезапусти меню, чтобы подхватить новую версию"
}

# Полная переустановка репы. Конфиг лежит вне репы, поэтому не теряется.
cmd_reinstall() {
	check_termux; load_config
	warn "Каталог $APP_DIR будет удалён и склонирован заново."
	warn "Конфиг и SECRET сохранятся ($CONFIG_FILE)."
	ask "Продолжить?" || { msg "Отменено"; return 0; }

	is_running && stop_proxy
	force_kill quiet
	safe_app_dir
	rm -rf "$APP_DIR"
	install_deps; clone_or_pull; setup_python
	check_entrypoint || true
	ok "Переустановка завершена, SECRET прежний: $SECRET"
}

# ============================================================
#  Запуск / остановка
# ============================================================

is_running() {
	command -v tmux >/dev/null 2>&1 || return 1
	tmux has-session -t "$SESSION_NAME" 2>/dev/null
}

# Строгая проверка: сессия есть И pane_pid жив (run.sh идёт через exec). См. docs/troubleshooting.md.
is_running_strict() {
	is_running || return 1
	local pane_pid
	pane_pid="$(tmux list-panes -t "$SESSION_NAME" -F '#{pane_pid}' 2>/dev/null | head -n1)"
	[ -n "$pane_pid" ] || return 1
	kill -0 "$pane_pid" 2>/dev/null
}

# Чистим каталог сокета только если tmux мёртв; живую сессию не трогаем никогда.
cleanup_stale_tmux_socket() {
	command -v tmux >/dev/null 2>&1 || return 0
	tmux ls >/dev/null 2>&1 && return 0
	[ -d "$TMUX_TMPDIR" ] || return 0
	warn "Очищаю недоступный каталог сокета tmux после аварийного завершения"
	rm -rf "$TMUX_TMPDIR" 2>/dev/null || return 1
	mkdir -p "$TMUX_TMPDIR" 2>/dev/null || return 1
	chmod 700 "$TMUX_TMPDIR" 2>/dev/null || true
	return 0
}

# Прибить процессы ядра, оставшиеся без tmux-сессии
force_kill() {
	local quiet="${1:-}"
	command -v pgrep >/dev/null 2>&1 || { [ "$quiet" = quiet ] || warn "pgrep нет (pkg install procps)"; return 0; }

	local pids=() pid pattern out
	for pattern in "proxy.tg_ws_proxy" "proxy/tg_ws_proxy.py"; do
		out="$(pgrep -f "$pattern" 2>/dev/null || true)"
		for pid in $out; do
			[ -n "$pid" ] && [ "$pid" != "$$" ] && pids+=("$pid")
		done
	done

	if [ "${#pids[@]}" -eq 0 ]; then
		[ "$quiet" = quiet ] || msg "Висящих процессов нет"
		return 0
	fi

	msg "Останавливаю процессы: ${pids[*]}"
	kill "${pids[@]}" 2>/dev/null || true
	sleep 2

	local alive=()
	for pid in "${pids[@]}"; do kill -0 "$pid" 2>/dev/null && alive+=("$pid"); done
	if [ "${#alive[@]}" -gt 0 ]; then
		warn "Не отвечают, KILL -9: ${alive[*]}"
		kill -9 "${alive[@]}" 2>/dev/null || true
	fi
	ok "Процессы остановлены"
}

port_busy() { tcp_open 127.0.0.1 "$PORT" 2; }

start_proxy() {
	check_termux; load_config; validate_config; ensure_secret
	command -v tmux >/dev/null 2>&1 || die "tmux не установлен"
	[ -d "$APP_DIR" ] || die "Проект не установлен (пункт 1)"
	check_entrypoint || die "Нет точки входа"

	is_running && { warn "Уже запущен"; return 0; }
	cleanup_stale_tmux_socket || warn "Не удалось очистить каталог сокета tmux"

	# tmux-сессии нет, но порт занят -> висящий процесс
	if port_busy; then
		warn "Порт $PORT занят, а tmux-сессии нет — похоже, висит старый процесс"
		force_kill
		sleep 1
		port_busy && die "Порт $PORT всё ещё занят другим приложением"
	fi

	build_run_args
	write_runner

	rm -f "$STOP_MARK" 2>/dev/null || true
	msg "Запускаю в tmux '$SESSION_NAME'..."
	tmux new-session -d -s "$SESSION_NAME" -- "$RUN_SCRIPT" || die "tmux не смог создать сессию"
	# pane-died — мгновенный рестарт; watchdog — страховка от зависания. См. docs/autostart.md.
	write_pane_died_script
	tmux set-hook -t "$SESSION_NAME" pane-died \
		"run-shell \"bash '$PANE_DIED_SCRIPT' '#{pane_dead_status}' &\"" 2>/dev/null || true

	sleep "$START_WAIT"
	if is_running_strict; then
		ok "Запущен на $(bind_host):$PORT"
		wake_lock_on
		hr; cmd_links
	else
		err "Не поднялся. Последние строки лога:"
		tail -n 25 "$LOG_FILE" 2>/dev/null || warn "Лог пуст"
		return 1
	fi
}

stop_proxy() {
	load_config
	if is_running; then
		mkdir -p "$STATE_DIR"; : > "$STOP_MARK" # плановая остановка: хук молчит
		tmux kill-session -t "$SESSION_NAME"; ok "Остановлен"
	else
		warn "tmux-сессии нет"
	fi
	force_kill quiet
	wake_lock_off
}

cmd_restart() { stop_proxy || true; sleep 1; start_proxy; }

cmd_status() {
	load_config
	hr
	is_running \
		&& printf '%s[+] %s запущен%s\n' "$C_GREEN" "$APP_NAME" "$C_RESET" \
		|| printf '%s[-] %s остановлен%s\n' "$C_RED" "$APP_NAME" "$C_RESET"
	hr
	printf '  Listen:      %s:%s\n' "$(bind_host)" "$PORT"
	printf '  Режим:       %s\n' "$([ "$BIND_MODE" = lan ] && echo 'раздача в сеть' || echo 'только телефон')"
	printf '  Интерфейс:   %s\n' "${NET_IFACE:-авто}"
	printf '  IP в сети:   %s\n' "$(detect_lan_ip)"
	printf '  Secret:      %s\n' "${SECRET:-<пусто>}"
	printf '  DC -> IP:    %s\n' "${DC_IP_RULES[*]:-нет}"
	printf '  CF fallback: %s\n' "$([ "${CF_PROXY_ENABLED:-1}" = 1 ] && echo включен || echo выключен)"
	printf '  CF Worker:   %s\n' "${CF_WORKER_DOMAINS[*]:-<нет>}"
	printf '  CF домены:   %s\n' "${CF_CUSTOM_DOMAINS[*]:-<нет>}"
	printf '  Fake TLS:    %s\n' "${FAKE_TLS_DOMAIN:-выключен}"
	printf '  Пул WS:      %s на DC\n' "$POOL_SIZE"
	printf '  Python:      %s\n' "$(python_bin)"
	printf '  Каталог:     %s\n' "$APP_DIR"
	printf '  Wake-lock:   %s\n' "$([ "${WAKE_LOCK:-1}" = 1 ] && echo включён || echo выключен)"
	printf '  Автозапуск:  %s\n' "$(autostart_state)"
	printf '  Лог:         %s\n' "$LOG_FILE"
	if is_running && ! is_running_strict; then
		warn "tmux-сессия есть, но процесс под ней не отвечает — похоже на зависание"
	fi
	hr
	is_running && cmd_links
	return 0
}

cmd_logs() {
	load_config
	[ -f "$LOG_FILE" ] || die "Лог пуст: прокси ещё не запускался"
	msg "Ctrl+C — выход в меню"
	tail -n 60 -f "$LOG_FILE" || true
	ask "Очистить лог?" && cmd_clear_logs || true
}

cmd_clear_logs() {
	load_config
	is_running && warn "Прокси запущен — лог обнулится на лету"
	: > "$LOG_FILE" 2>/dev/null || true
	local f
	for f in "$LOG_FILE."*; do [ -e "$f" ] && rm -f "$f"; done
	ok "Лог очищен: $LOG_FILE"
}

# события мыши/тача, которые не должны закрывать окно
MOUSE_EVENTS=(
	MouseDown1Pane MouseDown2Pane MouseDown3Pane
	MouseUp1Pane MouseUp2Pane MouseUp3Pane
	MouseDrag1Pane MouseDrag2Pane MouseDrag3Pane
	MouseDragEnd1Pane MouseDragEnd2Pane MouseDragEnd3Pane
	SecondClick1Pane DoubleClick1Pane TripleClick1Pane
	WheelUpPane WheelDownPane
	MouseDown1Status MouseUp1Status WheelUpStatus WheelDownStatus
	MouseDown1Border MouseDrag1Border
)

attach_keys_on() {
	# тач по экрану отдаём tmux, чтобы он не ушёл в Any
	tmux set-option -t "$SESSION_NAME" mouse on 2>/dev/null || true
	tmux set-option -t "$SESSION_NAME" prefix None 2>/dev/null || true
	tmux bind-key -T root Any detach-client 2>/dev/null || true
	# каждое касание — пустая команда вместо выхода
	local ev
	for ev in "${MOUSE_EVENTS[@]}"; do
		tmux bind-key -T root "$ev" refresh-client 2>/dev/null || true
	done
}

attach_keys_off() {
	local ev
	for ev in "${MOUSE_EVENTS[@]}"; do
		tmux unbind-key -T root "$ev" 2>/dev/null || true
	done
	tmux unbind-key -T root Any 2>/dev/null || true
	tmux set-option -t "$SESSION_NAME" prefix C-b 2>/dev/null || true
	tmux set-option -t "$SESSION_NAME" mouse off 2>/dev/null || true
}

cmd_attach() {
	load_config
	is_running || die "Прокси не запущен"
	msg "Любая клавиша — выход. Тап и прокрутка ничего не делают."
	sleep 1

	attach_keys_on
	trap 'attach_keys_off' EXIT
	tmux attach -t "$SESSION_NAME" 2>/dev/null || true
	trap - EXIT
	attach_keys_off
	ok "Вышли из окна, прокси работает"
}

# ============================================================
#  Ссылки и раздача
# ============================================================

cmd_links() {
	load_config; ensure_secret
	local lan; lan="$(detect_lan_ip)"

	printf '%sСсылки подключения (MTProto)%s\n' "$C_BOLD" "$C_RESET"
	hr
	printf '%sЛокально на телефоне:%s\n%s\n\n' "$C_CYAN" "$C_RESET" "$(proxy_link 127.0.0.1)"

	if [ -n "$lan" ]; then
		printf '%sДля других устройств (%s):%s\n%s\n\n' \
			"$C_CYAN" "${NET_IFACE:-авто}" "$C_RESET" "$(proxy_link "$lan")"
		printf '%sВручную:%s\n  Тип: MTProto\n  Сервер: %s\n  Порт: %s\n  Secret: %s\n' \
			"$C_DIM" "$C_RESET" "$lan" "$PORT" "$(link_secret)"
		[ -n "${FAKE_TLS_DOMAIN:-}" ] && printf '%s  Режим: Fake TLS, SNI %s%s\n' "$C_DIM" "$FAKE_TLS_DOMAIN" "$C_RESET"
	else
		warn "IP не определён — выбери интерфейс в настройках (пункт 9)"
	fi

	[ "$BIND_MODE" != "lan" ] && { printf '\n'; warn "Режим local: с других устройств не сработает (режим — в настройках, пункт 9)"; }
	# в local-режиме LAN-ссылка бесполезна — копируем локальную
	if [ "$BIND_MODE" = "lan" ] && [ -n "${lan:-}" ]; then
		copy_clip "$(proxy_link "$lan")"
	else
		copy_clip "$(proxy_link 127.0.0.1)"
	fi
	hr
}

# QR-код ссылки — чтобы не вбивать secret руками на другом телефоне
# QR через qrencode, а если пакета нет — через python-модуль qrcode
qr_render() {
	local link="$1" py pyc
	if ensure_pkg qrencode qrencode libqrencode; then
		qrencode -t ANSIUTF8 -m 1 "$link" && return 0
		warn "qrencode есть, но отрисовка не удалась"
	else
		warn "qrencode не ставится — перехожу на python"
	fi

	py="$(python_bin)"
	command -v "$py" >/dev/null 2>&1 || { err "python не найден"; return 1; }
	if ! "$py" -c 'import qrcode' 2>/dev/null; then
		msg "Ставлю python-модуль qrcode..."
		"$py" -m pip install --quiet qrcode 2>/dev/null || true
	fi
	pyc='import sys, qrcode\nq = qrcode.QRCode(border=1)\nq.add_data(sys.argv[1])\nq.make()\nq.print_ascii(invert=True)'
	if "$py" -c 'import qrcode' 2>/dev/null; then
		printf '%b\n' "$pyc" | "$py" - "$link" && return 0
	fi

	err "QR не нарисовался"
	msg "Вручную: pkg update && pkg install qrencode"
	msg "Или: pip install qrcode"
	return 1
}

cmd_qr() {
	load_config; ensure_secret
	local lan link
	lan="$(detect_lan_ip)"
	[ -n "$lan" ] || { err "IP не определён — выбери интерфейс в настройках (пункт 9)"; return 1; }
	[ "$BIND_MODE" = "lan" ] || warn "Режим local: с других устройств не сработает (режим — в настройках, пункт 9)"

	link="$(proxy_link "$lan")"
	hr
	printf '%s\n\n' "$link"
	qr_render "$link" || return 1
	hr
	msg "Наведи камеру другого телефона на код"
	copy_clip "$link"
}

# Ссылки + QR одним пунктом меню (без двойного копирования в буфер)
cmd_links_qr() {
	cmd_links || return 1
	ask "Показать QR-код?" || return 0
	load_config
	local lan link
	lan="$(detect_lan_ip)"
	[ -n "$lan" ] || { err "IP не определён — выбери интерфейс в настройках (пункт 9)"; return 1; }
	link="$(proxy_link "$lan")"
	hr
	printf '%s\n\n' "$link"
	qr_render "$link" || return 1
	hr
	msg "Наведи камеру другого телефона на код"
}

# Автозапуск после перезагрузки телефона (требуется Termux:Boot)
cmd_autostart_on() {
	load_config
	# Termux:Boot запускает скрипт без PATH и HOME — всё прописываем явно
	write_script "$BOOT_SCRIPT" 700 <<'EOS' || return 1
export PREFIX="@@PREFIX@@"
export HOME="@@HOME@@"
export PATH="@@PREFIX@@/bin:$PATH"
export TERM=dumb
export TMUX_TMPDIR="@@TMUXTMPDIR@@"
LOG="@@BOOTLOG@@"
mkdir -p "@@STATE@@" "@@TMUXTMPDIR@@"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

log "загрузка телефона"
"@@PREFIX@@/bin/termux-wake-lock" >/dev/null 2>&1 || true

# сеть после загрузки встаёт не сразу — ждём и пробуем несколько раз
sleep @@DELAY@@
for i in 1 2 3; do
	if "@@PREFIX@@/bin/tmux" has-session -t "@@SESSION@@" 2>/dev/null; then break; fi
	log "попытка $i"
	"@@PREFIX@@/bin/bash" "@@SELF@@" start >> "$LOG" 2>&1 || true
	sleep @@RETRY@@
done

if "@@PREFIX@@/bin/tmux" has-session -t "@@SESSION@@" 2>/dev/null; then
	log "прокси запущен"
else
	log "НЕ ЗАПУСТИЛСЯ"
fi
EOS

	ok "Boot-скрипт создан: $BOOT_SCRIPT"
	msg "Лог загрузки: $STATE_DIR/boot.log"
	hr

	# Сам файл ничего не запускает: без приложения Termux:Boot он мертвый
	local st=0
	boot_app_installed || st=$?
	if [ "$st" = "0" ]; then
		ok "Приложение Termux:Boot найдено — после перезагрузки скрипт запустится"
		printf '  Если всё равно не сработает: открой Termux:Boot один раз вручную\n'
		printf '  и выключи оптимизацию батареи для Termux и Termux:Boot\n'
	elif [ "$st" = "1" ]; then
		err "Приложение Termux:Boot НЕ установлено — сам файл ничего не запустит"
		printf '  1. Поставь Termux:Boot из F-Droid (версия из Google Play не подходит)\n'
		printf '  2. Открой его один раз вручную\n'
		printf '  3. Выключи оптимизацию батареи для Termux и Termux:Boot\n'
		msg "Либо включи резервный способ через планировщик Android — он Termux:Boot не требует"
	else
		warn "Не смог проверить, установлено ли Termux:Boot"
		printf '  Нужно: Termux:Boot из F-Droid, открытый один раз вручную,\n'
		printf '  и выключенная оптимизация батареи для Termux и Termux:Boot\n'
	fi
	msg "Проверить не дожидаясь перезагрузки: bash $BOOT_SCRIPT"
	return 0
}

# Установлено ли приложение Termux:Boot: 0 да, 1 нет, 2 проверить не удалось
# pm на части прошивок отвечает долго или никогда — таймаут обязателен
boot_app_installed() {
	# Самый быстрый признак: каталог данных самого приложения
	[ -d "/data/data/com.termux.boot" ] && return 0
	local pm out
	pm="$(command -v pm 2>/dev/null || true)"
	[ -n "$pm" ] || pm="/system/bin/pm"
	[ -x "$pm" ] || return 2
	out="$(run_timeout "$API_TIMEOUT" "$pm" list packages 2>/dev/null || true)"
	[ -n "$out" ] || return 2
	printf '%s\n' "$out" | grep -q 'com\.termux\.boot' || return 1
	return 0
}

# Задача в планировщике Android жива? Спрашиваем только по явной просьбе:
# вызов идёт в Termux:API и может не ответить. 0 да, 1 нет, 2 нет ответа.
job_pending() {
	command -v termux-job-scheduler >/dev/null 2>&1 || return 1
	local out rc=0
	out="$(run_timeout "$API_TIMEOUT" termux-job-scheduler -p 2>/dev/null)" || rc=$?
	[ "$rc" = "124" ] && return 2
	printf '%s\n' "$out" | grep -q 'boot-job\.sh' || return 1
	return 0
}

# Состояние для шапки меню: только локальные файлы, никаких внешних вызовов
autostart_state() {
	local a="" b=""
	[ -f "${BOOT_SCRIPT:-}" ] && a="Termux:Boot"
	[ -f "${JOB_MARK:-}" ] && b="планировщик"
	if [ -n "$a" ] && [ -n "$b" ]; then printf '%s + %s' "$a" "$b"
	elif [ -n "$a" ]; then printf '%s' "$a"
	elif [ -n "$b" ]; then printf '%s' "$b"
	else printf 'выкл'
	fi
}

cmd_autostart_off() {
	load_config
	rm -f "$BOOT_SCRIPT"
	ok "Автозапуск через Termux:Boot выключен"
	return 0
}

# ---------- резервный автозапуск через планировщик Android ----------
# Работает без Termux:Boot и переживает перезагрузку
write_boot_job() {
	write_script "$BOOT_JOB_SCRIPT" 700 <<'EOS'
export PREFIX="@@PREFIX@@"
export HOME="@@HOME@@"
export PATH="@@PREFIX@@/bin:$PATH"
export TERM=dumb
export TMUX_TMPDIR="@@TMUXTMPDIR@@"
LOG="@@BOOTLOG@@"
mkdir -p "@@STATE@@" "@@TMUXTMPDIR@@"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$LOG"; }

# живой прокси не трогаем
if "@@PREFIX@@/bin/tmux" has-session -t "@@SESSION@@" 2>/dev/null; then exit 0; fi

log "задача планировщика: поднимаю прокси"
"@@PREFIX@@/bin/termux-wake-lock" >/dev/null 2>&1 || true
"@@PREFIX@@/bin/bash" "@@SELF@@" start >> "$LOG" 2>&1 || log "старт не удался"
EOS
}

cmd_autostart_job_on() {
	load_config
	if ! command -v termux-job-scheduler >/dev/null 2>&1; then
		err "Нет termux-job-scheduler"
		msg "Нужно: pkg install termux-api и приложение Termux:API из F-Droid"
		return 1
	fi
	write_boot_job || return 1
	msg "Ставлю задачу в планировщик Android..."
	local rc=0
	run_timeout "$API_TIMEOUT" termux-job-scheduler --script "$BOOT_JOB_SCRIPT" \
		--job-id "$BOOT_JOB_ID" --period-ms "$BOOT_JOB_PERIOD_MS" \
		--persisted true --network any >/dev/null 2>&1 || rc=$?
	case "$rc" in
		0)
			mkdir -p "$STATE_DIR"; : > "$JOB_MARK"
			ok "Резервный автозапуск включён"
			msg "Android будет проверять прокси примерно раз в 15 минут и после перезагрузки"
			msg "Запущенный прокси повторно не трогается" ;;
		124)
			err "Termux:API не ответил за ${API_TIMEOUT} с"
			msg "Установи приложение Termux:API из F-Droid (того же источника, что и Termux)"
			msg "Без него pkg install termux-api не работает. Основной способ — Termux:Boot (пункт 1)"
			return 1 ;;
		*)
			err "Планировщик отказал (код $rc)"
			msg "Проверь, что установлено приложение Termux:API из F-Droid"
			return 1 ;;
	esac
	return 0
}

cmd_autostart_job_off() {
	load_config
	if command -v termux-job-scheduler >/dev/null 2>&1; then
		run_timeout "$API_TIMEOUT" termux-job-scheduler --cancel --job-id "$BOOT_JOB_ID" >/dev/null 2>&1 || true
	fi
	rm -f "$JOB_MARK"
	ok "Резервный автозапуск выключен"
	return 0
}

cmd_autostart_check() {
	load_config
	hr
	printf '%sПроверка автозапуска%s\n' "$C_BOLD" "$C_RESET"
	hr
	if [ -f "$BOOT_SCRIPT" ]; then
		ok "Boot-скрипт на месте: $BOOT_SCRIPT"
		[ -x "$BOOT_SCRIPT" ] && ok "Право на запуск есть" || err "Нет права на запуск"
		bash -n "$BOOT_SCRIPT" 2>/dev/null && ok "Синтаксис в порядке" || err "Синтаксис сломан"
	else
		warn "Boot-скрипт не создан"
	fi
	local st=0
	boot_app_installed || st=$?
	case "$st" in
		0) ok "Приложение Termux:Boot установлено" ;;
		1) err "Приложение Termux:Boot не установлено — загрузочный скрипт не вызовется" ;;
		*) warn "Проверить наличие Termux:Boot не удалось" ;;
	esac
	local jst=0
	job_pending || jst=$?
	case "$jst" in
		0) ok "Задача в планировщике Android активна" ;;
		2) warn "Termux:API не ответил — состояние планировщика неизвестно" ;;
		*) msg "Задачи в планировщике нет" ;;
	esac
	hr
	if [ -r /proc/uptime ]; then
		printf 'Телефон без перезагрузки: %s\n' \
			"$(awk '{printf "%d ч %d мин", $1/3600, ($1%3600)/60}' /proc/uptime)"
	fi
	if [ -s "$BOOT_LOG" ]; then
		printf '%sЛог загрузки (последние строки):%s\n' "$C_BOLD" "$C_RESET"
		tail -n 8 "$BOOT_LOG" | sed 's/^/  /'
	else
		msg "Лог загрузки пуст: автозапуск ещё ни разу не срабатывал"
	fi
	is_running && ok "Прокси сейчас запущен" || warn "Прокси сейчас не запущен"
	hr
	return 0
}

autostart_menu() {
	menu_guard_on
	while true; do
		load_config force
		cls
		hr
		printf '%sАвтозапуск при загрузке телефона%s\n' "$C_BOLD" "$C_RESET"
		printf ' Сейчас: %s\n' "$(autostart_state)"
		hr
		printf '  1) Включить через Termux:Boot\n'
		printf '  2) Выключить Termux:Boot\n'
		printf '  3) Включить резервный способ (планировщик Android)\n'
		printf '  4) Выключить резервный способ\n'
		printf '  5) Проверить, работает ли автозапуск\n'
		printf '  0) Назад\n\nВыбор: '
		local ch; read_choice ch || { menu_guard_off; return 0; }; printf '\n'
		case "$ch" in
			0) menu_guard_off; return 0 ;;
			1) run_item cmd_autostart_on ;;
			2) run_item cmd_autostart_off ;;
			3) run_item cmd_autostart_job_on ;;
			4) run_item cmd_autostart_job_off ;;
			5) run_item cmd_autostart_check ;;
			*) err "Неверный пункт" ;;
		esac
		pause_menu
	done
}

cmd_lan_toggle() {
	load_config
	if [ "$BIND_MODE" = "lan" ]; then
		cmd_lan_off
	else
		cmd_lan_on
		if is_running && [ "$BIND_MODE" = "lan" ]; then cmd_links; fi
	fi
}

cmd_lan_on() {
	load_config
	if [ "$BIND_MODE" != "lan" ]; then
			warn "Прокси будет слушать 0.0.0.0:$PORT и станет доступен всем в этой сети."
			warn "ВНИМАНИЕ: трафик к прокси не зашифрован. Используйте только в доверенных сетях."
		ask "Продолжить?" || { msg "Отменено"; return 0; }
		set_config_value BIND_MODE lan
		ok "Раздача включена"
	else
		warn "Раздача уже включена"
	fi
	if is_running; then cmd_restart; else cmd_links; fi
	return 0
}

cmd_lan_off() {
	load_config
	set_config_value BIND_MODE local
	ok "Раздача выключена, только 127.0.0.1"
	is_running && cmd_restart
	return 0
}

# ============================================================
#  Удобство: алиас, watchdog, профили, бэкапы, статистика
# ============================================================

# Надёжный путь к самому себе (работает и при source, и при bash script.sh)
self_path() {
	local src="${BASH_SOURCE[0]:-$0}" real=""
	# если запустили через симлинк tgws — берём настоящий файл
	if command -v readlink >/dev/null 2>&1; then
		real="$(readlink -f "$src" 2>/dev/null || true)"
	fi
	if [ -n "$real" ] && [ -f "$real" ]; then
		printf '%s' "$real"
	else
		printf '%s/%s' "$(cd "$(dirname "$src")" && pwd)" "$(basename "$src")"
	fi
}

# ---------- 4. алиас tgws ----------
cmd_alias_install() {
	local self rc pfx target
	self="$(self_path)"
	pfx="${PREFIX:-/data/data/com.termux/files/usr}"
	target="$pfx/bin/tgws"

	# Старый alias из .bashrc убираем: он работал только в интерактивном bash
	rc="$HOME/.bashrc"
	if [ -f "$rc" ] && grep -q 'alias tgws=' "$rc" 2>/dev/null; then
		local tmp
		tmp="$(mk_tmp)"
		grep -v 'alias tgws=' "$rc" | grep -v '^# tg-ws-proxy manager$' > "$tmp" || true
		cat "$tmp" > "$rc"
		rm -f "$tmp"
		msg "Старый alias из .bashrc убран"
	fi

	if ln -sf "$self" "$target" 2>/dev/null; then
		chmod +x "$self" 2>/dev/null || true
		ok "Команда tgws готова: $target"
		msg "Работает сразу и в любой сессии, source не нужен"
		msg "tgws — меню, tgws start | tgws qr | tgws stats — команды"
	else
		err "Не смог создать $target"
		msg "Запускай по полному пути: bash $self"
		return 1
	fi
}

cmd_alias_remove() {
	local pfx="${PREFIX:-/data/data/com.termux/files/usr}"
	rm -f "$pfx/bin/tgws" 2>/dev/null || true
	ok "Команда tgws удалена"
	return 0
}

# ---------- 5. watchdog ----------
watchdog_running() { tmux has-session -t "$WATCHDOG_SESSION" 2>/dev/null; }

write_watchdog() {
	write_script "$WATCHDOG_SCRIPT" 700 <<'EOS'
INTERVAL="@@INTERVAL@@"
PORT="@@PORT@@"
SELF="@@SELF@@"
LOG="@@WDLOG@@"
RESTART_EVERY_H="@@RESTARTH@@"
export TMUX_TMPDIR="@@TMUXTMPDIR@@"
mkdir -p "@@TMUXTMPDIR@@" 2>/dev/null || true

# Бэкофф + 1 уведомление после 5 падений подряд, иначе вечный цикл жрёт батарею.
FAIL_THRESHOLD=5
FAIL_BACKOFF_CAP=10
NOTIFIED=0
FAILS=0

stamp() { date '+%Y-%m-%d %H:%M:%S'; }
alive() {
	if command -v nc >/dev/null 2>&1; then
		nc -z -w 3 127.0.0.1 "$PORT" >/dev/null 2>&1
		return $?
	fi
	if (exec 3<>"/dev/tcp/127.0.0.1/$PORT") 2>/dev/null; then
		exec 3>&- 3<&-
		return 0
	fi
	return 1
}

printf '%s watchdog старт, интервал %sс\n' "$(stamp)" "$INTERVAL" >> "$LOG"
START_TS="$(date +%s)"
while true; do
	sleep "$INTERVAL"
	now="$(date +%s)"
	# плановый перезапуск каждые RESTART_EVERY_H часов (0 = выкл)
	case "$RESTART_EVERY_H" in ''|*[!0-9]*) RESTART_EVERY_H=0 ;; esac
	if [ "$RESTART_EVERY_H" -gt 0 ] && [ $(( now - START_TS )) -ge $(( RESTART_EVERY_H * 3600 )) ]; then
		printf '%s плановый перезапуск (каждые %s ч)\n' "$(stamp)" "$RESTART_EVERY_H" >> "$LOG"
		bash "$SELF" restart >> "$LOG" 2>&1 || true
		START_TS="$(date +%s)"
		FAILS=0
		NOTIFIED=0
		continue
	fi
	if ! alive; then
		printf '%s порт %s не отвечает -> перезапуск\n' "$(stamp)" "$PORT" >> "$LOG"
		bash "$SELF" start >> "$LOG" 2>&1 || true
		if alive; then
			FAILS=0
			NOTIFIED=0
		else
			FAILS=$((FAILS + 1))
			printf '%s перезапуск не помог (подряд: %s)\n' "$(stamp)" "$FAILS" >> "$LOG"
			if [ "$FAILS" -ge "$FAIL_THRESHOLD" ]; then
				if [ "$NOTIFIED" -eq 0 ] && command -v termux-notification >/dev/null 2>&1; then
					termux-notification \
						--title "TG WS Proxy" \
						--content "Не поднимается уже $FAILS раз подряд — проверь логи: $LOG" \
						--priority high >/dev/null 2>&1 || true
					NOTIFIED=1
				fi
				# бэкофф: не долбим чаще, чем раз в FAIL_BACKOFF_CAP интервалов
				mult=$FAILS
				[ "$mult" -gt "$FAIL_BACKOFF_CAP" ] && mult="$FAIL_BACKOFF_CAP"
				sleep $(( INTERVAL * mult ))
			fi
		fi
	fi
done
EOS
}

watchdog_start() {
	load_config
	watchdog_running && { warn "Watchdog уже работает"; return 0; }
	write_watchdog
	tmux new-session -d -s "$WATCHDOG_SESSION" -- "$WATCHDOG_SCRIPT" \
		|| { err "tmux не создал сессию watchdog"; return 1; }
	set_config_value WATCHDOG_ENABLED 1
		ok "Watchdog включён: проверка каждые ${WATCHDOG_INTERVAL:-300} с"
	msg "Лог watchdog: $WATCHDOG_LOG"
}

watchdog_stop() {
	load_config
	if watchdog_running; then tmux kill-session -t "$WATCHDOG_SESSION" 2>/dev/null || true; fi
	set_config_value WATCHDOG_ENABLED 0
	ok "Watchdog выключен"
}

watchdog_toggle() {
	load_config
	if watchdog_running; then watchdog_stop; else watchdog_start; fi
}

# ---------- 6. проверка обновлений ----------
check_update() {
	load_config
	[ -d "$APP_DIR/.git" ] || { warn "Проект не установлен (пункт 1)"; return 1; }
	msg "Проверяю обновления..."
		git -C "$APP_DIR" fetch --quiet origin --tags 2>/dev/null \
		|| { warn "Не связался с origin — проверь интернет"; return 1; }
	local behind
	behind="$(git -C "$APP_DIR" rev-list --count "HEAD..${REPO_BRANCH:-v1.10.2}" 2>/dev/null || echo 0)"
	printf '%s\n' "${behind:-0}" > "$UPDATE_STATE" 2>/dev/null || true
	if [ "${behind:-0}" -gt 0 ]; then
		warn "Есть обновление: отстаём на $behind коммит(ов) — пункт 2"
		hr
		git -C "$APP_DIR" log --oneline -n 8 "HEAD..${REPO_BRANCH:-v1.10.2}" 2>/dev/null || true
		hr
	else
		ok "Установлена последняя версия"
	fi
}

update_badge() {
	local b
	b="$(cat "${UPDATE_STATE:-/dev/null}" 2>/dev/null || printf '0')"
	case "$b" in ''|*[!0-9]*) return 0 ;; esac
	[ "$b" -gt 0 ] && printf '  %s[есть обновление: %s]%s' "$C_YELLOW" "$b" "$C_RESET" || true
}

# ---------- 7. автотест доменов ----------
set_list() {
	local key="$1"; shift
	if [ "$#" -gt 0 ]; then set_array_value "$key" "$@"; else set_array_value "$key"; fi
}

cmd_test_domains() {
	load_config
	local d all=() alive=() dead=()
	for d in "${CF_WORKER_DOMAINS[@]:-}" "${CF_CUSTOM_DOMAINS[@]:-}"; do
		[ -n "$d" ] && all+=("$d")
	done
	[ "${#all[@]}" -eq 0 ] && { warn "Домены не заданы (настройки, пункты 7 и 8)"; return 0; }

	hr; msg "Проверяю ${#all[@]} домен(ов)"; hr
	for d in "${all[@]}"; do
		if probe http "https://$d" "$d"; then alive+=("$d"); else dead+=("$d"); fi
	done
	hr
	printf '  Живых: %s   Мёртвых: %s\n' "${#alive[@]}" "${#dead[@]}"

	if [ "${#dead[@]}" -gt 0 ] && [ "${#alive[@]}" -gt 0 ]; then
		if ask "Оставить в конфиге только живые?"; then
			local x w=() c=()
			for x in "${alive[@]}"; do
				if printf '%s\n' "${CF_WORKER_DOMAINS[@]:-}" | grep -qx -- "$x"; then w+=("$x"); else c+=("$x"); fi
			done
			set_list CF_WORKER_DOMAINS "${w[@]:+${w[@]}}"
			set_list CF_CUSTOM_DOMAINS "${c[@]:+${c[@]}}"
			ok "Списки обновлены"
		fi
	elif [ "${#alive[@]}" -eq 0 ]; then
		err "Живых доменов нет — проверь интернет или сами домены"
	fi
}

# ---------- 8. профили ----------
profile_current() { cat "$PROFILE_MARK" 2>/dev/null || printf 'default'; }
profile_names()   { mkdir -p "$PROFILE_DIR"; ls -1 "$PROFILE_DIR" 2>/dev/null | sed 's/\.conf$//'; return 0; }

profile_save() {
	local name="${1:-}"
	[ -n "$name" ] || { err "Пустое имя"; return 1; }
	case "$name" in *[!a-zA-Z0-9_-]*) err "Только латиница, цифры, - и _"; return 1 ;; esac
	mkdir -p "$PROFILE_DIR"
	cp "$CONFIG_FILE" "$PROFILE_DIR/$name.conf"
	chmod600 "$PROFILE_DIR/$name.conf"
	printf '%s' "$name" > "$PROFILE_MARK"
	ok "Профиль сохранён: $name"
}

profile_apply() {
	local name="${1:-}" f="$PROFILE_DIR/${1:-}.conf"
	[ -f "$f" ] || { err "Профиля нет: $name"; return 1; }
	mkdir -p "$PROFILE_DIR"
	cp "$CONFIG_FILE" "$PROFILE_DIR/.autosave.conf" 2>/dev/null || true
	cp "$f" "$CONFIG_FILE"
	chmod600 "$CONFIG_FILE"
	printf '%s' "$name" > "$PROFILE_MARK"
	load_config
	ok "Профиль применён: $name"
	if is_running; then msg "Перезапускаю под новый профиль..."; cmd_restart; fi
}

profile_preset() {
	case "${1:-}" in
		home)    set_config_value BIND_MODE lan;   set_config_value NET_IFACE wlan0; set_config_value LAN_IP "" ;;
		hotspot) set_config_value BIND_MODE lan;   set_config_value NET_IFACE ap0;   set_config_value LAN_IP "" ;;
		local)   set_config_value BIND_MODE local; set_config_value NET_IFACE "";    set_config_value LAN_IP "" ;;
		*) err "Неизвестный пресет"; return 1 ;;
	esac
	profile_save "$1"
	if is_running; then cmd_restart; fi
}

profile_menu() {
	menu_guard_on
	while true; do
		load_config || true
		cls
		local names=() n line i=0
		while IFS= read -r line; do [ -n "$line" ] && names+=("$line"); done <<EOF
$(profile_names)
EOF
		printf '%s=== Профили ===%s\nТекущий: %s%s%s\n\n' \
			"$C_BOLD" "$C_RESET" "$C_YELLOW" "$(profile_current)" "$C_RESET"
		if [ "${#names[@]}" -gt 0 ]; then
			printf 'Сохранённые:\n'
			for n in "${names[@]}"; do i=$((i+1)); printf '  %2d) %s\n' "$i" "$n"; done
			printf '\n'
		else
			printf 'Профилей пока нет\n\n'
		fi
		printf ' s) Сохранить текущий конфиг как профиль\n'
		printf ' d) Удалить профиль\n'
		printf ' b) Бэкап конфига в Загрузки\n'
		printf ' r) Восстановить конфиг из копии\n'
		printf ' 1p) Пресет home    (раздача через wlan0)\n'
		printf ' 2p) Пресет hotspot (раздача через ap0)\n'
		printf ' 3p) Пресет local   (только телефон)\n'
		printf '  0) Назад\n\nНомер профиля для переключения или команда: '

		local ch v; read_choice ch || { menu_guard_off; return 0; }
		[ "${ch:-0}" = "0" ] && { menu_guard_off; return 0; }
		printf '\n'
		(
			case "$ch" in
				s) printf 'Имя профиля: '; read -r v || true; profile_save "${v:-}" ;;
				d) printf 'Имя профиля: '; read -r v || true
				   [ -n "${v:-}" ] && rm -f "$PROFILE_DIR/$v.conf" && ok "Удалён: $v" ;;
				1p) profile_preset home ;;
				2p) profile_preset hotspot ;;
				3p) profile_preset local ;;
				b) cmd_backup ;;
				r) cmd_restore ;;
				*)
					if is_uint "$ch" && [ "$ch" -ge 1 ] && [ "$ch" -le "${#names[@]}" ]; then
						profile_apply "${names[$((ch-1))]}"
					else
						err "Неверный пункт"
					fi ;;
			esac
		) || true
		pause_menu
	done
}

# ---------- 9. бэкап и восстановление ----------
backup_dir() {
	if [ -d "$HOME/storage/downloads" ]; then printf '%s' "$HOME/storage/downloads"
	else printf '%s' "$HOME"; fi
}

cmd_backup() {
	load_config
	ensure_storage
	local dst
	dst="$(backup_dir)/tg-ws-proxy-backup-$(date '+%Y%m%d-%H%M').conf"
	cp "$CONFIG_FILE" "$dst" || { err "Не смог скопировать в $dst"; return 1; }
	chmod600 "$dst"
	ok "Бэкап: $dst"
	warn "В файле лежит secret — не выкладывай его в общий доступ"
	return 0
}

cmd_restore() {
	load_config
	local files=() f n=0 raw
	raw="$( { ls -1t "$(backup_dir)"/tg-ws-proxy-backup-*.conf 2>/dev/null || true
		   ls -1t "$PROFILE_DIR"/*.conf 2>/dev/null || true; } )"
	while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<EOF
$raw
EOF
	[ "${#files[@]}" -eq 0 ] && { warn "Бэкапов не найдено в $(backup_dir)"; return 0; }

	hr
	for f in "${files[@]}"; do n=$((n+1)); printf '  %2d) %s\n' "$n" "$f"; done
	hr
	printf 'Номер (0 — отмена): '
	local ch; read_choice ch || { msg "Отменено"; return 0; }
	[ "${ch:-0}" = "0" ] && { msg "Отменено"; return 0; }
	is_uint "$ch" && [ "$ch" -le "${#files[@]}" ] || { err "Неверный номер"; return 1; }

	cp "$CONFIG_FILE" "$CONFIG_DIR/.before-restore.conf" 2>/dev/null || true
	cp "${files[$((ch-1))]}" "$CONFIG_FILE"
	chmod600 "$CONFIG_FILE"
	load_config
	ok "Конфиг восстановлен"
	if is_running; then cmd_restart; fi
}

# ---------- 10. смена secret ----------
cmd_change_secret() {
	load_config
	hr
	warn "ВСЕ выданные ранее ссылки перестанут работать."
	printf '  Текущий secret: %s\n' "${SECRET:-<пусто>}"
	hr
	ask "Сгенерировать новый?" || { msg "Отменено"; return 0; }
	local sec; sec="$(generate_secret)"
	set_config_value SECRET "$sec"
	ok "Новый secret: $sec"
	if is_running; then msg "Перезапускаю..."; cmd_restart; else cmd_links; fi
}

# ---------- 11. кто подключён ----------
# Источник 1: таблица сокетов ядра (точный, но Android часто её прячет)
conns_from_proc() { proc_peers 2>/dev/null || true; }

# Источник 2: ss или netstat, если вдруг работают
conns_from_tools() {
	if command -v ss >/dev/null 2>&1; then
		ss -tn 2>/dev/null | awk -v p=":$PORT\$" 'NR>1 && $4 ~ p {print $5}' && return 0
	fi
	if command -v netstat >/dev/null 2>&1; then
		netstat -tn 2>/dev/null | awk -v p=":$PORT\$" '$4 ~ p && $6=="ESTABLISHED" {print $5}'
	fi
	return 0
}

# Источник 3: то же, что видно глазами — окно tmux и лог
conns_from_text() {
	tmux_buffer 2>/dev/null | extract_client_ips || true
	[ -s "$LOG_FILE" ] && tail -n 3000 "$LOG_FILE" | extract_client_ips || true
	return 0
}

# Соседи по сети: ip neigh на Android 11+ без root молчит, поэтому есть ARP
conns_neighbors() {
	local out=""
	if command -v ip >/dev/null 2>&1; then
		out="$(ip neigh show 2>/dev/null | awk '$1 !~ /:/ && $NF != "FAILED" {print "  " $1}' || true)"
	fi
	if [ -z "$out" ] && [ -r /proc/net/arp ]; then
		out="$(awk 'NR>1 && $1 ~ /^[0-9]/ && $4 != "00:00:00:00:00:00" {print "  " $1}' /proc/net/arp 2>/dev/null || true)"
	fi
	printf '%s' "$out"
}

# Печать списка "ip — сколько раз": conns_table <текст> <слово> [лимит]
conns_table() {
	local data="$1" word="$2" limit="${3:-100}"
	printf '%s\n' "$data" | sed 's/:[0-9]*$//' | grep -E '.' \
		| sort | uniq -c | sort -rn | head -n "$limit" \
		| while read -r cnt ip; do printf '  %-24s %s %s\n' "$ip" "$cnt" "$word"; done
}

cmd_conns() {
	load_config
	hr; msg "Подключения к порту $PORT"; hr

	local peers src=""
	peers="$(conns_from_proc)"
	[ -n "$peers" ] && src="/proc/net/tcp"
	if [ -z "$peers" ]; then
		peers="$(conns_from_tools)"
		[ -n "$peers" ] && src="ss/netstat"
	fi

	if [ -n "$peers" ]; then
		printf '%sЖивые соединения:%s\n' "$C_BOLD" "$C_RESET"
		conns_table "$peers" "подкл."
		printf '\n  Всего: %s   %s(источник: %s)%s\n' \
			"$(printf '%s\n' "$peers" | grep -c . || true)" "$C_DIM" "$src" "$C_RESET"
	else
		msg "Таблица сокетов пуста (Android её прячет) — смотрю лог и окно tmux"
		local clients
		clients="$(conns_from_text | grep -E '.' || true)"
		if [ -n "$clients" ]; then
			hr
			printf '%sКлиенты по активности в логе:%s\n' "$C_BOLD" "$C_RESET"
			conns_table "$clients" "упоминаний" 20
			printf '\n  Уникальных устройств: %s\n' \
				"$(printf '%s\n' "$clients" | sort -u | grep -c . || true)"
		else
			msg "Клиентов не вижу"
			is_running || warn "Прокси не запущен (пункт 3)"
			[ "${VERBOSE:-0}" = "1" ] || warn "Включи подробное логирование (настройки, пункт 9) — без него IP клиентов в лог не попадают"
			[ "$BIND_MODE" = "lan" ] || msg "Режим local — чужие устройства подключиться не могут"
		fi
	fi

	local neigh; neigh="$(conns_neighbors)"
	if [ -n "$neigh" ]; then
		hr
		printf '%sУстройства рядом в сети:%s\n' "$C_BOLD" "$C_RESET"
		printf '%s\n' "$neigh"
	fi
	hr
	return 0
}

# ---------- 12. аптайм и статистика лога ----------
cmd_stats() {
	load_config
	hr; msg "Статистика"; hr
	if is_running; then
		local created now up
		created="$(tmux display-message -p -t "$SESSION_NAME" '#{session_created}' 2>/dev/null || echo 0)"
		now="$(date +%s)"
		case "$created" in ''|*[!0-9]*) created=0 ;; esac
		if [ "$created" -gt 0 ]; then
			up=$(( now - created ))
			printf '  Аптайм:       %sд %sч %sм\n' "$((up/86400))" "$(((up%86400)/3600))" "$(((up%3600)/60))"
		fi
		ok "Прокси запущен"
	else
		warn "Прокси не запущен"
	fi

	if [ -s "$LOG_FILE" ]; then
		printf '  Размер лога:  %s\n' "$(du -h "$LOG_FILE" 2>/dev/null | cut -f1)"
		printf '  Ошибок:       %s\n' "$(grep -ci 'error' "$LOG_FILE" 2>/dev/null || echo 0)"
		printf '  Предупреждений: %s\n' "$(grep -ci 'warn' "$LOG_FILE" 2>/dev/null || echo 0)"
		printf '  CF fallback:  %s\n' "$(grep -ci 'cfproxy\|fallback' "$LOG_FILE" 2>/dev/null || echo 0)"
		hr
		printf '%sПоследние ошибки:%s\n' "$C_BOLD" "$C_RESET"
		grep -i 'error' "$LOG_FILE" 2>/dev/null | tail -n 5 || true
	else
		warn "Лог пуст"
	fi

	hr
	if watchdog_running; then
			ok "Watchdog активен (каждые ${WATCHDOG_INTERVAL:-300} с)"
		[ -s "$WATCHDOG_LOG" ] && tail -n 3 "$WATCHDOG_LOG"
	else
		msg "Watchdog выключен"
	fi
	hr
}

# Мониторинг одним пунктом меню: кто подключён + статистика
cmd_monitoring() {
	cmd_conns
	cmd_stats
}

# ============================================================
#  Тесты
# ============================================================

# probe port <host> <порт> [подпись]  — TCP-проверка
# probe http <url>  [подпись]        — HTTP-проверка
# 0 = живо, 1 = нет. Все таймауты и формат вывода заданы здесь один раз.
probe() {
	case "$1" in
		port)
			local host="$2" port="$3" label="${4:-Порт}"
			if tcp_open "$host" "$port" "$((TCP_TIMEOUT + 2))"; then
				ok "$label — $host:$port доступен"; return 0
			fi
			err "$label — $host:$port недоступен"; return 1 ;;
		http)
			local url="$2" label="${3:-$2}" code
			command -v curl >/dev/null 2>&1 || { warn "$label — нет curl (pkg install curl)"; return 1; }
			code="$(curl -s -o /dev/null -w '%{http_code}' -I \
				--connect-timeout "$((TCP_TIMEOUT + 5))" --max-time "$HTTP_TIMEOUT" "$url" 2>/dev/null || printf '000')"
			code="${code##*$'\n'}"; code="${code:0:3}"; code="${code:-000}"
			case "$code" in
				000) err  "$label — нет ответа"; return 1 ;;
				5*)  warn "$label — HTTP $code";  return 1 ;;
				*)   ok   "$label — HTTP $code";  return 0 ;;
			esac ;;
		*) err "probe: неизвестный тип проверки '$1'"; return 1 ;;
	esac
}

test_port() { probe port "$1" "$2" "$3"; }
test_http() { probe http "$1" "${2:-$1}"; }

cmd_test_local() { load_config; test_port 127.0.0.1 "$PORT" "Локальный порт"; }

cmd_test_lan() {
	load_config
	local lan; lan="$(detect_lan_ip)"
	[ -n "$lan" ] || die "IP не определён"
	[ "$BIND_MODE" = "lan" ] || warn "BIND_MODE=local — снаружи недоступен по определению"
	test_port "$lan" "$PORT" "Внешний порт"
	msg "С другого устройства проверь: nc -vz $lan $PORT"
}

cmd_test_dc() {
	load_config
	local rule fail=0
	for rule in "${DC_IP_RULES[@]:-}"; do
		[ -z "$rule" ] && continue
		test_port "${rule#*:}" 443 "DC${rule%%:*}" || fail=1
	done
	return "$fail"
}

cmd_test_ws() {
	load_config
	local rule dc fail=0
	for rule in "${DC_IP_RULES[@]:-}"; do
		[ -z "$rule" ] && continue
		dc="${rule%%:*}"
		test_http "https://kws${dc}.web.telegram.org" || fail=1
	done
	return "$fail"
}

cmd_test_cf() {
	load_config
	[ "${CF_PROXY_ENABLED:-1}" = "1" ] || warn "CF fallback выключен в конфиге"
	test_http "https://cloudflare.com" || true
	local d had=0
	for d in "${CF_CUSTOM_DOMAINS[@]:-}"; do
		[ -n "$d" ] && { test_http "https://$d" || true; }
	done
	for d in "${CF_WORKER_DOMAINS[@]:-}"; do
		[ -n "$d" ] && { had=1; test_http "https://$d" || true; }
	done
	[ "$had" = "0" ] && msg "Worker-домены не заданы (пункт настроек 8)"
	msg "Встроенный пул CF-доменов ядро обновляет с GitHub раз в час"
}

cmd_test_all() {
	hr; msg "Полная проверка"; hr
	cmd_test_local || true; cmd_test_lan || true
	cmd_test_dc || true; cmd_test_ws || true; cmd_test_cf || true
	hr
}

cmd_doctor() {
	check_termux; load_config
	hr; msg "Диагностика"; hr
	local c
	for c in git python tmux curl openssl pgrep nc; do
		command -v "$c" >/dev/null 2>&1 && ok "$c: $(command -v "$c")" || err "$c: нет"
	done
	[ -d "$APP_DIR" ] && ok "Проект: $APP_DIR" || err "Проекта нет"
	[ -s "$APP_DIR/proxy/tg_ws_proxy.py" ] && ok "Ядро: proxy/tg_ws_proxy.py" || err "Ядро не найдено"
	[ "${USE_VENV:-0}" = "1" ] && { [ -d "$VENV_DIR" ] && ok "venv: $VENV_DIR" || err "venv включен, но не создан"; }

	local py pyver; py="$(python_bin)"
	pyver="$("$py" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null || echo '?')"
	if "$py" -c 'import sys;sys.exit(0 if sys.version_info>=(3,8) else 1)' 2>/dev/null; then
		ok "Python $pyver (проекту нужен >= 3.8)"
	else
		err "Python $pyver — проекту нужен >= 3.8"
	fi
	"$py" -c "import cryptography" 2>/dev/null && ok "cryptography импортируется" || err "cryptography НЕ импортируется"
	command -v termux-wake-lock >/dev/null 2>&1 && ok "termux-wake-lock есть" || warn "Нет termux-wake-lock (pkg install termux-tools)"
	msg "Оптимизацию батареи для Termux Android не даёт проверить программно — открой пункт 19 и проверь глазами"
	[ -f "$JOB_MARK" ] && ok "Резервный автозапуск через планировщик Android включён" || warn "Резервный автозапуск через планировщик выключен (пункт 15)"
	command -v qrencode >/dev/null 2>&1 && ok "qrencode есть" || msg "qrencode не стоит (поставится при первом QR)"
	[ -f "$BOOT_SCRIPT" ] && ok "Автозапуск включён" || msg "Автозапуск выключен"

	is_secret "${SECRET:-}" && ok "Secret валиден (32 hex)" || warn "Secret невалиден"
	is_running && ok "tmux-сессия активна" || warn "tmux-сессии нет"
	port_busy && msg "Порт $PORT занят" || msg "Порт $PORT свободен"
	[ -d "$HOME/storage" ] && ok "Доступ к памяти телефона есть" || warn "Нет ~/storage (termux-setup-storage)"
	[ -d "$APP_DIR/.git" ] && ok "Ревизия: $(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null)"

	hr
	printf '%sИнтерфейсы:%s\n' "$C_BOLD" "$C_RESET"
	list_interfaces | while IFS="$(printf '\t')" read -r i p; do printf '  %-12s %s\n' "$i" "$p"; done
	hr
}

cmd_py_help() {
	load_config
	[ -s "$APP_DIR/proxy/tg_ws_proxy.py" ] || die "Ядро не найдено"
	(cd "$APP_DIR" && "$(python_bin)" -m proxy.tg_ws_proxy --help) || warn "--help не отработал"
}

cmd_uninstall() {
	load_config
	warn "Будет удалён каталог: $APP_DIR"
	ask "Продолжить?" || { msg "Отменено"; return 0; }
	is_running && stop_proxy
	force_kill quiet
	safe_app_dir
	rm -rf "$APP_DIR"; ok "Проект удалён"
	if ask "Удалить конфиг и логи?"; then
		rm -rf "$CONFIG_DIR" "$STATE_DIR"; ok "Удалены"
	fi
}

# ============================================================
#  Меню настроек
# ============================================================

ask_value() {
	# приглашение — в stderr: stdout забирает вызывающий через $(...) только под ввод
	printf '%s\nТекущее: %s%s%s\nНовое (Enter — не менять): ' "$1" "$C_YELLOW" "${2:-<пусто>}" "$C_RESET" >&2
	local v; read -r v || true; printf '%s' "${v:-}"
}

edit_dc_rules() {
	load_config; hr
	printf '%sТекущие правила DC -> IP:%s\n' "$C_BOLD" "$C_RESET"
	local r; for r in "${DC_IP_RULES[@]:-}"; do printf '  %s\n' "$r"; done
	hr
	printf 'Вводи правила по одному (формат N:IP). Пустая строка — конец.\n'
	printf 'Дефолт проекта: 2:149.154.167.220 и 4:149.154.167.220\n\n'
	local new=() line
	while true; do
		printf '> '; read -r line || break
		[ -z "$line" ] && break
		if [[ "$line" =~ ^[0-9]+:([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then new+=("$line")
		else err "Формат N:IP"; fi
	done
	if [ "${#new[@]}" -gt 0 ]; then set_dc_rules "${new[@]}"; ok "Правила обновлены"
	else warn "Без изменений"; fi
}

# Редактирование списка доменов через ввод через запятую
edit_domain_list() {
	local key="$1" label="$2"; shift 2
	local cur="$*" v item items=() cleaned=()

	hr
	printf '%s%s%s\nТекущие: %s%s%s\n\n' "$C_BOLD" "$label" "$C_RESET" "$C_YELLOW" "${cur:-<нет>}" "$C_RESET"
	printf 'Введи домены через запятую.\n'
	printf 'Enter — не менять, символ "-" — очистить список.\n> '
	read -r v || true

	[ -z "$v" ] && { warn "Без изменений"; return 0; }
	if [ "$v" = "-" ]; then set_array_value "$key"; ok "Список очищен"; return 0; fi

	IFS=',' read -r -a items <<< "$v"
	for item in "${items[@]}"; do
		item="$(printf '%s' "$item" | tr -d ' \t' | sed -E 's#^https?://##; s#/+$##')"
		[ -n "$item" ] && cleaned+=("$item")
	done

	if [ "${#cleaned[@]}" -eq 0 ]; then err "Ничего не распознал"; return 1; fi
	set_array_value "$key" "${cleaned[@]}"
	ok "Сохранено: ${cleaned[*]}"
}

# Таблица настроек: подпись|тип|переменная|подсказка. Порядок = номера пунктов. См. docs/commands.md.
readonly CONFIG_ITEMS=(
	"Режим доступа|mode|BIND_MODE|"
	"Порт|uint:1:65535|PORT|Порт (1-65535)"
	"Secret (32 hex)|secret|SECRET|Secret (ровно 32 hex)"
	"Интерфейс / IP|act:choose_interface|NET_IFACE|"
	"Правила DC -> IP|act:edit_dc_rules|DC_IP_RULES|"
	"CF fallback|bool|CF_PROXY_ENABLED|"
	"Свои CF-домены|list|CF_CUSTOM_DOMAINS|Свои Cloudflare-домены"
	"CF Worker домены|list|CF_WORKER_DOMAINS|Cloudflare Worker домены"
	"Verbose (IP клиентов в лог)|bool|VERBOSE|"
	"Буфер, КБ|uint:1:65536|BUF_KB|Буфер, КБ"
	"Пул WS-сессий|uint:0:64|POOL_SIZE|Пул WS на DC (0 = без пула)"
	"Макс. размер лога, МБ|float|LOG_MAX_MB|Макс. лог, МБ"
	"Копий лога|uint:1:100|LOG_BACKUPS|Копий лога (минимум 1)"
	"Использовать venv|bool|USE_VENV|При включении запусти установку заново"
	"Доп. аргументы|text|EXTRA_ARGS|Доп. аргументы"
	"Fake TLS (SNI-домен)|domain|FAKE_TLS_DOMAIN|SNI-домен (пусто = выключить, напр. www.cloudflare.com)"
	"Тестовые ДЦ Telegram|warn|FORCE_TEST_DC|Тестовые ДЦ — только для отладки. Обычный Telegram через них НЕ работает."
	"PROXY protocol v1|warn|PROXY_PROTOCOL|Нужно только за nginx/haproxy. На телефоне сломает подключения."
	"Wake-lock при старте|bool|WAKE_LOCK|Без него Android может усыпить прокси"
	"Копировать ссылку в буфер|bool|CLIPBOARD_COPY|Нужен Termux:API; иначе просто не скопируется"
	"Плановый перезапуск, ч|uint:0:168|RESTART_EVERY_H|Перезапуск каждые N часов, 0 = выкл (применится после рестарта watchdog)"
	"Интервал проверки watchdog, с|uint:15:3600|WATCHDOG_INTERVAL|Как часто watchdog проверяет порт"
	"Сгенерировать Secret|act:regen_secret||"
	"Открыть конфиг в редакторе|act:edit_config_file||"
	"Показать команду запуска|act:show_command_block||"
	"Показать --help проекта|act:cmd_py_help||"
)

# Точки-заполнитель до заданной ширины (считаем символы, а не байты)
pad_dots() {
	local text="$1" width="${2:-32}" len n out=""
	len="$(printf '%s' "$text" | wc -m | tr -d ' ')"
	n=$(( width - len )); [ "$n" -lt 1 ] && n=1
	out="$(printf '%*s' "$n" '')"
	printf '%s' "${out// /.}"
}

onoff() { [ "${1:-0}" = "1" ] && printf 'вкл' || printf 'выкл'; }

# Текущее значение для правого столбца меню
config_item_value() {
	local kind="$1" var="$2"
	case "$kind" in
		bool|warn) onoff "${!var:-0}" ;;
		mode) printf '%s' "${BIND_MODE:-local}" ;;
		list)
			local -n arr="$var"
			[ "${#arr[@]}" -eq 0 ] && printf '<нет>' || printf '%s' "${arr[*]}" ;;
		act:choose_interface) printf '%s -> %s' "${NET_IFACE:-авто}" "${LAN_IP:-авто}" ;;
		act:edit_dc_rules) printf '%s шт.' "${#DC_IP_RULES[@]}" ;;
		act:*) printf '' ;;
		*) printf '%s' "${!var:-<пусто>}" ;;
	esac
}

# Обработка выбранного пункта: валидация живёт в одном месте
config_item_apply() {
	local kind="$1" var="$2" hint="$3" label="$4" v
	case "$kind" in
		mode)
			printf '\n1) local (только этот телефон)\n2) lan (раздавать в сеть)\nВыбор: '
			read -r v || true
			case "$v" in
				1) set_config_value BIND_MODE local; ok "Режим: local" ;;
				2) cmd_lan_on ;;
				*) err "Неверный выбор" ;;
			esac ;;
		bool)
			if [ "${!var:-0}" = "1" ]; then
				set_config_value "$var" 0; msg "$label: выкл"
				[ -n "$hint" ] && warn "$hint"
			else
				set_config_value "$var" 1; ok "$label: вкл"
			fi ;;
		warn)
			if [ "${!var:-0}" = "1" ]; then
				set_config_value "$var" 0; ok "$label: выкл"
			else
				warn "$hint"
				if ask "Всё равно включить?"; then
					set_config_value "$var" 1; ok "$label: вкл"
				else msg "Отменено"; fi
			fi ;;
		uint:*)
			local lo hi rest="${kind#uint:}"; lo="${rest%%:*}"; hi="${rest##*:}"
			v="$(ask_value "$hint" "${!var}")"
			[ -z "$v" ] && { msg "Не изменено"; return 0; }
			if is_uint "$v" && [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ]; then
				set_config_value "$var" "$v"; ok "$label: $v"
			else err "Нужно целое число от $lo до $hi"; fi ;;
		float)
			v="$(ask_value "$hint" "${!var}")"
			[ -z "$v" ] && { msg "Не изменено"; return 0; }
			if is_float "$v"; then set_config_value "$var" "$v"; ok "$label: $v"
			else err "Нужно число, напр. 5 или 2.5"; fi ;;
		secret)
			v="$(ask_value "$hint" "${!var}")"
			[ -z "$v" ] && { msg "Не изменено"; return 0; }
			if is_secret "$v"; then set_config_value "$var" "$v"; ok "Secret обновлён"
			else err "Нужно ровно 32 hex-символа"; fi ;;
		domain)
			warn "Fake TLS меняет ссылку: secret станет ee-формата."
			v="$(ask_value "$hint" "${!var}")"
			v="$(printf '%s' "$v" | tr -d ' \t' | sed -E 's#^https?://##; s#/+$##')"
			set_config_value "$var" "$v"
			[ -n "$v" ] && ok "Fake TLS включён: $v" || ok "Fake TLS выключен" ;;
		text)
			v="$(ask_value "$hint" "${!var}")"
			set_config_value "$var" "$v"; ok "$label обновлены" ;;
		list)
			local -n arr="$var"
			edit_domain_list "$var" "$hint" "${arr[@]:-}" ;;
		act:*)
			"${kind#act:}" ;;
		*) err "Неизвестный тип настройки: $kind" ;;
	esac
}

# Мелкие действия меню настроек
regen_secret() {
	warn "Новый Secret сломает все старые ссылки."
	ask "Продолжить?" || { msg "Отменено"; return 0; }
	local sec; sec="$(generate_secret)"
	set_config_value SECRET "$sec"; ok "Новый Secret: $sec"
	if is_running && ask "Перезапустить прокси?"; then cmd_restart; fi
	return 0
}
# Редактор для конфига: что задано в $EDITOR, иначе первый найденный
pick_editor() {
	local e
	for e in "${EDITOR:-}" nano vim vi micro; do
		[ -n "$e" ] || continue
		command -v "$e" >/dev/null 2>&1 && { printf '%s' "$e"; return 0; }
	done
	return 1
}

edit_config_file() {
	local e
	if ! e="$(pick_editor)"; then
		err "Редактор не найден"
		msg "Установи: pkg install nano"
		msg "Файл конфига: $CONFIG_FILE"
		return 1
	fi
	"$e" "$CONFIG_FILE"
	CONFIG_LOADED=0
	return 0
}
show_command_block() { hr; show_command; hr; }

config_menu() {
	menu_guard_on
	local n total="${#CONFIG_ITEMS[@]}"
	while true; do
		load_config force || { err "Конфиг не читается"; pause_menu; return 1; }
		cls
		printf '%s=== Настройки tg-ws-proxy ===%s\n\n' "$C_BOLD" "$C_RESET"

		local item label kind var value dots
		for n in $(seq 1 "$total"); do
			IFS='|' read -r label kind var _ <<< "${CONFIG_ITEMS[$((n-1))]}"
			value="$(config_item_value "$kind" "$var")"
			dots="$(pad_dots "$label" 32)"
			if [ -n "$value" ]; then
				printf ' %2d) %s %s %s%s%s\n' "$n" "$label" "$dots" "$C_YELLOW" "$value" "$C_RESET"
			else
				printf ' %2d) %s\n' "$n" "$label"
			fi
		done
		printf '  0) Назад\n\nВыбор: '

		local ch; read_choice ch || { menu_guard_off; return 0; }
		[ "${ch:-0}" = "0" ] && { menu_guard_off; return 0; }
		printf '\n'
		if ! is_uint "$ch" || [ "$ch" -lt 1 ] || [ "$ch" -gt "$total" ]; then
			err "Неверный пункт"; pause_menu; continue
		fi

		local hint
		IFS='|' read -r label kind var hint <<< "${CONFIG_ITEMS[$((ch-1))]}"
		( config_item_apply "$kind" "$var" "$hint" "$label" ) || true
		pause_menu
	done
}

tests_menu() {
	menu_guard_on
	while true; do
		cls
		printf '%s=== Тесты ===%s\n\n' "$C_BOLD" "$C_RESET"
		printf '  1) Все тесты\n  2) Локальный порт\n  3) Доступность из сети\n'
		printf '  4) Telegram DC (IP:443)\n  5) WS-домены kwsN.web.telegram.org\n'
		printf '  6) Cloudflare и Worker\n  7) Автотест доменов (с чисткой)\n'
		printf '  0) Назад\n\nВыбор: '
		local ch; read_choice ch || { menu_guard_off; return 0; }
		[ "$ch" = "0" ] && { menu_guard_off; return 0; }
		printf '\n'
		case "$ch" in
			1) run_item cmd_test_all ;;   2) run_item cmd_test_local ;;
			3) run_item cmd_test_lan ;;   4) run_item cmd_test_dc ;;
			5) run_item cmd_test_ws ;;    6) run_item cmd_test_cf ;;
			7) run_item cmd_test_domains ;;
			*) err "Неверный пункт" ;;
		esac
		pause_menu
	done
}

main_menu() {
	menu_guard_on
	while true; do
		load_config || { err "Конфиг не читается: $CONFIG_FILE"; pause_menu; }
		cls
		printf '%s╔══════════════════════════════════════╗%s\n' "$C_CYAN" "$C_RESET"
		printf '%s║      TG WS PROXY — Termux Manager    ║%s\n' "$C_CYAN" "$C_RESET"
		printf '%s╚══════════════════════════════════════╝%s\n' "$C_CYAN" "$C_RESET"
		is_running \
			&& printf ' Статус: %sзапущен%s  |  %s:%s\n' "$C_GREEN" "$C_RESET" "$(bind_host)" "$PORT" \
			|| printf ' Статус: %sостановлен%s  |  %s:%s\n' "$C_RED" "$C_RESET" "$(bind_host)" "$PORT"
		printf ' Профиль: %-17s Watchdog: %s%s\n' \
			"$(profile_current)" "$(watchdog_running && echo вкл || echo выкл)" "$(update_badge)"
		printf ' Режим:  %-18s Интерфейс: %s\n\n' \
			"$([ "$BIND_MODE" = lan ] && echo 'раздача в сеть' || echo 'только телефон')" "${NET_IFACE:-авто}"

		printf '  1) Установить\n  2) Обновить\n  3) Запустить\n  4) Остановить\n  5) Перезапустить\n'
		printf '  6) Статус\n  7) Логи\n  8) Подключиться к tmux\n  9) Настройки\n 10) Ссылки и QR\n'
		printf ' 11) Тесты\n 12) Диагностика\n 13) Переустановить (secret сохранится)\n'
		printf ' 14) Удалить\n'
		printf ' 15) Автозапуск при загрузке: %s\n' "$(autostart_state)"
		printf ' 16) Мониторинг (кто подключён + статистика)\n'
		printf ' 17) Watchdog (автоперезапуск): %s\n' "$(watchdog_running && echo вкл || echo выкл)"
		printf ' 18) Профили и бэкапы\n'
		printf ' 19) Батарея и фон (важно!)\n'
			printf '  0) Выход\n\nВыбор: '

		local ch; read_choice ch || { menu_guard_off; ok "Выход"; return 0; }; printf '\n'
		case "$ch" in
			0) menu_guard_off; ok "Выход"; exit 0 ;;
			9)  config_menu; menu_guard_on; continue ;;
			11) tests_menu;  menu_guard_on; continue ;;
			1)  run_item cmd_install ;;   2)  run_item cmd_update ;;
			3)  run_item start_proxy ;;   4)  run_item stop_proxy ;;
			5)  run_item cmd_restart ;;   6)  run_item cmd_status ;;
			7)  run_item cmd_logs ;;      8)  run_item cmd_attach ;;
			10) run_item cmd_links_qr ;;
			12) run_item cmd_doctor ;;    13) run_item cmd_reinstall ;;
			14) run_item cmd_uninstall ;;
			15) autostart_menu; menu_guard_on; continue ;;
			16) run_item cmd_monitoring ;;
			17) run_item watchdog_toggle ;;
			18) profile_menu; menu_guard_on; continue ;;
			19) run_item cmd_battery_all ;;
			*) err "Неверный пункт" ;;
		esac
		printf '\nEnter — в меню...'; read -r _ || true
	done
}

# ============================================================
#  CLI: одна таблица на весь разбор команд и справку
#  имена (через пробел) | функция | группа | описание
# ============================================================

# Тонкие обёртки: каждой команде — ровно одна точка входа
cmd_config()          { check_termux; load_config; config_menu; }
cmd_edit()            { load_config; edit_config_file; }
cmd_iface()           { choose_interface; }
cmd_detect_ip()       { load_config; detect_lan_ip; printf '\n'; }
cmd_gen_secret()      { load_config; local sec; sec="$(generate_secret)"; set_config_value SECRET "$sec"; ok "Secret: $sec"; }
cmd_force_kill()      { load_config; force_kill; }
cmd_show_command()    { load_config; show_command; }
cmd_storage()         { ensure_storage; }
cmd_start()           { start_proxy; }
cmd_stop()            { stop_proxy; }
cmd_check_update()    { check_update; }
cmd_watchdog_on()     { watchdog_start; }
cmd_watchdog_off()    { watchdog_stop; }
cmd_watchdog_status() { load_config; if watchdog_running; then ok "Watchdog активен"; else msg "Watchdog выключен"; fi; }
cmd_battery_settings()   { check_battery_optimization; }
cmd_miui_help()          { show_miui_help; }

# Батарея одним пунктом меню: настройки + памятка MIUI
cmd_battery_all() {
	check_battery_optimization
	hr
	show_miui_help
}
cmd_profile_list()    { load_config; local n; n="$(profile_names)"; [ -n "$n" ] && printf '%s\n' "$n" || msg "Профилей пока нет (создать: profile-save <имя>)"; return 0; }
cmd_profile_save()    { load_config; profile_save "${1:-}"; }
cmd_profile_use()     { load_config; profile_apply "${1:-}"; }

readonly COMMANDS=(
	"install|cmd_install|Установка|скачать и настроить проект"
	"update|cmd_update|Установка|обновить ядро до свежего коммита"
	"self-update|cmd_self_update|Установка|обновить сам менеджер"
	"reinstall|cmd_reinstall|Установка|переустановить (secret сохраняется)"
	"uninstall|cmd_uninstall|Установка|удалить проект"
	"storage|cmd_storage|Установка|дать доступ к памяти телефона"

	"start|cmd_start|Запуск|запустить прокси в tmux"
	"stop|cmd_stop|Запуск|остановить"
	"restart|cmd_restart|Запуск|перезапустить"
	"status|cmd_status|Запуск|текущее состояние"
	"logs|cmd_logs|Запуск|смотреть лог"
	"attach|cmd_attach|Запуск|войти в окно tmux"
	"force-kill|cmd_force_kill|Запуск|прибить зависшие процессы"
	"clear-logs|cmd_clear_logs|Запуск|очистить лог"

	"link links|cmd_links|Клиенты|ссылки подключения"
	"qr|cmd_qr|Клиенты|QR-код со ссылкой"
	"conns|cmd_conns|Клиенты|кто подключён"
	"stats|cmd_stats|Клиенты|аптайм и статистика лога"

	"lan-on|cmd_lan_on|Сеть|раздавать в локальную сеть"
	"lan-toggle|cmd_lan_toggle|Сеть|переключить раздачу (вкл/выкл)"
	"lan-off|cmd_lan_off|Сеть|только 127.0.0.1"
	"iface|cmd_iface|Сеть|выбрать интерфейс (wlan0/ap0)"
	"detect-ip|cmd_detect_ip|Сеть|показать определённый IP"

	"config|cmd_config|Конфиг|меню настроек"
	"edit|cmd_edit|Конфиг|открыть конфиг в редакторе"
	"show-command|cmd_show_command|Конфиг|показать итоговую команду запуска"
	"gen-secret|cmd_gen_secret|Конфиг|сгенерировать secret"
	"new-secret|cmd_change_secret|Конфиг|сменить secret с подтверждением"
	"backup|cmd_backup|Конфиг|сохранить копию конфига"
	"restore|cmd_restore|Конфиг|восстановить из копии"
	"profile-list|cmd_profile_list|Конфиг|список профилей"
	"profile-save|cmd_profile_save|Конфиг|сохранить профиль: profile-save <имя>"
	"profile-use|cmd_profile_use|Конфиг|применить профиль: profile-use <имя>"

	"autostart-on|cmd_autostart_on|Автозапуск|включить через Termux:Boot"
	"autostart-off|cmd_autostart_off|Автозапуск|выключить Termux:Boot"
	"autostart-check|cmd_autostart_check|Автозапуск|проверить честно, без перезагрузки"
	"autostart-job-on|cmd_autostart_job_on|Автозапуск|резерв через планировщик Android"
	"autostart-job-off|cmd_autostart_job_off|Автозапуск|выключить планировщик"
	"watchdog-on|cmd_watchdog_on|Автозапуск|следить и поднимать упавший прокси"
	"watchdog-off|cmd_watchdog_off|Автозапуск|выключить watchdog"
	"watchdog-status|cmd_watchdog_status|Автозапуск|состояние watchdog"
		"battery-settings|cmd_battery_settings|Автозапуск|открыть настройки батареи (исключить из оптимизации)"
		"miui-help|cmd_miui_help|Автозапуск|памятка MIUI 12.5: автозапуск, замок и батарея"
		"alias|cmd_alias_install|Автозапуск|короткая команда tgws"
	"alias-remove|cmd_alias_remove|Автозапуск|убрать команду tgws"

	"test|cmd_test_all|Тесты|все проверки подряд"
	"test-local|cmd_test_local|Тесты|локальный порт"
	"test-lan|cmd_test_lan|Тесты|доступность из сети"
	"test-dc|cmd_test_dc|Тесты|ДЦ Telegram"
	"test-ws|cmd_test_ws|Тесты|WS-домены Telegram"
	"test-cf|cmd_test_cf|Тесты|Cloudflare и Worker-домены"
	"test-domains|cmd_test_domains|Тесты|автотест всех доменов из конфига"
	"doctor|cmd_doctor|Тесты|диагностика окружения"
	"py-help|cmd_py_help|Тесты|--help самого ядра"
	"check-update|cmd_check_update|Тесты|есть ли обновления в репозитории"

	"help -h --help|usage|Прочее|эта справка"
)

# Имя команды -> функция (пусто, если команды нет)
command_fn() {
	local want="$1" row names fn
	for row in "${COMMANDS[@]}"; do
		IFS='|' read -r names fn _ _ <<< "$row"
		case " $names " in *" $want "*) printf '%s' "$fn"; return 0 ;; esac
	done
	return 1
}

usage() {
	printf 'TG WS Proxy Manager (Termux)\n\n'
	printf '  %s              интерактивное меню\n' "$(basename "$0")"
	printf '  %s <команда>\n' "$(basename "$0")"
	local row names fn group desc last=""
	for row in "${COMMANDS[@]}"; do
		[ -z "$row" ] && continue
		IFS='|' read -r names fn group desc <<< "$row"
		if [ "$group" != "$last" ]; then
			printf '\n%s%s%s\n' "$C_BOLD" "$group" "$C_RESET"
			last="$group"
		fi
		printf '  %-20s %s\n' "$names" "$desc"
	done
	printf '\n'
}

main() {
	if [ "$#" -eq 0 ]; then check_termux; load_config; main_menu; return 0; fi
	local fn cmd="$1"; shift
	if fn="$(command_fn "$cmd")"; then
		"$fn" "$@"
		return 0
	fi
	err "Неизвестная команда: $cmd"
	printf '\n'
	usage
	exit 1
}

main "$@"
