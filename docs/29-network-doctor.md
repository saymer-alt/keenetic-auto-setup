# Сетевой Doctor: каскадная диагностика по одной цели

`kas-network-doctor.sh` — автономный диагностический инструмент этапов сети (issues [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#166](https://github.com/saymer-alt/keenetic-auto-setup/issues/166), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270)). В отличие от обычного Doctor, этот инструмент **сам выполняет сетевые пробы** — и делает это только когда пользователь явно его запустил. Для одной заданной цели он проходит цепочку доставки **DNS → TCP → TLS → HTTP**, затем показывает фактический адрес выхода (egress), локальный путь Mihomo (порт 7890, read-only запросы к Controller, проба SOCKS5h) и read-only сведения MagiTrickle/Keenetic (ProxyN).

Обычный `mihomo-doctor.sh` остаётся локальным и офлайн-безопасным: внешних проб он по-прежнему не делает. `mihomo-route-check.sh` продолжает работать как узкая точечная проверка одного сайта.

## Что инструмент делает и чего не делает

- Ничего не меняет: DNS, маршруты, firewall, интерфейсы, ProxyN, политики, Mihomo, MagiTrickle и конфигурация не затрагиваются; проверка сертификатов никогда не отключается.
- Бюджет запросов: **≤ 12 небольших запросов** за запуск (DNS-запросы считаются), каждый ограничен `--connect-timeout 6` / таймаутом 15 с / `--max-filesize 256 KiB`. Счётчик показывается в отчёте и JSON.
- Секрет `MIHOMO_API_SECRET` **никогда не выводится**; выбранное имя прокси-сервера скрывается («selected leaf (name withheld)»); сырые строки running-config не печатаются (только сводка сопоставления). Аргументы curl в журнале санитизируются (Authorization → `[authorization header]`); URL в отчёте и JSON обезличены: userinfo → `[credentials withheld]`, query/fragment → `[query withheld]`. Прямые пробы идут с `--noproxy '*'`, поэтому `HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` из окружения не искажают утверждения о direct-пути (socks-пробы используют явный `--socks5-hostname`). DNS-пробы ограничены 6 с через `timeout`, если он доступен (иначе ограничение помечается в отчёте). Ответ Controller `/proxies` ограничен `--max-filesize`.
- Причина не объявляется установленной: вердикт называет **только подтверждённую ступень отказа**, остальные объяснения помечены как гипотезы (H:) и «следующие шаги» (N:). Успех пробы с роутера не доказывает путь конкретного LAN-клиента — `client.vantage` всегда `NOT TESTED`.
- UDP-транспорт за пределами косвенной работы резолвера — `UNSUPPORTED` (честно, без фиктивного PASS).
- DNS-проба выполняется только при наличии утилиты `timeout` (лимит 6 с); без неё стадия честно `NOT TESTED` — неограниченное ожидание на слабом роутере исключено.

## Быстрый запуск на новом роутере из `stable`

Нужны SSH-доступ к Keenetic/Netcraze, работающий Entware (`/opt`, `opkg`), Интернет и `curl`. Если `curl` отсутствует, сначала установите **только эту утилиту**: `opkg update && opkg install curl`. KAS Web не нужен; отсутствие Mihomo/MagiTrickle/ProxyN не мешает запуску, но соответствующие этапы будут отмечены как непроверенные или неподдерживаемые.

Скачайте проверенную версию из `stable` во временный `/tmp`, проверьте синтаксис и запустите диагностику указанного домена (замените `example.com` своим адресом):

```sh
curl -fSsL --retry 2 --max-time 60 -o /tmp/kas-network-doctor.sh \
  https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-network-doctor.sh &&
sh -n /tmp/kas-network-doctor.sh &&
sh /tmp/kas-network-doctor.sh --target example.com
```

Для сохранения результатов после скачивания:

```sh
sh /tmp/kas-network-doctor.sh --target example.com \
  --report /tmp/kas-network-report.txt --json /tmp/kas-network-report.json
```

Цепочка `&&` **не запускает скрипт**, если скачивание или синтаксическая проверка завершились ошибкой. Запуск Network Doctor намеренно выполняет внешние сетевые запросы с ограничениями времени и объёма; это **не установка KAS**, не изменение маршрутов и не фоновая служба. Файлы в `/tmp` временные, после перезагрузки могут исчезнуть. При недоступности GitHub можно перенести скрипт на роутер через SCP и запустить `sh /tmp/kas-network-doctor.sh --target example.com`.

## Запуск

```sh
sh kas-network-doctor.sh --target example.com
sh kas-network-doctor.sh --target https://example.com/path
sh kas-network-doctor.sh --target 192.0.2.10 --port 80      # plain HTTP
sh kas-network-doctor.sh --target example.com --dns-server 1.1.1.1
sh kas-network-doctor.sh --target example.com --json /opt/tmp/net-report.json
sh kas-network-doctor.sh --target example.com --report /opt/tmp/net-report.txt --brief
MIHOMO_PROXY_GROUP='GLOBAL' MIHOMO_API_SECRET='…' sh kas-network-doctor.sh --target example.com
sh kas-network-doctor.sh --target example.com --no-egress   # без наблюдения egress
```

Правила цели и порта: путь и query из URL-цели сохраняются и проверяются фактически (`--target https://example.com/missing` проверяет именно `/missing`, query-only URL вида `https://example.com?token=abc` проверяется с query); приоритет порта — явный `--port` > порт внутри URL > схема (443/80); IPv6-литералы и нечисловые порты — явная ошибка использования, а не молчаливая проверка другого адреса, и сообщения об ошибках не повторяют исходный ввод. Политика отчётов: **путь и query никогда не печатаются** — в stdout, текстовом отчёте и JSON любой непустой путь показывается как `[path withheld]`, query как `[query withheld]`, userinfo как `[credentials withheld]`; сетевая проба всегда идёт по полному URL.

Статусы: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Коды возврата: `0` — цепочка подтверждена (DNS+TCP+TLS ответили, HTTP ответил любым статусом); `1` — подтверждён отказ ступени; `2` — ошибка использования; `3` — неопределённый итог (ничего не FAIL, но и цепочка не завершена: нет утилит, таймауты, исчерпан бюджет); вердикт печатает точную инвентаризацию — какие ступени подтверждены и каких свидетельств не хватает — вместо «ничего не доказано».

## Ступени и стабильные идентификаторы проверок

| ID проверки | Что показывает |
| --- | --- |
| `tools.curl` | доступность curl (без него почти всё — `UNSUPPORTED`, вердикт — неопределённый) |
| `dns.router` | разрешение имени системным резолвером: NXDOMAIN / SERVFAIL / REFUSED / timeout различаются явно; для IP-цели — `NOT TESTED` |
| `dns.curl-path` | только косвенное свидетельство: если независимая DNS-стадия не выполнялась (нет `timeout`, нет nslookup или бюджет), но цель была достигнута по TLS/HTTP — фиксируется `PASS` «имя разрешилось на curl-пути». Это НЕ независимая DNS-стадия, не входит в цепочку вердикта и не заменяет её |
| `dns.custom` | то же имя через заданный `--dns-server`; расхождение с `dns.router` печатается как факт |
| `tcp.connect` | TCP до host:port через telnet-приём curl; поддержка telnet сначала определяется из `curl -V` — если curl собран без telnet, TCP-проба пропускается без расхода запроса (`NOT TESTED`), а TCP подтверждает TLS/HTTP-стадия; `curl 7` = отказ/недостижимость; `curl 56` при telnet = подключение установлено. Если TLS/HTTP-стадия доказала обмен с сервером, TCP фиксируется как подтверждённый, а расходящееся наблюдение telnet помечается явно |
| `tls.handshake` | TLS-рукопожатие с включённой проверкой сертификата: `curl 35` (handshake), `curl 60/19` (сертификат: время/CA), `curl 43` (malformed), `curl 56` (разрыв в середине обмена → UNKNOWN) |
| `http.response` | HTTP-статус и цель редиректа (`%{redirect_url}`); **редиректы не следуются** — это один ограниченный запрос; 3xx сопровождается целью редиректа и гипотезой captive-portal; 4xx/5xx = «транспорт здоров, приложение ответило» — факт, а не сетевой отказ |
| `egress.direct` | адрес фактического прямого выхода (api.ipify.org, крошечный запрос); отключается `--no-egress` |
| `mihomo.socks-port` | слушается ли локальный порт 7890 (netstat/ss) |
| `mihomo.controller` | доступность Controller (GET /version; 401/403 = секрет не принят) |
| `mihomo.controller.selection` | есть ли выбранная кнопка у группы (GET /proxies + jq; имя скрывается) |
| `mihomo.socks-probe` | доходит ли HTTP до цели через локальный SOCKS5h; ограничение печатается явно: не доказывает классификацию LAN-клиента |
| `egress.via-mihomo` | адрес выхода через путь Mihomo; сравнение с `egress.direct` — факт (совпадают/различаются) |
| `magitrickle.process` | процесс magitrickled запущен (pgrep/pidof, read-only) |
| `keenetic.proxyn` | наличие ProxyN-моста к 127.0.0.1:7890 в running-config (ndmc, read-only, фильтрованный вывод) |
| `udp.transport` | всегда `UNSUPPORTED` — надёжной UDP-пробы с проверяемой семантикой на BusyBox/Entware нет |
| `client.vantage` | всегда `NOT TESTED` — наблюдения сделаны с роутера; путь конкретного клиента требует отдельной проверки на клиенте |

## Интерпретация

- Verto печатаются отдельно от гипотез: секция «Hypotheses» начинается с явного «NOT confirmed causes». Типовые гипотезы: NXDOMAIN (ошибка имени/перехват), curl 35 (известный полевой случай docs/03 — путь X25519/IPv6; DPI — лишь одна из гипотез), curl 60/19 (время устройства или `ca-bundle`), разрыв в TLS (DPI/MTU/сервер — без диагноза), captive-portal редирект (итоговый URL на приватный адрес), 4xx/5xx (сторона сервиса).
- Согласованность ступеней печатается строкой «consistency: …» (например, DNS ответил, TCP отказал → далее отказ закономерен).

## JSON-контракт для будущей интеграции с KAS Web

`--json FILE` пишет `network-diagnostics/v1` на чистом POSIX sh (jq не требуется и для записи, и для чтения): схема, версия инструмента, UTC-время, exit-код, вердикт (summary/first_failed_stage/hypotheses/next_steps), цель, vantage (`router`), бюджет (таймауты, лимиты, счётчики), egress-наблюдения, счётчики статусов и массив `checks` со стабильными `id`/`status`/`detail`/`observed`. Все статусы — из фиксированного словаря. Формат предназначен для будущей панели; парсер Doctor 1.2.18/1.2.19 (doctor-report.js) не затронут.

## Тестирование и границы доказанности

- `tests/network-doctor-regression.py` — офлайн-регрессия: mock curl/nslookup/ndmc/netstat/jq/pgrep через PATH, поведенческие и специальные регрессионные сценарии на обоих шеллах (dash-совместимый sh и BusyBox ash): NXDOMAIN/SERVFAIL/REFUSED/timeout, TCP refused/reset/timeout, TLS 35/60/56/28, HTTP 200/403/500/редирект, captive-portal, расхождение резолверов, отсутствие curl, недоступный Controller, выключенный egress, позитивные пути Mihomo/ProxyN/MagiTrickle, точное число запросов, валидность JSON на happy/fail-путях, изоляция PATH, «секрет не появляется ни в одном выводе».
- Прогон выполнен на host sh и BusyBox ash 1.37: **MOCK PASS на обоих диалектах**. Это доказательство логики, а не полевой результат.
- **QEMU (отдельный read-only прогон): PASS для запуска обоих новых скриптов** в disposable KeeneticOS Ported 5.1.8 / Entware (DRIVER_OK, 254 с). Network Doctor выполнился, JSON `network-diagnostics/v1` валиден, `checks[].id` уникальны; отказ DNS в изолированном госте классифицирован. Из-за WAN `restrict=on` и отсутствия curl **успешный внешний сетевой путь в QEMU: NOT TESTED**. Успешный GitHub CI `native-kas / ported-lab` подтверждает общий жизненный цикл KAS, но не заменяет отдельную проверку скриптов в госте. **PHYSICAL: NOT TESTED** — реальные Keenetic остаются непроверенными; для них нужен отдельный GO.
