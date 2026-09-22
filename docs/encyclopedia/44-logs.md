# Логи Mihomo: уровни, MetaCubeXD и безопасная диагностика

Логи нужны, чтобы ответить на конкретный вопрос: **что ядро сделало с соединением и почему**, а не для постоянного просмотра каждой строки.

## `log-level`

~~~yaml
log-level: warning
~~~

Практические уровни: `silent`, `error`, `warning`, `info`, `debug`. Для обычной эксплуатации на роутере нет смысла постоянно держать `debug`: он увеличивает поток сообщений и нагрузку.

## Страница «Журнал» в MetaCubeXD

Она получает live log stream через Controller API. Панель умеет искать, ставить отображение на паузу, копировать/скачивать выборку, сортировать и менять runtime log level.

Пауза UI не останавливает Mihomo — только отображение. Разбор: [40-interfejs-metacubexd.md](40-interfejs-metacubexd.md).

## Runtime level ≠ файл `config.yaml`

Изменение уровня через API относится к живому процессу и не обязано переписывать `/opt/etc/mihomo/config.yaml`. Если настройка должна пережить restart, проверяйте файл.

## Что искать

При проблеме с сайтом смотрите правило/группу, DNS error, timeout, TLS/network error и ошибку соединения с proxy. Сверяйте [30-rules.md](30-rules.md), [29-proxy-groups.md](29-proxy-groups.md) и [26-dns-i-fake-ip.md](26-dns-i-fake-ip.md).

Для provider проверяйте health-check/test URL/timeout и ошибки загрузки: [42-proxy-providers.md](42-proxy-providers.md).

После переключения старое TCP-соединение может продолжать жить; страницу «Соединения» используйте для проверки chain.

## Логи Mihomo ≠ watchdog log

Watchdog — отдельный компонент. Его история рестартов анализируется Doctor'ом.

| Вопрос | Источник |
| --- | --- |
| почему watchdog решил рестартовать | watchdog log / Doctor |
| почему proxy получил timeout | Mihomo log |
| какая группа выбрана | Controller / MetaCubeXD |
| состояние ProxyN/DNS/MagiTrickle | Doctor + Keenetic |

## Приватность

Логи могут раскрывать домены, IP, имена групп/узлов и LAN-адреса. Перед публикацией очищайте чувствительные данные. Doctor специально агрегирует диагностику вместо вывода сырого конфига/секретов.

## `debug` на слабом роутере

Включайте `debug` только для конкретной ошибки, воспроизведите её, соберите короткий фрагмент и верните `warning` или `info`. Это особенно важно на 256 MB-классе.

## Куда идти дальше

- [40-interfejs-metacubexd.md](40-interfejs-metacubexd.md) — экран журнала.
- [41-controller-api-security.md](41-controller-api-security.md) — API и безопасность.
- [30-rules.md](30-rules.md) — маршрутизация.
- [42-proxy-providers.md](42-proxy-providers.md) — providers.
