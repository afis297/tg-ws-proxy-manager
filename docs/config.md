# Конфиг и сеть

Файл: `~/.config/tg-ws-proxy/tg-ws-proxy.conf`, права `600` (внутри secret).
Создаётся автоматически при первом запуске; недостающие ключи старого
конфига добираются из значений по умолчанию. Править можно через пункт
`9) Настройки`, командой `tgws edit` или руками в редакторе.

## Все ключи

| Ключ | По умолчанию | Что значит |
|------|--------------|------------|
| `REPO_URL` | `https://github.com/Flowseal/tg-ws-proxy.git` | откуда клонировать ядро |
| `REPO_BRANCH` | `v1.10.2` | зафиксированная версия (защита от supply chain) |
| `APP_DIR` | `~/tg-ws-proxy` | каталог ядра (в конфиг пишется явно) |
| `USE_VENV` | `0` | `1` — запуск в `venv` (`--system-site-packages`); после включения переустановить (п.1) |
| `BIND_MODE` | `local` | `local` — только `127.0.0.1`; `lan` — `0.0.0.0`, раздача в сеть |
| `PORT` | `1443` | порт прокси, 1–65535 (ниже 1024 Android без root не даст) |
| `SECRET` | (пусто → генерируется) | ровно 32 hex-символа |
| `LAN_IP` | (авто) | IP для ссылок; принимается, только если реально есть на интерфейсах |
| `NET_IFACE` | (авто) | предпочитаемый интерфейс (`wlan0`, `ap0`, `rmnet_data0`...) |
| `DC_IP_RULES` | `2:149.154.167.220`, `4:149.154.167.220` | маршруты на ДЦ Telegram, формат `N:IP` |
| `CF_PROXY_ENABLED` | `1` | `0` — передать ядру `--no-cfproxy` |
| `CF_CUSTOM_DOMAINS` | (пусто = встроенный пул ядра) | свои CF-домены (`--cfproxy-domain`, повторяемый) |
| `CF_WORKER_DOMAINS` | (пусто) | Worker-домены, пробуются раньше остальных (`--cfproxy-worker-domain`) |
| `FAKE_TLS_DOMAIN` | (выкл) | SNI-домен (`--fake-tls-domain`, напр. `www.cloudflare.com`); ссылка становится `ee`-формата |
| `FORCE_TEST_DC` | `0` | `--force-test-dc`; только для отладки, обычный Telegram через тестовые ДЦ не работает |
| `PROXY_PROTOCOL` | `0` | только за nginx/haproxy; на телефоне сломает подключения |
| `WAKE_LOCK` | `1` | брать `termux-wake-lock` при старте, иначе система усыпит прокси |
| `CLIPBOARD_COPY` | `1` | копировать ссылку в буфер (нужен Termux:API); ссылка содержит secret — чужие приложения могут читать буфер |
| `WATCHDOG_ENABLED` | `0` | фоновая проверка и автоперезапуск (см. [autostart](autostart.md)) |
| `WATCHDOG_INTERVAL` | `300` | интервал проверки watchdog, сек (15–3600) |
| `RESTART_EVERY_H` | `0` | плановый рестарт каждые N часов, `0` — выкл (выполняет watchdog; новое значение — после его перезапуска) |
| `VERBOSE` | `0` | `-v`; без него IP клиентов в лог не попадают |
| `BUF_KB` | `256` | `--buf-kb` |
| `POOL_SIZE` | `4` | `--pool-size` (0 — без пула) |
| `LOG_MAX_MB` | `5` | `--log-max-mb` |
| `LOG_BACKUPS` | `1` | `--log-backups`, минимум 1 (требование ядра) |
| `EXTRA_ARGS` | (пусто) | дополнительные флаги ядра; разбираются с учётом кавычек (`--foo "bar baz"` — один аргумент). Сверять через `py-help` |

## Сеть и ссылки

- `detect-ip` / выбор интерфейса в настройках (пункт `9`): определение IP идёт каскадом —
  python ioctl → `ip` → `ifconfig` → Termux:API → адрес активного маршрута.
  Рут нигде не нужен (на Android 11+ `ip addr` требует root, ioctl — нет).
- Приоритет выбора IP: `NET_IFACE` → точка доступа (`ap*`) → Wi-Fi (`wlan*`) → любой.
- Ссылка: `https://t.me/proxy?server=IP&port=PORT&secret=...`.
  Обычный режим — `dd` + secret; Fake TLS — `ee` + secret + hex(SNI-домена).
- `lan-on` предупреждает: трафик к прокси не зашифрован, только доверенные сети.
- QR (`qr`): сначала `qrencode`, fallback — python-модуль `qrcode` через pip.

## Secret

Генерируется через `openssl rand -hex 16`, fallback — `/dev/urandom`.
`gen-secret` — молча записать новый; `new-secret` — с подтверждением
(все старые ссылки умрут) и перезапуском. Валидация: ровно 32 hex.

## Профили и бэкапы

- Профили (`profile-save <имя>`, `profile-use`, `profile-list`):
  копии конфига в `~/.config/tg-ws-proxy/profiles/`, имя — латиница/цифры/`-`/`_`.
  Пресеты: `home` (lan+wlan0), `hotspot` (lan+ap0), `local`.
  Применение на лету перезапускает прокси.
- Бэкап (`backup`): копия в `~/storage/downloads/` (или `$HOME` без доступа
  к памяти), имя `tg-ws-proxy-backup-ГГГГММДД-ЧЧММ.conf`. Внутри secret —
  не выкладывать в общий доступ.
- Восстановление (`restore`): выбор из бэкапов и профилей; текущий конфиг
  перед заменой копируется в `.before-restore.conf`.

## Где что лежит

- Конфиг: `~/.config/tg-ws-proxy/` (+ `profiles/`, `current_profile`).
- Состояние: `~/.local/state/tg-ws-proxy/` — `proxy.log`, `run.args`, `run.sh`,
  `watchdog.sh`/`watchdog.log`, `boot-job.sh`, `boot.log`, `pane-died.sh`,
  `netinfo.py`, `manual_stop`, `job.enabled`, `update_state`.
- Автозапуск: `~/.termux/boot/10-tg-ws-proxy.sh`.
- Алиас: `$PREFIX/bin/tgws` (симлинк на сам скрипт).
