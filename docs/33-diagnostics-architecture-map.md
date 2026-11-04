# 33 — Карта диагностических инструментов KAS (issue #327/#323/#266/#270, сводка)

**Назначение документа:** зафиксировать, какой инструмент для чего существует, где границы, и почему KAS не превращается в набор дублирующихся Doctor-скриптов. Документ — карта, не фреймворк: общий код не выделяется, пока дублирование не доказано полевыми отказами (Proof Before Build).

## Инструменты и их единственная ответственность

| Инструмент | Вопрос пользователя | Сетевые пробы | Системные изменения |
|---|---|---|---|
| `mihomo-doctor.sh` (offline Doctor) | «Корректно ли установлена и связана моя KAS/Mihomo/MagiTrickle-конфигурация?» | **Нет** (только локальные read-only наблюдения: процессы, конфиги, ndmc, ipset/iptables-инвентаризация) | Нет |
| [Network Doctor](29-network-doctor.md) (`kas-network-doctor.sh`) | «Почему этот сайт недоступен?» — DNS, TCP, TLS, HTTP и наблюдения egress с роутера | Да, по явному запуску и с ограниченным бюджетом | Наблюдает сеть. При явном `--json FILE` пишет отчёт |
| [Download Doctor](27-download-check.md) (`kas-download-check.sh`) | «Почему не скачивается bootstrap/install/config-import?» (DNS/TCP/TLS/CA/redirect по путям GitHub) | Да, к URL доставки. Опциональная проба MOSHUB использует заданный URL | Нет |
| [Router Metrics](30-sys-metrics.md) (`kas-sys-metrics.sh`) | «Какова загрузка/температура/память роутера сейчас?» | Нет | Нет |
| `kas-entware-preflight.sh` (Draft [#367](https://github.com/saymer-alt/keenetic-auto-setup/pull/367)) | «Целы ли /opt/bin/sh, busybox, апплеты, wget, opkg?» | Локальные пробы бинарников | Предлагается диагностика с ручным восстановлением |
| `mihomo-route-check.sh`, `mihomo-interface-check.sh` | Узкие проверки маршрута и интерфейсов Mihomo | Route Check может выполнить HTTP(S)-пробу через SOCKS5h. Interface Check анализирует локальные данные | Нет |
| Web adapter (проект [#382](https://github.com/saymer-alt/keenetic-auto-setup/pull/382)) | «Проверить сайт из панели» через Network Doctor | Предусмотрен вызов CLI | Проект контракта |

**Правило различения:** если вопрос про *доставку пакетов до цели* — Network/Download Doctor; если про *состояние установки и конфигурации* — offline Doctor/preflight; если про *ресурсы роутера* — Metrics. Инструмент не перетягивает чужие вопросы: egress-доказательство не появляется в offline Doctor, а инвентаризация ipset не появляется в Network Doctor (там только MagiTrickle-факты, нужные для интерпретации пробы).

## Контракты переиспользования (уже реализованные)

- **`network-diagnostics/v1`** — текущий JSON-контракт Network Doctor. В `main` поле `vantage` описывает наблюдения с роутера. Выбор интерфейса и массив `vantages[]` предложены в Draft [#376](https://github.com/saymer-alt/keenetic-auto-setup/pull/376).
- **Marker-блоки** (`# BEGIN/END ... v1`) — способ делить код между скриптами без общего source. Lifecycle lock и process state уже используются, init resolution предложен в Draft [#366](https://github.com/saymer-alt/keenetic-auto-setup/pull/366).
- Статусы и exit-коды определяет контракт каждого инструмента. Например, Network Doctor использует `INCONCLUSIVE` с exit 3, а Entware preflight в Draft #367 использует exit 2 для `UNKNOWN` при отсутствии `FAIL`.
- **CLI-цвета и префиксы** (docs/18) — presentation-only; семантика в префиксах.

## Границы доказательности (общие для всех)

- Router-side наблюдение не доказывает путь LAN-клиента (`client.vantage` = NOT TESTED).
- `ip global`, LISTEN и `curl --interface` не доказывают маршрут; доказательство — только фактический egress (`route proof: egress-distinct`).
- Один тайм-аут не доказывает DPI/блокировку; вердикт называет только подтверждённую ступень, остальное — гипотезы (H:).
- `mihomo -t` валидирует конфиг, не эффективный packet path; полевая приёмка — отдельный owner-GO этап.

## Что сознательно НЕ делается

- Никакого «диагностического фреймворка»/общей библиотеки: расшаривание кода через marker-блоки дешевле, чем новый слой абстракций, а дублирование пока гипотетическое.
- Никаких фоновых демонов мониторинга: все сетевые пробы — явные запуски.
- Никаких авто-исправлений в диагностиках: Doctor/preflight/Network Doctor только наблюдают и советуют.
