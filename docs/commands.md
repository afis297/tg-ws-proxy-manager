# Команды и меню

Интерактивное меню: `tg-ws-proxy-manager.sh` без аргументов (или `tgws`).
Неинтерактивно: `tgws <команда>`. Справка: `tgws help`.

`Ctrl+C` внутри меню возвращает в меню, из просмотра логов — тоже в меню.
`Ctrl+D` / EOF — выход.

## Главное меню (19 пунктов)

Все функции доступны и через CLI — из меню убраны только дубли настроек
и одноразовые действия (ставятся/спрашиваются при установке).

| № | Пункт | CLI-эквивалент |
|---|-------|----------------|
| 1 | Установить (ставит пакеты, даёт доступ к памяти, ставит алиас `tgws`) | `install` |
| 2 | Обновить (сначала показывает, что изменилось) | `update` |
| 3 | Запустить | `start` |
| 4 | Остановить | `stop` |
| 5 | Перезапустить | `restart` |
| 6 | Статус | `status` |
| 7 | Логи (`tail -f`, после выхода предлагает очистить) | `logs` |
| 8 | Подключиться к tmux | `attach` |
| 9 | Настройки | `config` |
| 10 | Ссылки и QR | `link`, `qr` |
| 11 | Тесты (подменю) | `test`, `test-local`, `test-lan`, `test-dc`, `test-ws`, `test-cf`, `test-domains` |
| 12 | Диагностика | `doctor` |
| 13 | Переустановить (secret сохраняется) | `reinstall` |
| 14 | Удалить | `uninstall` |
| 15 | Автозапуск (подменю) | `autostart-on/off/check`, `autostart-job-on/off`, см. [autostart](autostart.md) |
| 16 | Мониторинг (кто подключён + статистика) | `conns`, `stats` |
| 17 | Watchdog | `watchdog-on/off/status` |
| 18 | Профили и бэкапы (подменю, вкл. бэкап/восстановление) | `profile-list/save/use`, `backup`, `restore` |
| 19 | Батарея и фон (настройки + памятка MIUI) | `battery-settings`, `miui-help` |
| 0 | Выход | — |

## Все CLI-команды по группам

Установка: `install`, `update`, `self-update` (сам менеджер: `git pull` в клоне, иначе скачивание raw с GitHub с проверкой `bash -n`), `reinstall`, `uninstall`, `storage`.
Запуск: `start`, `stop`, `restart`, `status`, `logs`, `attach`, `force-kill`, `clear-logs`.
Клиенты: `link` (= `links`), `qr`, `conns`, `stats`.
Сеть: `lan-on`, `lan-toggle`, `lan-off`, `iface`, `detect-ip`.
Конфиг: `config`, `edit`, `show-command`, `gen-secret`, `new-secret`,
`backup`, `restore`, `profile-list`, `profile-save <имя>`, `profile-use <имя>`.
Автозапуск: `autostart-on`, `autostart-off`, `autostart-check`,
`autostart-job-on`, `autostart-job-off`, `watchdog-on`, `watchdog-off`,
`watchdog-status`, `battery-settings`, `miui-help`, `alias`, `alias-remove`.
Тесты: `test` (все), `test-local`, `test-lan`, `test-dc`, `test-ws`,
`test-cf`, `test-domains`, `doctor`, `py-help`, `check-update`.

## Подменю настроек (пункт 9)

Порядок = порядок в меню: режим доступа, порт, secret, интерфейс/IP,
правила DC, CF fallback, свои CF-домены, Worker-домены, verbose,
буфер, пул WS, размер/копии лога, venv, доп. аргументы, Fake TLS,
тестовые ДЦ, PROXY protocol, wake-lock, плановый перезапуск,
интервал watchdog, генерация secret, редактор конфига, команда запуска,
`--help` ядра. Значения всех пунктов — в [конфиге](config.md).

## Подменю тестов (пункт 11)

`test-local` — TCP порт на 127.0.0.1; `test-lan` — порт на определённом LAN IP;
`test-dc` — `IP:443` каждого DC из правил; `test-ws` — `https://kwsN.web.telegram.org`;
`test-cf` — cloudflare.com + свои/Worker-домены; `test-domains` — автотест доменов
из конфига с предложением выкинуть мёртвые.

## Кто подключён и статистика

`conns`: сначала живые соединения (`/proc/net/tcp`, иначе `ss`/`netstat`),
если таблица сокетов пуста (Android её часто прячет) — активность клиентов
по tmux-буферу и логу + устройства рядом (`ip neigh` / `/proc/net/arp`).
Без `VERBOSE=1` IP клиентов в лог не попадают.
`stats`: аптайм tmux-сессии, размер лога, счётчики error/warn/CF-fallback,
последние ошибки, состояние watchdog.
