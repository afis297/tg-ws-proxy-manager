# tg-ws-proxy manager для Termux

Менеджер MTProto-прокси [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy)
на телефоне с Android: установка, запуск в `tmux`, ссылки `t.me/proxy`,
раздача в локальную сеть, автозапуск после перезагрузки, watchdog,
тесты и диагностика. Один файл: `tg-ws-proxy-manager.sh`.

Подробно:

- [Команды и меню](docs/commands.md) — весь CLI и все 19 пунктов меню.
- [Конфиг и сеть](docs/config.md) — каждый ключ конфига, secret, DC, Cloudflare, Fake TLS, профили, бэкапы.
- [Автозапуск и watchdog](docs/autostart.md) — Termux:Boot, планировщик Android, watchdog, wake-lock.
- [Диагностика и проблемы](docs/troubleshooting.md) — батарея, MIUI, Doze, логи, FAQ.

## Требования

- Телефон с Android + [Termux](https://termux.dev/) (F-Droid-версия).
- Интернет для установки пакетов и клонирования репозитория.
- Необязательно, но нужно для отдельных фич (всё из F-Droid, не из Google Play):
  - Termux:Boot — автозапуск после перезагрузки телефона.
  - Termux:API (приложение + `pkg install termux-api`) — wake-lock,
    буфер обмена, планировщик Android, уведомления watchdog.

Root не нужен.

## Установка

С GitHub (рекомендуется — так работают обновления через пункт `2`):

```sh
pkg install -y git
git clone https://github.com/afis297/tg-ws-proxy-manager.git ~/tg-ws-manager
chmod +x ~/tg-ws-manager/tg-ws-proxy-manager.sh
~/tg-ws-manager/tg-ws-proxy-manager.sh
```

Или одним файлом вручную:

```sh
termux-setup-storage
cp ~/storage/downloads/tg-ws-proxy-manager.sh ~
chmod +x ~/tg-ws-proxy-manager.sh
~/tg-ws-proxy-manager.sh
```

В меню: пункт `1) Установить`. Скрипт сам поставит пакеты
(`git python tmux curl procps nano openssl`, `python-cryptography`),
склонирует `tg-ws-proxy` в `~/tg-ws-proxy` (ветка `v1.10.2`),
создаст конфиг и сгенерирует secret.

Короткая команда `tgws` ставится автоматически при установке:

```sh
tgws            # интерактивное меню
tgws status     # состояние
tgws qr         # QR-код ссылки
```

## Первый запуск

1. Пункт `1) Установить`.
2. Пункт `3) Запустить`.
3. Пункт `6) Статус` — проверить, что слушает `127.0.0.1:1443`.
4. Пункт `9) Настройки` → «Режим доступа» → `lan`, если нужен доступ
   с других устройств в той же сети.
5. Пункт `15) Автозапуск` — включить, чтобы переживало перезагрузку.
6. Пункт `19) Батарея и фон` — исключить Termux из оптимизации,
   иначе прошивка убьёт прокси в фоне (см. [диагностику](docs/troubleshooting.md)).

## Как это устроено (кратко)

- Прокси работает в `tmux`-сессии `tgwsproxy`, watchdog — в `tgwsproxydog`.
- Конфиг: `~/.config/tg-ws-proxy/tg-ws-proxy.conf` (права `600`, там secret).
- Состояние и логи: `~/.local/state/tg-ws-proxy/` (`proxy.log`, `watchdog.log`, `boot.log`).
- Команда запуска собирается из конфига и кладётся в `run.args`/`run.sh`
  (по одному аргументу на строку — пробелы в доменах ничего не ломают).
- Ссылка формата `https://t.me/proxy?server=IP&port=1443&secret=...`,
  где secret — `dd` + 32 hex, а при включённом Fake TLS — `ee` + secret + hex домена.

## Обновление и удаление

- Пункт `2) Обновить` / `tgws update` — `git fetch` + перезапуск.
  Локальные правки в `~/tg-ws-proxy` блокируют автообновление (скрипт предупредит).
- Пункт `14) Переустановить` — каталог проекта удаляется и клонируется заново,
  конфиг и secret сохраняются. Есть защита от удаления опасных путей.
- Пункт `17) Удалить` — удаляет проект, конфиг и логи — только по запросу.
