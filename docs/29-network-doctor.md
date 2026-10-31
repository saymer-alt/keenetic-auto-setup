# Сетевой Doctor: каскадная диагностика по одной цели

`kas-network-doctor.sh` — автономный диагностический инструмент этапов сети (issues [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#166](https://github.com/saymer-alt/keenetic-auto-setup/issues/166), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270)). В отличие от обычного Doctor, этот инструмент **сам выполняет сетевые пробы** — и делает это только когда пользователь явно его запустил. Для одной заданной цели он проходит цепочку доставки **DNS → TCP → TLS → HTTP**, затем показывает фактический адрес выхода (egress), локальный путь Mihomo (порт 7890, read-only запросы к Controller, проба SOCKS5h) и read-only сведения MagiTrickle/Keenetic (ProxyN).

Обычный `mihomo-doctor.sh` остаётся локальным и офлайн-безопасным: внешних проб он по-прежнему не делает. `mihomo-route-check.sh` продолжает работать как узкая точечная проверка одного сайта.

## Что инструмент делает и чего не делает

- Ничего не меняет: DNS, маршруты, firewall, интерфейсы, ProxyN, политики, Mihomo, MagiTrickle и конфигурация не затрагиваются; проверка сертификатов никогда не отключается.
- Бюджет запросов: **≤ 12 небольших запросов** за запуск (DNS-запросы считаются), каждый ограничен `--connect-timeout 6` / таймаутом 15 с / `--max-filesize 256 KiB`. Счётчик показывается в отчёте и JSON.
- Секрет `MIHOMO_API_SECRET` **никогда не выводится**; выбранное имя прокси-сервера скрывается («selected leaf (name withheld)») — отчёт безопасно прикладывать к Issue. Аргументы curl в журнале санитизируются: заголовок Authorization заменяется на `[authorization header]`.
- Причина не объявляется установленной: вердикт называет **только подтверждённую ступень отказа**, остальные объяснения помечены как гипотезы (H:) и «следующие шаги» (N:). Успех пробы с роутера не доказывает путь конкретного LAN-клиента — `client.vantage` всегда `NOT TESTED`.
- UDP-транспорт за пределами косвенной работы резолвера — `UNSUPPORTED` (честно, без фиктивного PASS).

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

Статусы: `PASS / FAIL / UNKNOWN / NOT TESTED / UNSUPPORTED`. Коды возврата: `0` — цепочка подтверждена (DNS+TCP+TLS ответили, HTTP ответил любым статусом); `1` — подтверждён отказ ступени; `2` — ошибка использования; `3` — неопределённый итог (ничего не FAIL, но и цепочка не завершена: нет утилит, таймауты, исчерпан бюджет).

## Ступени и стабильные идентификаторы проверок

| ID проверки | Что показывает |
| --- | --- |
| `tools.curl` | доступность curl (без него почти всё — `UNSUPPORTED`, вердикт — неопределённый) |
| `dns.router` | разрешение имени системным резолвером: NXDOMAIN / SERVFAIL / REFUSED / timeout различаются явно; для IP-цели — `NOT TESTED` |
| `dns.custom` | то же имя через заданный `--dns-server`; расхождение с `dns.router` печатается как факт |
| `tcp.connect` | TCP до host:port через telnet-приём curl; `curl 7` = отказ/недостижимость; `curl 56` при telnet = подключение установлено (одноранговый узел закрыл пробу) |
| `tls.handshake` | TLS-рукопожатие с включённой проверкой сертификата: `curl 35` (handshake), `curl 60/19` (сертификат: время/CA), `curl 43` (malformed), `curl 56` (разрыв в середине обмена → UNKNOWN) |
| `http.response` | HTTP-статус после редиректов (`--max-redirs`-ограничение curl), код, итоговый URL; 4xx/5xx = «транспорт здоров, приложение ответило» — факт, а не сетевой отказ |
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

## JSON-контракт для KAS Web beta.4

`--json FILE` пишет `network-diagnostics/v1` на чистом POSIX sh (jq не требуется и для записи, и для чтения): схема, версия инструмента, UTC-время, exit-код, вердикт (summary/first_failed_stage/hypotheses/next_steps), цель, vantage (`router`), бюджет (таймауты, лимиты, счётчики), egress-наблюдения, счётчики статусов и массив `checks` со стабильными `id`/`status`/`detail`/`observed`. Все статусы — из фиксированного словаря. Формат предназначен для будущей панели; парсер Doctor 1.2.18/1.2.19 (doctor-report.js) не затронут.

## Тестирование и границы доказанности

- `tests/network-doctor-regression.py` — офлайн-регрессия: mock curl/nslookup/ndmc/netstat/jq/pgrep через PATH, ~36 поведенческих кейсов на оба шелла (dash-совместимый sh и BusyBox ash): NXDOMAIN/SERVFAIL/REFUSED/timeout, TCP refused/reset/timeout, TLS 35/60/56/28, HTTP 200/403/500/редирект, captive-portal, расхождение резолверов, отсутствие curl, недоступный Controller, выключенный egress, позитивные пути Mihomo/ProxyN/MagiTrickle, точное число запросов, валидность JSON на happy/fail-путях, изоляция PATH, «секрет не появляется ни в одном выводе».
- Прогон выполнен на host sh и BusyBox ash 1.37: **MOCK PASS на обоих диалектах**. Это доказательство логики, а не полевой результат.
- **QEMU: НЕ RUN** (стенд router-emulator (#208) не задействован в этой работе), **PHYSICAL: NOT TESTED** — первая аппаратная проверка требует отдельного GO владельца.
