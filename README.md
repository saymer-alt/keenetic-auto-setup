# Keenetic Auto Setup

Набор POSIX-скриптов, превращающий Keenetic-роутер с Entware в самонастраивающийся шлюз: прокси-ядро Mihomo (Clash Meta), DNS-сплит-роутинг MagiTrickle, автоматический VoIP-обход и watchdog, который сам перезапускает Mihomo при сбое.

Русский — основной язык документации. Английская версия этого README: [docs/EN/README.md](docs/EN/README.md); английское руководство — [docs/HOWTO.md](docs/HOWTO.md).

## Что это

После установки на роутере работают:

| Компонент | Роль |
| --- | --- |
| **Mihomo** (Clash Meta) | прокси-ядро: rule-based маршрутизация исходящего трафика (VLESS/Reality, подписки, группы). Управляется конфигом `/opt/etc/mihomo/config.yaml` |
| **Proxy-интерфейс Keenetic** (`ProxyN`) | мост Keenetic → Mihomo: SOCKS5-подключение к `127.0.0.1:7890` |
| **MagiTrickle** | DNS-сплит-роутинг: по домену решает, какой трафик и куда направить |
| **bypass_wa** | политика + firewall-хук: VoIP-трафик (Telegram/WhatsApp/WebRTC, UDP 1400/3478/3482) идёт через проектный Proxy-интерфейс, минуя DNS-классификацию |
| **Watchdog** | cron каждые 5 минут: проверяет WAN, порт 7890 и сквозной туннель; перезапускает Mihomo только когда сломан именно он |
| **S00ubifs** (режим `ram`) | переносит `/opt/tmp`, `/opt/var/log`, `/opt/var/run` в tmpfs, защищая флеш-память |

Требования: Keenetic с установленной Entware, доступ в интернет, SSH. Минимум 256 МБ RAM — 128 МБ не поддерживаются, tmpfs дестабилизирует такие устройства ([docs/09-limitations.md](docs/09-limitations.md)). Архитектуры: aarch64, armv7, mipsel, mips.

## Как установить

SSH на роутер. Установка во внутреннюю память (по умолчанию):

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh
```

Установка на USB/SSD-накопитель — добавьте аргумент `disk`:

```bash
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/install.sh | sh -s -- disk
```

- режим `ram` (по умолчанию) включает tmpfs-защиту флеша; `disk` — отключает её (для накопителя);
- Entware установщик не ставит — предполагается, что она уже развёрнута ([docs/HOWTO_RU.md](docs/HOWTO_RU.md), раздел 2);
- повторный запуск идемпотентен: установленные компоненты пропускаются, пользовательские настройки не перезаписываются ([docs/HOWTO_RU.md](docs/HOWTO_RU.md), раздел 3.3).

## Что происходит при установке

1. Обновление opkg, установка базовых пакетов (`curl`, `jq`, `nano`, `ca-bundle`, `cron`).
2. Создание политики `bypass_wa`, если её ещё нет.
3. Включение перехвата транзитного DNS (`dns-proxy intercept enable`) — чтобы классические DNS-запросы клиентов попадали в MagiTrickle. Это не защита от DoH/DoT.
4. Только в режиме `ram` — установка tmpfs-скрипта S00ubifs.
5. Установка Mihomo из пакетного репозитория [saymer-alt/entware-go](https://github.com/saymer-alt/entware-go/releases).
6. **Bootstrap `config.yaml`**: если рабочего конфига нет — создаётся минимальный с `mixed-port: 7890`. Существующий пользовательский конфиг никогда не изменяется.
7. **Выбор проектного Proxy-интерфейса**: инсталлятор сам находит или создаёт проектный Proxy-интерфейс Keenetic. Если существующий `Proxy0` принадлежит другой конфигурации, он его не изменяет, а использует первый свободный `ProxyN`.

   > Proxy0 на живом роутере нередко принадлежит чему-то ещё: прошлому эксперименту, другому набору скриптов или просто человеку, который однажды тоже решил «быстро проверить». Установщик не угадывает, чей он: не совпали описание и порт — Proxy0 объявляется чужим и обходится стороной.

8. **Привязка `bypass_wa`**: политика автоматически направляется через выбранный проектный Proxy-интерфейс.
9. Установка MagiTrickle и VoIP-хука `020-bypass_wa.sh`.
10. Установка watchdog в cron (каждые 5 минут).
11. Перезапуск Mihomo и самопроверка: `[OK] Done` — готово; `[WARN]` — установлено, но есть на что посмотреть (раздел «Диагностика»); `[FAIL]` — установка не завершена, смотрите текст проверки.

## Как настроить Mihomo

Без рабочего конфига прокси не работает: bootstrap только поднимает контрактный порт. Замените `/opt/etc/mihomo/config.yaml` своим конфигом:

```bash
nano /opt/etc/mihomo/config.yaml
```

Минимальный рабочий пример:

```yaml
mixed-port: 7890
mode: rule
log-level: info

proxies:
  - name: "server"
    type: vless
    server: "YOUR_SERVER"
    port: 443
    uuid: "YOUR_UUID"
    tls: true

proxy-groups:
  - name: "Proxy"
    type: select
    proxies: ["server"]

rules:
  - GEOIP,private,DIRECT
  - MATCH,Proxy
```

Собрать конфиг можно в браузере: [saymer-alt/link-generators](https://github.com/saymer-alt/link-generators) — клиентское веб-приложение без сервера.

**Mihomo использует фиксированный локальный порт `127.0.0.1:7890`.** Это контракт проекта: на нём слушает Mihomo, на него смотрят Proxy-интерфейс и watchdog. Выбрать другой порт нельзя.

> Параметра `--port` не будет. Это не злой умысел, а контракт: `7890` согласован между компонентами проекта, и плодить ещё одну точку рассинхронизации никто не собирается.

Проверка и применение:

```bash
mihomo -t -f /opt/etc/mihomo/config.yaml   # валидация без запуска
/opt/etc/init.d/S99mihomo restart
/opt/etc/init.d/S99mihomo status
```

Веб-панель (MetaCubeX) по умолчанию не устанавливается; как включить — [docs/encyclopedia/12-pervyj-vhod-v-ui.md](docs/encyclopedia/12-pervyj-vhod-v-ui.md).

## bypass_wa

Звонки в Telegram/WhatsApp и WebRTC (UDP-порты 1400, 3478, 3482) выводятся из DNS-классификации MagiTrickle: firewall-хук помечает этот трафик, а политика `bypass_wa` направляет его через проектный Proxy-интерфейс в Mihomo — дальше трафик идёт по правилам Mihomo.

- привязка выполняется автоматически при установке;
- если вы вручную привязали `bypass_wa` к своему VPN-интерфейсу, установка добавит проектный Proxy в политику, но не удалит и не переупорядочет вашу привязку;
- механизм и типичные проблемы: [docs/05-bypass-wa.md](docs/05-bypass-wa.md).

> Историческая справка: раньше политика `bypass_wa` создавалась пустой, и её предлагалось вручную навести на VPN. Теперь установщик делает это сам; ручная привязка по-прежнему допустима и не будет уничтожена.

## Проверка после установки

```bash
/opt/etc/init.d/S99mihomo status                # сервис запущен
curl -sS -o /dev/null -w '%{http_code}\n' --proxy 127.0.0.1:7890 http://google.com/generate_204
cat /opt/var/log/mihomo_watchdog.log            # через ~5 минут: "[OK] All good"
```

Ожидаемый код ответа — `204`: запрос действительно прошёл через локальный прокси.

Watchdog проверяет по порядку: доступность WAN напрямую (Cloudflare/Google; при их недоступности — fallback-список gosuslugi/ya.ru/mail.ru/vk, отличающий ограниченную сеть от полного отсутствия интернета), локальный порт 7890, сквозной запрос через SOCKS5. Если WAN недоступен — Mihomo не перезапускается: нет сети ≠ сломан Mihomo. Рестарт выполняется только при подтверждённой сети и подтверждённой проблеме в Mihomo, с паузой 300 секунд между рестартами. Детали: [docs/04-watchdog.md](docs/04-watchdog.md).

## Обновление

Обновление Mihomo до свежего релиза (ARM; на MIPS намеренно отказывается — официальных бинарников для MIPS не существует):

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/update-mihomo.sh | sh
```

Скрипт скачивает бинарник в `/tmp`, проверяет его и совместимость с вашим `config.yaml`, заменяет и перезапускает сервис; на любом сбое — автоматический откат. `--force` переустанавливает ту же версию. Ручная процедура для особых случаев: [mihomo_manual_update_arm.md](mihomo_manual_update_arm.md).

Watchdog обновляется отдельно (`update-watchdog.sh`). Внимание: он обновляет копию в `/opt/bin/mihomo_watchdog.sh`, тогда как установщик кладёт её в `/opt/etc/cron.5mins/mihomo_watchdog`. Перед обновлением проверьте, какой путь реально исполняется: `grep mihomo_watchdog /opt/etc/crontab`.

> Классическая ошибка — обновить копию в `/opt/bin`, а исполняется cron.5mins. Сверяйтесь с crontab до обновления, а не после.

## Диагностика

| Что смотреть | Команда |
| --- | --- |
| Статус Mihomo | `/opt/etc/init.d/S99mihomo status` |
| Решения watchdog | `cat /opt/var/log/mihomo_watchdog.log` |
| Валидность конфига | `mihomo -t -f /opt/etc/mihomo/config.yaml` |
| Слушается ли 7890 | `netstat -tln \| grep 7890` |
| Свободное место и RAM | `df -h /opt`, `free` |
| Время (сбитое время ломает SSL) | `date` |
| WAN-интерфейсы для `interface-name` | `sh mihomo-interface-check.sh` |

Типовые предупреждения самопроверки:

- `Port 7890 not listening` — Mihomo не запустился, либо в конфиге нет `mixed-port: 7890`;
- `Low free space on /opt` — свободно меньше 32 МБ;
- `bypass_wa policy has no interface permit` — у политики нет выхода;
- `Mihomo config syntax check failed` — конфиг не проходит `mihomo -t`.

Полный разбор «симптом → причина → решение»: [docs/08-troubleshooting.md](docs/08-troubleshooting.md) и [docs/HOWTO_RU.md](docs/HOWTO_RU.md), разделы 11–12.

## Документация

| Документ | О чём |
| --- | --- |
| [ARCHITECTURE.md](ARCHITECTURE.md) | как устроена маршрутизация: три пути трафика, роли Keenetic/MagiTrickle/Mihomo, границы схемы |
| [docs/HOWTO_RU.md](docs/HOWTO_RU.md) / [docs/HOWTO.md](docs/HOWTO.md) | полное руководство: подготовка, установка, конфигурация, MagiTrickle, обновления, откат, диагностика |
| [docs/encyclopedia/00-karta-sistemy.md](docs/encyclopedia/00-karta-sistemy.md) | энциклопедия Mihomo для новичков: карта системы, панель, DNS/fake-ip, правила, TUN |
| [docs/03-install.md](docs/03-install.md) | что именно делает install.sh |
| [docs/04-watchdog.md](docs/04-watchdog.md) | устройство watchdog |
| [docs/05-bypass-wa.md](docs/05-bypass-wa.md) | VoIP-обход подробно |
| [docs/06-s00ubifs.md](docs/06-s00ubifs.md) | tmpfs-профили и лимиты RAM |
| [docs/07-install.md](docs/07-install.md) | установщики и их различия |
| [docs/08-troubleshooting.md](docs/08-troubleshooting.md) | симптом → причина → решение |
| [docs/09-limitations.md](docs/09-limitations.md) | жёсткие ограничения проекта |
| [docs/10-roadmap.md](docs/10-roadmap.md) | планы развития |
| [CHANGELOG.md](CHANGELOG.md) | история изменений |

## Ограничения и важные особенности

- **RAM**: минимум 256 МБ; на устройствах со 128 МБ установка не поддерживается.
- **MTU туннелей**: «всё медленно / часть сайтов не открывается» — почти всегда MTU, а не маршрутизация; рабочие значения 1200–1300 ([docs/09-limitations.md](docs/09-limitations.md)).
- **IPv6** выключен намеренно: MagiTrickle и конфиги проекта рассчитаны на IPv4-схему ([ARCHITECTURE.md](ARCHITECTURE.md)).
- **DoH/DoT** клиентов проходит мимо перехвата: классифицируется только классический DNS на порту 53.
- **Логи в RAM** (режим `ram`) пропадают при перезагрузке — осознанный размен ради ресурса флеш-памяти.
- **Весь трафик не идёт через прокси**: часть трафика всегда ходит напрямую — это основа схемы, а не ошибка ([ARCHITECTURE.md](ARCHITECTURE.md)).

## Legacy

`install_7621.sh` — отдельный установщик для старых устройств на MT7621/mipsel: не ставит MagiTrickle и VoIP-обход. Ставит меньше, доверяет серверу больше. Используйте его, только если универсальный `install.sh` на устройстве не проходит; отличия описаны в [docs/07-install.md](docs/07-install.md).

## Лицензия

[MIT](LICENSE)
