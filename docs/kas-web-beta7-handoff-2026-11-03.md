# KAS WEB beta.7 — план работ и handoff для нового чата (03.11.2026)

> **Статус: ROADMAP / DESIGN, не реализованный релиз.** Это закреплённый план следующего цикла, а не разрешение на merge, Release, Pages, `stable` или доступ к физическим роутерам. Проверять актуальные HEAD/CI/GitHub issues перед началом работ. Приоритет: сначала завершить и испытать beta.6.

## Обновление статуса после выпуска beta.6 (03.11.2026, подтверждено GitHub)

- **beta.6 ОПУБЛИКОВАНА:** [Release v0.1.0-beta.6](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/v0.1.0-beta.6), пакет `0.1.0.beta.6-1`, GitHub prerelease, четыре IPK + SHA256SUMS. Финальный `main` / релизный SHA: `b7d97c297a70c90980d932bf571cd0ff6ee52ad9`.
- [Интеграционный #363](https://github.com/saymer-alt/keenetic-auto-setup/pull/363) merged (`2f18c1742955f9b352d9131375ce43c10d9faec8`), [фикc имени артефактов #370](https://github.com/saymer-alt/keenetic-auto-setup/pull/370) merged. Не повторять интеграцию исходных PR #359–#362.
- [Candidate build 41701185022](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41701185022), [publisher 41702447669](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41702447669), [Pages deploy 41703509323](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41703509323): GitHub API показывает completed/success на том же SHA. По отчёту агента публичный experimental index переведён на beta.6; перед разработкой проверить HTTP по [channels.json](https://saymer-alt.github.io/keenetic-auto-setup/updates/channels.json) и [experimental/panel-update.json](https://saymer-alt.github.io/keenetic-auto-setup/updates/experimental/panel-update.json).
- **Реальные NC-4210 и KN-1012 пока не получили подтверждённого hardware FIELD PASS.** Проверить ручную установку, upgrade, фактический порт (новая установка 18080, сохранённые настройки сохраняют порт), password-file 401/200 и KeenDNS/Origin/Host. CI не заменяет полевые испытания.
- **P0 технический долг, не выполненный при beta.6:** в актуальном `main` остался `.github/workflows/web-beta3-build.yml`, а `kas-web-candidate-build.yml` отсутствует. Ранее запрошенная миграция не была выполнена. Выделить отдельный безопасный PR перед публикацией beta.7: переименовать без дублирования, обновить pin в `scripts/kas_web_beta_publisher.py`, `tests/web-beta-publish-dryrun.py`, `tests/candidate-build-dryrun.py`, активные workflow и docs; проверить dispatch, 4 архитектуры, отказ publisher для неверного workflow, version/SHA/asset proofs. **Не изменять выпущенную beta.6 задним числом**; сохранить возможность использовать её release artifacts и верные historical tests. Не смешивать с первой функциональной реализацией Network Doctor.
- Дополнительные beta.6 production bugfix, обязательные для регрессии beta.7: watchdog `now_ms()` с zero-padded дробью uptime `090` (POSIX shell arithmetic) и `auth_mode:none` + `-password-file` (пароль 401/200). Они уже включены в релизную ветку main; не отменять.

## 1. Исходная точка и зависимости

- Репозиторий: https://github.com/saymer-alt/keenetic-auto-setup
- Историческая запись на момент первоначального плана (уже не текущий статус): **интеграционный Draft PR #363** https://github.com/saymer-alt/keenetic-auto-setup/pull/363 (порт `18080`, fallback `18081..18090`, Mihomo API `v1.19.33`, read-only `router-metrics/v1`, watchdog source/hash evidence). Не объявлять её опубликованной, пока это не подтверждено GitHub Release и Pages.
- Релиз beta.6 уже опубликован; **первые аппаратные smoke/upgrade-проверки ещё нужны** перед окончательным решением о выпуске beta.7. Регрессии beta.6 исправляются раньше новых функций.
- Исходные PR #359/#360/#361/#362 и интеграционный #363 не сливать повторно. Проверять фактический новый `main` после завершения beta.6; будущие ветки beta.7 создавать от актуального `main`, а не от beta.6 Draft.
- Инженерный протокол beta.5/beta.6: PR #358 и `docs/kas-web-beta5-field-lessons-2026-11-03.md` (пока находится в его ветке); не путать этот документ с принятой реализацией.
- Миграция старого имени `web-beta3-build.yml` на `kas-web-candidate-build.yml` **не вошла в выпущенную beta.6**; это явный P0 технический долг перед публикацией beta.7. Делать отдельным проверенным PR без второго сборщика.

## 2. Зафиксированный предварительный состав beta.7

### P0. FIELD beta.6: браузерные кнопки массово не реагируют (NC-4210)

> **FIELD confirm 03.11.2026:** На NC-4210 реальный GET `/api/updates/panel/operation` вернул `State:FAIL, Phase:recovery_required, ErrorCode:PANEL_START_FAILED, Gate:true`, так что блокировка кнопок durable self-update gate подтверждена, а не просто гипотеза. Оператор выполнил штатную `/opt/bin/kas-control-center -recover-panel-update` без сообщения об ошибке; затем `S98kas-control-center status` → `RUNNING / PANEL_ADDRESS:192.168.1.1:18080`. **Повторный Gate:false и интерактивные клики ещё не присланы**; аппаратный UI PASS пока не объявлять. Документация/UX beta.7 должны объяснять и безопасно завершать recovery после port-migration #377, не удаляя gate вручную.



> **Уточнение после изучения отображаемой страницы и исходников:** клиентский UI всё же получает динамические данные по API: Mihomo 1.19.33, MT 0.8.2-1, footer beta.6 и состояние watchdog. Карточка `«Обновление панели прервалось. Новая версия панели не запустилась»` указывает на активный **durable self-update gate** после `PANEL_START_FAILED` (сохранён при ошибке запуска на legacy 8081). В `panel-update.js` при `FAIL + Gate` вызывается `occupy(true)`, а `main.go` блокирует mutating HTTP во время `panelUpdate.gate()`. Это высокая по достоверности гипотеза первопричины «неактивных кнопок»; подтвердить GET `/api/updates/panel/operation` на реальном NC-4210. **Не удалять gate руками.** Штатное восстановление: `/opt/bin/kas-control-center -recover-panel-update` после подтверждения отсутствия активного opkg/worker, c безопасным integrity/receipt verification и рестартом лишь WEB. Реальное выполнение/успех не подтверждены и не должны подменяться исходниками.
>
> Дополнительно есть очевидный frontend UX-дефект: `panelStageKey` ошибочно считает dotted prerelease `0.1.0.beta.6` стабильным и пишет в sidebar «Стабильная версия». Исправить парсер version/release stage тестами, отдельно от recovery.



**Новая задача [#379](https://github.com/saymer-alt/keenetic-auto-setup/issues/379).** После успешного IPK upgrade beta.5→beta.6 и исправления сохранённого порта на 18080 на реальном NC-4210 сервис `RUNNING`, но владелец сообщает: **«почти ни какие кнопки» не работают**. Причина ещё неизвестна; не считать CI 18/18 доказательством FIELD UI PASS. Разделить проблемы загрузки JS/инициализации, навигации, disabled state и реальных POST/GET API ошибок по DevTools Console/Network. Без секрета/cookies/YAML в отчёте.

- Требуется воспроизвести и исправить до релиза beta.7; если массово воспроизводится, рассмотреть отдельный beta.6.x hotfix и не ждать большого Network Doctor.
- После исправления добавить **интерактивный browser regression** (реальные клики, меню, кнопки обновления, Doctor, экспорт YAML, настройки/метрики, безопасные негативные запросы), UI asset integrity/CSP/API smoke; QEMU/Go/JS tests сами по себе не заменяют реальный браузер.
- Это отдельная задача от миграции legacy 8081 [#377](https://github.com/saymer-alt/keenetic-auto-setup/issues/377). Не трогать работающие маршруты/службы роутера, Core/stable или Release без GO.

### P0. Автоматическая миграция legacy-порта 8081 при обновлении (FIELD NC-4210)

**Обязательный release gate beta.7:** [#377](https://github.com/saymer-alt/keenetic-auto-setup/issues/377) — новое решение владельца после реального обновления NC-4210 `beta.5 → beta.6`. Хотя IPK/SHA256 прошли, beta.6 не запустилась (`PORT_BIND_FAILED`): legacy settings сохранили `8081`, занятый системным nginx. Ручная корректировка только `8081 → 18080` дала `RUNNING` / `PANEL_ADDRESS: 192.168.1.1:18080`. **Нельзя повторять этот сценарий для пользователей beta.4/5, переходящих на beta.7.**

- На подтверждённом upgrade c legacy `8081` **самостоятельно однократно переводить** настройки на `18080`, при `EADDRINUSE` на следующий свободный `18081..18090`; без ручного редактирования JSON. Не путать с новой установкой, для которой default/fallback уже существует с beta.6.
- Поскольку в schema v1 нет достоверного указания «8081 выбран автоматически или вручную», уведомлять в диалоге подтверждения обновления о смене именно устаревшего `8081`, а не выдавать эвристику за знание provenance; для SSH/opkg — аналогичный читаемый журнал и recovery. Сохранить прочие явно пользовательские порты и настройки, особенно `auth_mode`, пароли и ограничение доступа.
- Миграция/резервная копия/откат только с безопасными атомарными операциями, честным listener-bind, ограниченным fallback, ясным `PANEL_ADDRESS` и корректным новым URL. Проверить потерю текущего origin/upgrade UI и необходимость ручной перенастройки KeenDNS proxy (без автоматического изменения KeeneticOS).
- Тестировать переходы beta.4/5/6, занятый 8081 и 18080, все варианты auth/Home-only, reboot, повторный update, read-only сохранность KAS Core/MT/Mihomo; обязательна аппаратная проверка NC-4210 и KN-1012 SE.

**Приоритет P0 выше функционального P1 Network Doctor в окончательной сборке beta.7.** Можно вести реализацию параллельно в отдельных ветках/PR, но выпускать beta.7 без решённой migration #377 нельзя.

### P0 / P1. Network Doctor — главная функция beta.7

Задачи: [#323](https://github.com/saymer-alt/keenetic-auto-setup/issues/323), [#270](https://github.com/saymer-alt/keenetic-auto-setup/issues/270), [#158](https://github.com/saymer-alt/keenetic-auto-setup/issues/158), [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266).

**Уже есть:** независимый CLI `kas-network-doctor.sh` с контрактом `network-diagnostics/v1`, поддерживающий текущую таблицу маршрутизации роутера и отдельную SOCKS5h-пробу через Mihomo. Есть `kas-download-check.sh`; их не нужно писать с нуля. Имеющийся флаг `--dns-server` **не** означает выбор исходящего интерфейса.

**Цель GUI:**
- В разделе «Диагностика» форма ввода одного публичного домена/IPv4/HTTP(S) URL; явная кнопка запуска, отображение стадии и копируемого краткого/полного очищенного отчёта.
- Выбор маршрута: `default` (фактическое решение маршрутизации самого роутера), `Mihomo SOCKS5h`; далее, **только после доказанного CLI и E2E**, конкретный WAN, поддерживаемый VPN либо последовательный `Все поддерживаемые`.
- Для каждой поддерживаемой проверки отдельные факты DNS / TCP / TLS / HTTP, наблюдаемый код, время, состояние `PASS/FAIL/UNKNOWN/UNSUPPORTED/NOT TESTED`. Не выводить «сайт работает у клиента» из успешного curl с роутера.
- Не фальсифицировать доказательство egress: `curl --interface`, `ip global`, название ProxyN или IP-геолокация по отдельности не подтверждают реальный маршрут. Неподдерживаемый VPN/ProxyN отображать как `UNSUPPORTED`.
- Thin Go/JS adapter только над единым CLI-движком; не создавать второго алгоритма DNS/TCP/TLS в Web.

**Безопасность / производительность:** ручной запуск; HTTP(S) only, SSRF/redirect/DNS-rebinding/IP-list policy, запрет localhost/RFC1918/link-local/metadata/управляющих адресов по умолчанию, безопасные аргументы без shell interpolation; строгие connect/total timeout, лимит размера/числа выходов, последовательные пробы, single-flight, no logs of secrets, без обязательных пакетов. Не менять маршруты, DNS, firewall, политики, watchdog, состояние Mihomo/MT. Никаких внешних проб при открытии страницы.

**Scope gate:** для beta.7 обязательна работающая безопасная форма `default` + `Mihomo`; расширенный выбор WAN/VPN и `Все` — только после проверенного CLI и нативного сетевого proof, не блокировать базовую диагностику недоказанным ProxyN/VPN.

### P1. MagiTrickle: эффективный DNS/Netfilter/route Doctor

Задача [#327](https://github.com/saymer-alt/keenetic-auto-setup/issues/327); Draft PR [#326](https://github.com/saymer-alt/keenetic-auto-setup/pull/326) + зависимый [#338](https://github.com/saymer-alt/keenetic-auto-setup/pull/338) (stacked — **сначала #326, потом #338**, после проверки актуальности `main`).

- Раздельно выводить configured scope `app.link` (DNS endpoint br0/br1), эффективные `iptables/ipset/marks/ip rule/routes` и policy/overlay. Не утверждать, что `app.link:[br0]` исключает MT-marked трафик br1.
- Сохранять признаки `OPKG-off` только как диагностическое A/B-наблюдение, **не доказательство причины**; не пытаться автоматически выключить OPKG или исправить firewall.
- Не раскрывать пользовательские домены, группы, URL подписок, токены, ключи или конфиги. Read-only, BusyBox ash, mocked snapshots/ported E2E, отрицательные тесты.

### P1. Watchdog identity в полном Doctor

Задачи [#335](https://github.com/saymer-alt/keenetic-auto-setup/issues/335), [#337](https://github.com/saymer-alt/keenetic-auto-setup/issues/337).

- beta.6 (#362) должна дать в **Web карточке** сравнение SHA256 установленного watchdog с известным снимком исходников; это **не** semver и не полный идентификатор ревизии watchdog.
- В `mihomo-doctor.sh`, раздел 8 «Watchdog», добавить фактический путь/тип установки, полный SHA256 и **только проверенную** самостоятельную ревизию (при наличии надёжного manifest/receipt/catalogue) либо явное «версия/ревизия не подтверждена».
- Использовать совместимую семантику с Web, без отдельной выдуманной версии и без изменения watchdog. Отчёт должен сохраняться полностью при копировании из Web. Обработать symlink, unreadable, файл меняется, отсутствует sha256sum, legacy layout, secret redaction.

### P1 / acceptance. KeenDNS, порт и небольшие улучшения WEB

Задачи: [#349](https://github.com/saymer-alt/keenetic-auto-setup/issues/349), [#348](https://github.com/saymer-alt/keenetic-auto-setup/issues/348).

- Провести отдельную приёмку KeenDNS/HTTP proxy для нового beta.6 default **18080**: браузерные GET + POST, Origin/Host, роутерная авторизация и доверенный локальный proxy peer, Home-only/прямой доступ. Ранее записанное в #349 `8081` — устаревший порт для **новой** установки; ранее сохранённый `8081` не менять молча.
- Не создавать отдельные аккаунты или новые WAN firewall-правила. Сохранять штатную авторизацию KeeneticOS (если используется) и защиту от поддельных заголовков; не выводить защиту из одного имени домена.
- По факту кода `main` от 03.11.2026 **кнопка «Скачать текущий YAML» уже реализована**: `web/index.html` содержит `config-download`, Go регистрирует `/api/config/download`. Не включать повторную реализацию в beta.7. Только регрессия: скачивание правильного `config.yaml`, no-store, error handling, безопасность при обычном авторизованном доступе.
- Малый UX из #348 — пояснение, почему штатный script-install не имеет `kas-core.ipk`; наглядный RUNNING, размещение версии в шапке, короткие RU/EN подсказки Doctor — **проверить наличие перед реализацией**, не устраивать новый redesign.

### P2 / условно, если P1 стабилен

- Тонкая Web-оболочка для `kas-download-check.sh` (ошибки curl/TLS/GitHub, экспорт результата), отдельная read-only кнопка, no automatic downloads; [#266](https://github.com/saymer-alt/keenetic-auto-setup/issues/266).
- При необходимости аккуратно включить текущие Draft read-only наблюдатели: [#329 IPv6](https://github.com/saymer-alt/keenetic-auto-setup/pull/329), [#343 штатный OpkgTunN](https://github.com/saymer-alt/keenetic-auto-setup/pull/343), только после CI и тщательного ревью. Не менять `mitun0` на `tun0` автоматически.

## 3. Явно НЕ beta.7 (отдельные Core/R&D треки)

- [#240](https://github.com/saymer-alt/keenetic-auto-setup/issues/240): ручное управление Ping Check в интерфейсе — **после** Native-First исследования KeeneticOS, не внедрять сомнительные shim или автоуправление.
- [#328](https://github.com/saymer-alt/keenetic-auto-setup/issues/328): Watchdog 2.0 recovery-политика и дорогие incident-пробы; не менять принятие решения о рестарте ради отчёта.
- [#295](https://github.com/saymer-alt/keenetic-auto-setup/issues/295): KAS Core IPK.
- [#355](https://github.com/saymer-alt/keenetic-auto-setup/issues/355): S28/S99 Mihomo; [#356](https://github.com/saymer-alt/keenetic-auto-setup/issues/356): broken BusyBox/Entware — самостоятельные Core reliability issues, а не неявные релизные блокеры beta.7.
- Traffic Explorer, WDTT/CSQTT/OpenFlux providers, Config Studio, массовая замена маршрутизации и новые фоновые демоны — за пределами beta.7.
- Никаких изменений на реальных роутерах, `stable`, ядре KAS, Pages или release без отдельного явного GO.

## 4. Порядок работ будущего агента

1. **Discovery/read-only**: проверить `main`, Release/Pages beta.6, CI #363, действующие файлы, PR #326/#338/#329/#343, актуальные issues. Составить evidence matrix: уже сделано / Draft / отсутствует / непроверено.
2. **Контракт CLI**: сначала доработать `kas-network-doctor.sh` и тесты, если новые выходы требуют изменений, строго сохранив обратную совместимость `network-diagnostics/v1` или явно версионировав `v2`.
3. **Web thin adapter**: отдельная ветка PR, однократный bounded запуск, безопасные URL/route, RU/EN форма, краткий/полный отчёт и копирование.
4. **Doctor MT**: ревью #326 → #338, разбор конфликтов с main, проверки на эмуляторе и независимые негативные тесты.
5. **Doctor Watchdog**: отдельный PR/тесты #337 без изменения runtime watchdog.
6. **KeenDNS + UX**: реальная проверка beta.6 и только доказанные исправления.
7. **Integration gate**: единый кандидат beta.7 после code review; Go + Node + POSIX sh/BusyBox ash, test matrix ошибок DNS/TCP/TLS/HTTP, SSRF, WAN/VPN, port/auth, QEMU/ported, IPK all ABI, no regressions.
8. **Publication stage**: после явного GO владельца использовать единственный действующий version-agnostic candidate-builder, штатный Release publisher и отдельный Pages experimental deploy. Проверять SHA/tag/run/4 IPK и публичные HTTP индексы, не менять Core Latest/stable. Целевые `v0.1.0-beta.7` / `0.1.0.beta.7-1` — предложение, подтвердить через действующий package-version contract после beta.6.

## 5. Definition of Done / стоп-условия

- Для **разработки**: все P1-обязательные функции интегрированы и протестированы, сведения корректны, нет side effects; каждый unsupported/unknown отображён честно.
- Для **релиза**: beta.6 аппаратно оценена, интеграционная beta.7 CI зелёная, 4 IPK + checksums подтверждены, Release опубликован после GO и experimental Pages подтверждён внешним HTTP-запросом.
- Любой реальный блокер означает `BLOCKED` с точным evidence, а не фиктивный PASS. Если WAN/VPN выбор нельзя честно доказать, выпустить надёжный `default + Mihomo` и перенести рискованную часть отдельно.

## 6. Инструкция переноса в новый чат

Открыть новый чат и приложить ссылку на этот файл + репозиторий. Первым сообщением попросить:
«Начинаем KAS WEB beta.7. Прочитай `docs/kas-web-beta7-handoff-2026-11-03.md`, сравни план с актуальными `main`, Release/Pages beta.6, задачами #323/#327/#337/#349 и PR #326/#338. Начни с доказательной матрицы и первого самостоятельного Draft PR Network Doctor CLI/Web. Никаких merge/публикации/действий на роутерах без моего отдельного GO. Не реализуй повторно уже существующее скачивание YAML».
