# 2026-11-08 — подборки Gemini: DNS / egress / leak / GeoIP / client diagnostics для KAS

> **Статус: RESEARCH / OPERATOR-SUPPLIED / AGENT HANDOFF, НЕ ГОТОВЫЙ КОД И НЕ FIELD PASS.**
> Источник: три присланные владельцем 08.11.2026 подборки Google Gemini: (1) стабильность маршрутов, VPN/DIRECT и риск геоскачков; (2) ECS и список DoT/DoH для Keenetic; (3) IP/DNS/WebRTC/IPv6/TCP/GeoIP и инструменты для роутера/браузера.
> Ни исходные утверждения Gemini, ни эта запись не являются рекомендацией обходить правила сторонних сервисов или гарантией защиты от блокировки аккаунтов.
> **Safety:** никакого автоматического применения DNS-команд, изменения firewall, VPN, подписок, routes, DNS interception, сохранения конфигурации либо запуска внешних тестов без отдельного разрешения. Исследование не меняет production.

## Зачем сохраняем и где место в архитектуре

Цель владельца — не потерять идеи и позже поручить агенту **проверить их на практике, в mock и эмуляторе**, а затем оценить тонкую интеграцию в **KAS Web**. Пользовательский результат: честный отчёт, показывающий, *какой путь наблюдался, где именно, какие проверки не выполнены*, и где есть риск неожиданного резервного маршрута.

**Не строить новый «anti-ban» или «anti-detect» модуль.** Внутренние антифрод-механизмы Google/OpenAI не раскрыты; внешний георейтинг и «fraud score» не равны оценке риска блокировки аккаунта. Стабильный IP не гарантирует разрешённость использования сервиса в неподдерживаемых регионах. Проверять доступность и сетевую согласованность, а не заявлять обход.

Привязка к текущим задачам и коду (снимок `main` на момент подготовки: `9d2412bc58b56bde8633e9ff874e7951805ffdcd`; при начале агентской работы проверить HEAD заново):

- [#158 Network Doctor](https://github.com/saymer-alt/keenetic-auto-setup/issues/158): staged DNS/TCP/TLS/HTTP/egress и ограниченные явные probes;
- [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270): инвентаризация → CLI-скрипты → проверки → только затем Web;
- [docs/33](../33-diagnostics-architecture-map.md), [docs/29](../29-network-doctor.md): разделение ответственности и существующий `network-diagnostics/v1`;
- `kas-network-doctor.sh`: direct / SOCKS5h egress, DNS/TCP/TLS/HTTP с router-vantage;
- `mihomo-route-check.sh`, `mihomo-proxy-selection-watch.sh`: узкий путь и цепочка Selector/URLTest/Fallback/LoadBalance;
- [Draft PR #452](https://github.com/saymer-alt/keenetic-auto-setup/pull/452) (CLI interface vantages), [#459](https://github.com/saymer-alt/keenetic-auto-setup/pull/459) (DPI/DNS design), [#382](https://github.com/saymer-alt/keenetic-auto-setup/pull/382) (Web adapter design). **Не конфликтовать с ними, не копировать их код, не считать Draft слитым.**
- `mihomo-doctor.sh` — только offline read-only и **никаких внешних DNS/HTTP-проб**.

## A. Критическая проверка предпосылок из Gemini

| Утверждение из подборок | Оценка на 08.11.2026 | Требуемое поведение KAS |
| --- | --- | --- |
| Смена IP/VPN — доказанный главный триггер волны банов OpenAI | **НЕ ПОДТВЕРЖДЕНО.** Данные отдельных жалоб не раскрывают алгоритм блокировки | Никаких обещаний anti-ban / risk score |
| «DNS leak» и ECS — одно и то же | **НЕВЕРНО.** ECS — передача клиентского префикса авторитетному серверу (если используется); DNS leak — использование неожиданного резолвера/пути | Отдельные проверки `dns.ecs` и `dns.path`; не объявлять отсутствие ECS доказательством отсутствия утечек |
| Google меняет страну европейского VPS в GeoIP, увидев запросы к 8.8.8.8 с РФ | **ГИПОТЕЗА, доказательств не приведено** | Не создавать «GeoIP poisoning detected» |
| Anycast-нод DNS внутри РФ автоматически означает VPN/IP-утечку | **НЕВЕРНО**: DNS маршрут, веб-egress, Anycast PoP и страна базы GeoIP — независимые наблюдения | Разделять результаты и vantage |
| Браузерный WebRTC/Canvas/JA3/TCP fingerprint определяется `curl` на роутере | **НЕВЕРНО**: browser/client vantage ≠ router vantage, прокси может терминировать TCP/TLS | Браузерная часть — клиентский ручной тест или отдельная явно одобренная программа на клиенте |
| MTU=1420/1280 или Windows «видится Linux» = мгновенный бан | **НЕПОДТВЕРЖДЁННЫЙ ВЫВОД**; свойства TCP часто принадлежат прокси | Никаких anti-fraud выводов без доказательств |
| `curl https://dns.google/resolve?...` проверяет DNS Keenetic | **НЕВЕРНО**: явно опрашивает Google DoH, минуя системный resolver | Для ECS/path использовать выбранный resolver/vantage, не подменять тест |
| Страна в футере Google = точная внутренняя GeoIP-база Google | **СЛИШКОМ СИЛЬНЫЙ ВЫВОД**; страна может зависеть от аккаунта, устройства, истории | Ручное дополнительное наблюдение, не source of truth |
| Cloudflare `colo` = страна внешнего IP | **НЕВЕРНО**: это код обслужившего дата-центра (Anycast) | Раздельные поля `cf.colo`, `cf.loc`, `egress.ip`, без приравнивания |
| Произвольный онлайн «Fraud Score» = оценка Google/OpenAI | **НЕВЕРНО** | Только внешняя справка с указанием провайдера; без объединённого рейтинга |

## B. DNS-кандидаты и устаревшие записи (не автонастройка)

В исходной подборке предложены настройки/удаление через `dns-proxy ...` и `system configuration save`. **Не переносить эти блоки как ready-to-run**: они меняют пользовательскую конфигурацию DNS, могут конфликтовать с перехватом MagiTrickle/53, DoT/DoH, частной сетью, IPv6 и правилами KeeneticOS. Совместимость CLI и актуальную роль каждого upstream нужно проверять по версии прошивки, не предполагать.

| Резолвер | DoT hostname | DoH URL / status | Уровень доказательности |
| --- | --- | --- | --- |
| Quad9 No Threat Blocking | `dns10.quad9.net` | `https://dns10.quad9.net/dns-query` | адреса официальные; DNSSEC включён, блокировки угроз нет |
| Quad9 Secure | `dns.quad9.net` | `https://dns.quad9.net/dns-query` | официальный, блокирует угрозы |
| DNS.SB | `dot.sb` | `https://doh.sb/dns-query` | кандидат, проверить официальные характеристики и reachability |
| CZ.NIC ODVR | `odvr.nic.cz` | официальный guide: `https://odvr.nic.cz/dns-query` | документация CZ.NIC; сторонние источники также приводят `/doh` — не заявлять, что этот путь заведомо невозможен; испытать отдельно |
| Digitale Gesellschaft | `dns.digitale-gesellschaft.ch` | `https://dns.digitale-gesellschaft.ch/dns-query` | кандидат, перепроверить официальные параметры |
| DNS4EU (название «unfiltered») | `unfiltered.joindns4.eu` | `https://unfiltered.joindns4.eu/dns-query` | кандидат; «unfiltered» не гарантирует ноль правовых/региональных блокировок |
| Restena | `dnspub.restena.lu` | `https://dnspub.restena.lu/dns-query` | подтверждено документацией Restena; исходное `dns.restena.lu` не брать без проверки |
| DNS0.eu | — | **DISCONTINUED (октябрь 2025)** | не добавлять в рекомендованные upstream |
| Mullvad public DoH/DoT | — | **SUNSET: перейти до 02.11.2026** | не добавлять как действующий публичный DNS |

**Quad9/ECS:** ECS-профили — не только `dns11.quad9.net` (9.9.9.11), но и `dns12` (9.9.9.12). `dns10` — без threat-blocking, но не «без DNSSEC». Все адреса DoT/DoH — **документированные строки, не FIELD PASS на конкретном Keenetic**. Проверить DNSSEC, DoT/DoH certificate/SNI, bootstrap, split DNS, timeout, fallback, rebind, IPv6 и отсутствие неожиданных незашифрованных запросов.

**Ссылки на проверенные документы (по состоянию на дату заметки):**
- [Quad9 service profiles](https://docs.quad9.net/services/) / [Quad9 current features](https://quad9.net/service/service-addresses-and-features/)
- [Mullvad announcement, 03.09.2026](https://mullvad.net/nl/blog/2026/9/3/shutting-down-our-public-encrypted-dns-servers-and-sponsoring-quad9-instead)
- [DNS0.EU closure report, 20.10.2025](https://www.bleepingcomputer.com/news/security/dns0eu-private-dns-service-shuts-down-over-sustainability-issues/)
- [CZ.NIC ODVR](https://www.nic.cz/en/domains/tools/odvr/)
- [Restena public DNS](https://restena.lu/en/document/190-configuring-your-server-public-dns-resolver)

## C. Инструменты из Gemini — классификация, не список обязательных зависимостей

| Инструмент | Доступен на каком уровне | Для чего полезен; ограничения |
| --- | --- | --- |
| [ipleak.net](https://ipleak.net/), [dnsleaktest.com](https://www.dnsleaktest.com/), [dnscheck.tools](https://dnscheck.tools/) | браузер/клиент | IPv4/IPv6, DNS server path, WebRTC (если поддерживается); не доказывают policy конкретного роутера |
| [mullvad.net/check](https://mullvad.net/check) / [browserleaks.com](https://browserleaks.com/) | браузер/клиент | IP, WebRTC, fingerprint; browser fingerprint не извлечь роутерным `curl` |
| [whoer.net](https://whoer.net/), [browserscan.net](https://www.browserscan.net/), [pixelscan.net](https://pixelscan.net/), [nodemaven.com/tools/webrtc-leak-test](https://nodemaven.com/tools/webrtc-leak-test/), [todetect.net](https://www.todetect.net/) | браузер/клиент | сторонние, функции/скоры не подтверждены единым стандартом; не считать гарантией «антидетекта» |
| [iplocation.net](https://www.iplocation.net/), [ipinfo.io](https://ipinfo.io/), [scamalytics.com](https://scamalytics.com/), [maxmind.com](https://www.maxmind.com/en/locate-my-ip-address) | справочные веб-базы | разногласия GeoIP/ASN/VPN flags и внешние репутационные оценки; не доказательство внутреннего решения Google/OpenAI |
| Google Search location footer | браузер (вход/история могут влиять) | пользовательское наблюдение страны, не direct query к приватной GeoIP-базе |
| `https://www.cloudflare.com/cdn-cgi/trace` | router/CLI opt-in (при проверке доступности) | поля `ip`, `loc`, `colo`, `warp` в пределах реально возвращённого ответа; `colo` = PoP, не страна IP |
| `https://api.ipify.org`, `https://icanhazip.com`, `https://ipinfo.io/json` | router/CLI opt-in | IPv4/IPv6 и egress, но запрос из роутера ≠ LAN-client; чужой сервис видит адрес |
| `dig TXT o-o.myaddr.l.google.com` | router/CLI opt-in | косвенное наблюдение системного рекурсивного DNS и возможного ECS; зависит от конкретного resolver path; `dig` не обязателен |
| Google DNS JSON API | внешний DoH | только диагностика **явного** пути Google; НЕ тест текущего системного DNS Keenetic |
| bash.ws dnsleak | browser / отдельный клиент | одна HTML-страница в `curl` не эквивалентна многозапросному тесту; сторонний shell-script не скачивать и не запускать автоматически |
| `chrome://net-internals/#dns`, `chrome://webrtc-internals` | Chrome/Edge клиент | ручная диагностика; наличие функций и UI проверить на конкретной версии Chromium, не очищать кеш автоматически |
| TCP/MTU/MSS traces | router/vantage-specific с имеющимися утилитами | только наблюдение параметров, не сигнал о «VPN-фроде»; p0f относится к точке установления TCP |

**Конфиденциальность внешних тестов:** запрет отправки подписок, токенов, авторизационных URL, userinfo, реальных VPS inventories; даже обычный IP и доменные запросы — внешняя передача данных, поэтому probes **только по явному запуску**, с ограниченным бюджетом и понятным destination disclosure.

## D. План следующему агенту: ограниченные стадии с доказательствами

### Stage A — инвентаризация и защита идеи (только read-only)

- На **новом актуальном HEAD** прочитать релевантные участки `AGENTS.md`, `docs/CONSTITUTION.md`, `docs/AGENT-TASK-CONTRACT.md`, `docs/33-diagnostics-architecture-map.md`, а также affected scripts полностью перед правкой routing/DNS и их tests.
- Сверить #158/#270/#323/#455, Draft #452/#459/#382 и другие изменившиеся PR, посмотреть, что уже реализовано / только в Draft. Не дублировать исправления, не править параллельно конфликтные `docs/29-network-doctor.md` или исходники.
- Сравнить: A) существующие CLI + инструкция ручных тестов; B) минимальное **опциональное** расширение текущего Network Doctor; C) новый механизм. Выбрать A/B без отдельного GO на C.
- Составить таблицу «полезная проверка → источник → available commands → vantage → evidence → mock cases → цена запроса», отдельно `NOT_TESTED` для неиспытанного. Проверить доступность и корректность кандидатов только из документации / в изолированном стенде; не менять DNS сети.
- Записать согласованный план/контракт в связанную Issue/малый Draft PR. Владелец **пока не санкционировал изменения кода, merge, release или работу с устройствами** этим исследованием.

### Stage B — минимальная CLI-диагностика (после отдельного task GO)

- Расширять **существующий** `kas-network-doctor.sh`, сохраняя `network-diagnostics/v1`, exit-коды, бюджеты, backwards-compatible schema и нейтральные статусы. Без второго движка, автозапуска или установки тяжёлых пакетов.
- Возможные узкие opt-in проверки: `egress.ipv4`, `egress.ipv6`, `egress.via-mihomo` с показом расхождений; `dns.path`/`dns.ecs` (если корректная семантика достижима); `route.proxy-selection` (read-only Controller); опциональный `cloudflare.trace` со строго ограниченным парсером. Никаких авто-конфигураторов DNS или «anti-ban» скорингов.
- Флаг/профиль должен быть явным; `--no-egress` оставляет внешние egress-пробы выключенными; непроверенный IPv6 = `NOT TESTED` или `UNSUPPORTED`, а не `PASS`; DNS-ответ из другой точки не считать утечкой без подтверждения client path.
- Никаких запросов к сайтам с авторизованной сессией, непроверенных shell-клиентов DNS leak или IP-reputation API без отдельного разрешения.
- Результаты должны указывать `vantage=router` или подтип при наличии объективных данных; IP/ASN/GeoIP сохранять локально только по опциональному согласию и редактировать в shareable JSON.

### Stage C — проверки на mock и эмуляторе (после отдельных правок)

- POSIX sh / BusyBox ash без GNU-only инструментов; `sh -n`, релевантные `tests/network-doctor-regression.py`, `sh tests/contracts.sh`, `python3 tests/docs-links.py` при необходимости; не запускать бесполезно повторные CI на том же SHA (loop guard).
- Фикстуры: direct/SOCKS **различаются**; direct/SOCKS **совпадают** (не путать с доказательством обхода); `DIRECT` как leaf и `LoadBalance` без одного leaf; proxy fallback switched; Controller absent/401; curl без telnet; timeout отсутствует; DNS REFUSED/NXDOMAIN/SERVFAIL, split DNS, ECS отсутствует/есть/неопределён; DoH с TLS CA error; IPv6 only/off/blocked; MT/NDM classification расходится с роутерной пробой; ложный «фрод/GeoIP» из Cloudflare PoP; недоступный внешний сервис; превышение бюджета, отсутствие утечек секретов.
- Эмулятор: disposable KeeneticOS/Entware стенд, без production-конфигураций, без реальных ключей и без изменения `stable`. Проверить фактическое выполнение кода и JSON/таймауты; если WAN ограничен или нет curl/IPv6/DoH — соответствующие пункты **NOT TESTED**, не экстраполировать.
- Результаты назвать точно `MOCK PASS`, `EMULATOR PASS`, `CI PASS`; **FIELD PASS только после реальных приборов**, что требует отдельного owner GO. Записать SHA и ссылки на прогоны.

### Stage D — FIELD на реальном Keenetic (только отдельный owner GO)

- Только согласованное устройство/время; начальный backup, доступ к откату, без автоматической перенастройки DNS/MT/Mihomo.
- Подтвердить реальный клиентский путь из Windows/Android отдельно от маршрута роутера, плюс IPv6/DoH/WebRTC вручную. Проверить, что VoIP, WAN failover, DHCP/разрешение локальных имён, MT 53→3553, ProxyN и пользовательский роутинг не нарушены.
- При отсутствии подтверждения маркировать `INCONCLUSIVE`, а не приписывать причину антифроду или DPI.

### Stage E — KAS Web (только после стабильного CLI и отдельного owner GO)

- Использовать **тонкий Web-адаптер** по [#382](https://github.com/saymer-alt/keenetic-auto-setup/pull/382) и актуальным границам #323. UI вызывает CLI, не дублирует DNS/egress-логику.
- Кнопка **«Проверить сеть»** только по пользовательскому действию, без фоновых проверок при открытии панели; понятные чекбоксы для внешних проб, информация о том, что IP/домен попадут на сторонний сервер.
- Один слот выполнения, отмена, таймаут, лимит вывода; строгая валидация целей/порта/vantage, SSRF-проверки и запрет `sh -c` при сборке команд; SAN JSON перед показом/копированием.
- В веб-отчёте отдельно показывать **router vs client**, `PASS/FAIL/UNKNOWN/NOT TESTED/UNSUPPORTED`, а «риск нежелательного выхода» — только на конкретных доказательствах. Никаких утверждений «Google/OpenAI считают аккаунт безопасным».

## E. Границы прав и Definition of Done

- **Этот документ = только сохранение наработок.** Он не даёт агенту право автоматически выполнять Stage B–E, изменять `main`/`stable`, слить PR, публиковать релиз, развернуть на VPS или тестировать домашний/рабочий/чужой роутер.
- Следующая самостоятельная разрешаемая работа: **Stage A**, небольшая инвентаризация и узкая постановка без мутаций production. Stage B/C/D/E отдельно согласуются по scope и отдельным GO.
- Не добавлять реальных IP VPS, подписок, приватных YAML, ключей, токенов, историю посещений и авторизованные диагностические ответы в публичный репозиторий.
- Не перезапускать WAN, DNS, watchdog, MagiTrickle, Mihomo, не менять пользовательские правила, не делать `dns-proxy ...` конфигурационные операции.
- **DoD для этой записи:** один Markdown, источники и статус утверждений, точные связи с существующими компонентами, staged task contract и проверенные ссылки. Код/эмулятор/полевые испытания/Web — **NOT TESTED / NOT IMPLEMENTED**.
