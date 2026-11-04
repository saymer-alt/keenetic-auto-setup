# KAS WEB beta.7 — план работ и handoff для нового чата (03.11.2026)

## Решение по выпуску beta.7 от 04.11.2026

Beta.7 включает четыре исправления панели [#381](https://github.com/saymer-alt/keenetic-auto-setup/pull/381), [#384](https://github.com/saymer-alt/keenetic-auto-setup/pull/384), [#385](https://github.com/saymer-alt/keenetic-auto-setup/pull/385) и [#387](https://github.com/saymer-alt/keenetic-auto-setup/pull/387). Автоматические проверки относятся к финальной интегрированной ревизии. Аппаратные проверки NC-4210 и KN-1012 SE выполняет владелец после публикации, статус до проверки — `FIELD NOT TESTED`.

Форма Network Doctor WEB перенесена в beta.8. Контракт [#382](https://github.com/saymer-alt/keenetic-auto-setup/pull/382) требует проверки фактического адреса назначения для прямых и SOCKS5h-проб и сопоставления селекторов с CLI. [#376](https://github.com/saymer-alt/keenetic-auto-setup/pull/376), карта [#383](https://github.com/saymer-alt/keenetic-auto-setup/pull/383) и связка MagiTrickle [#326](https://github.com/saymer-alt/keenetic-auto-setup/pull/326) → [#338](https://github.com/saymer-alt/keenetic-auto-setup/pull/338) остаются отдельными работами.

Разделы ниже сохраняют историю планирования. Объём текущего выпуска и порядок аппаратного допуска определены этим решением.

> **Статус: ROADMAP / DESIGN, не реализованный релиз.** Это закреплённый план следующего цикла, а не разрешение на merge, Release, Pages, `stable` или доступ к физическим роутерам. Проверять актуальные HEAD/CI/GitHub issues перед началом работ. Приоритет: сначала завершить и испытать beta.6.

## Актуализация 04.11.2026 — ревизия GitHub и новые независимые Draft PR

> Приоритетные данные от 04.11 имеют преимущество над историческим начальным порядком работ внизу файла. Здесь перечислен **фактический статус подготовки**, не разрешение на merge, установку, Release или Pages.

- **main:** `5fa32fc1d9a2db03212fe3fb848e3342e3b4cd95` (после информационного Core Sync Guard PR #373). **Официальная beta.6:** tag/source `070faa90e15855ae6076d8738c5dcec931059a36`, четыре IPK и SHA256SUMS; канонический builder `.github/workflows/kas-web-candidate-build.yml` после merged #375. Переименование workflow **закрыто**. *(retired 04.11.2026: Release object удалён, тег сохранён, assets в архиве — [release-hygiene/2026-11-04-kas-web-beta4-beta6-retired.md](release-hygiene/2026-11-04-kas-web-beta4-beta6-retired.md).)*
- **Pages:** deployment run #41712854453 `completed/success` на `070faa90…`, но независимый HTTP GET `channels.json` и `experimental/panel-update.json` в этой ревизии не прошёл: **HTTP content UNVERIFIED**, не объявлять подтверждённым.
- **Metrics #380:** standalone `kas-sys-metrics.sh` на NC-4210/ash 1.37 PASS; исправленный Web launcher остаётся только [Draft PR #381](https://github.com/saymer-alt/keenetic-auto-setup/pull/381), 17/17 CI success на `5330bace…`. 04.11 проведено code review COMMENT: changes limited to `router_metrics.go` + test; нет конфликтов с #373; настоящий исправленный `POST /api/metrics` / новый IPK на железе **не испытывался**.
- **P0 saved 8081 #377:** отдельный [Draft PR #387](https://github.com/saymer-alt/keenetic-auto-setup/pull/387): после фактического bind — одноразовая миграция при штатном `-lan -listen auto`, EADDRINUSE-only `18080…18090`, приватная backup-копия `.pre-beta7-8081.bak`, сохранение `auth_mode/password_hash` и Home-only, предупреждение/адрес в init status + Web. Есть [операторский runbook](https://github.com/saymer-alt/keenetic-auto-setup/blob/fix/web-beta7-legacy-8081-migration-20261104/docs/kas-web-beta7-port-migration-runbook.md) в ветке PR. **Требуются CI, code review, hardware**. Ограничение: старые JSON не фиксируют, выбирал ли владелец 8081 вручную, поэтому историческое происхождение порта нельзя доказывать.
- **P0 update recovery #379:** отдельный [Draft PR #384](https://github.com/saymer-alt/keenetic-auto-setup/pull/384) изменяет **только** текст/отображение recovery sentinel `State:FAIL, Phase:recovered, Gate:false` и RU/EN regression. Gate/worker не ослаблены, новый check обязателен. **Требуются CI и hardware UX**.
- **P1 prerelease label:** отдельный [Draft PR #385](https://github.com/saymer-alt/keenetic-auto-setup/pull/385): строка `0.1.0.beta.6-1` и другие prerelease больше не называются «Стабильная версия»; тесты RU/EN. **Требуются CI и визуальная проверка**.
- **Network Doctor #323:** [#376](https://github.com/saymer-alt/keenetic-auto-setup/pull/376) — CLI stage A/B, 3 CI success, без hardware WAN/VPN proof; [#382](https://github.com/saymer-alt/keenetic-auto-setup/pull/382) — только draft WEB-contract; [#383](https://github.com/saymer-alt/keenetic-auto-setup/pull/383) — карта инструментов, docs-only. Review COMMENT в #382: **pre-resolve SSRF недостаточен против DNS rebinding/remote SOCKS5h lookup**; требуются IP pinning / equivalent effective-address enforcement и точное отображение `default` / `mihomo` без несуществующих CLI flags. Не начинать опасную Web-реализацию по контракту как есть.
- **MagiTrickle #327:** [#326](https://github.com/saymer-alt/keenetic-auto-setup/pull/326) и stacked [#338](https://github.com/saymer-alt/keenetic-auto-setup/pull/338), по 18 CI success, но ни один не merged; review/diff #338 после #326, тесты на поле отдельно. Никакого изменения маршрутизации.

### Приоритет и порядок безопасной интеграции beta.7

1. **FIELD regression blockers P0:** review/owner GO на независимый #381 (не переписывать), #387 (миграция), #384 (recovery), #385 (semver label); устранить все CI red до интеграции. Эти PR изолированы и **не merged**.
2. **Сформировать один beta.7 integration candidate только после отдельного GO на merge.** Проверить совместимость PR друг с другом, в т.ч. применение #381 поверх текущего main; не трогать beta.6 tag/source, рабочую stable/Core, не запускать IPK на живых роутерах.
3. **Network Doctor minimal:** использовать единственный CLI `kas-network-doctor.sh` и существующие JSON-контракты, Web default+Mihomo только после исправления SSRF/DoS/budget/cancel контракта; один ручной запуск. `if:DEV/all` из #376 после CLI review и доказуемого route proof, **не release-blocker** базового режима; ProxyN без netdev — UNSUPPORTED.
4. **Read-only MagiTrickle:** review #326 → #338 (проверка effective netfilter и group semantics, никаких автоисправлений). Watchdog #335/#337 — только подтверждённый source/identity + SHA и честный UNKNOWN при отсутствии evidence. Использовать уже имеющиеся механизмы, не размножать Doctor.
5. **Критерии выпуска:** отдельный владелец GO; Web Go/Node shell/BusyBox, QEMU, 4 ABI/IPK, upgrade beta.4/5/6→beta.7, rollback settings, auth/Home-only, -recover-panel-update, KeenDNS GET/POST, Health metrics 503 regression, user-visible beta tag; NC-4210 и KN-1012 SE аппаратная test matrix. По завершении — штатный candidate-builder, publisher и Pages *только по отдельным GO*.

### Аппаратная test matrix (перед Release)

| Device / scenario | Expected | Proof |
| --- | --- | --- |
| NC-4210 (текущая первая beta.6 `b7d97c2…`) | отличать установленную сборку от опубликованной `070faa90…` при равном IPK version | installed binary/source checksum + receipt, не вывод по одному opkg |
| NC-4210, saved 8081 | bind 18080 или fallback 18081–18090, 0600 backup, UI/status сообщает новый URL | startup output, read-only settings/backup inspection, HTTP GET |
| NC-4210, existing custom port / auth / Home-only | порт/пароль/firewall policy не меняются; EADDRINUSE/EACCES честно fail-closed | reboot & settings comparator |
| NC-4210, manual self-update recovery | `Gate:true` блокирует; после штатного explicit recover → `Gate:false`, `State:FAIL/Phase:recovered`, понятный UX и повторная проверка версии | verified receipt/GET operation/JS |
| NC-4210 BusyBox ash 1.37 | `POST /api/metrics` HTTP 200 valid `router-metrics/v1`; UNKNOWN temperature не ломает load/RAM/uptime | actual candidate IPK API, independently read-only collector |
| NC-4210 / KN-1012 SE | beta prerelease label корректен; no background probes, no accidental KAS Core changes | screenshots, browser tests |
| KN-1012 SE clean/new/upgrade | auto default 18080, saved port persistence, LAN + explicitly permitted WAN & KeenDNS GET/POST with Host/Origin/auth intact | browser+curl, existing router firewall policy, no auto-rule |
| Both routers, Network Doctor after owner GO | default and Mihomo separately reported; no SSRF or private-target probes; WAN/VPN UNKNOWN/UNSUPPORTED where route not proven | bounded JSON+text, no route/firewall mutation |

## Обновление статуса после выпуска beta.6 (03.11.2026, подтверждено GitHub)

- **beta.6 ОПУБЛИКОВАНА И ОФИЦИАЛЬНО ПЕРЕИЗДАНА 03.11.2026:** [Release v0.1.0-beta.6](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/v0.1.0-beta.6), пакет `0.1.0.beta.6-1`, GitHub prerelease, четыре IPK + SHA256SUMS. **Текущий release/tag SHA `070faa90e15855ae6076d8738c5dcec931059a36`** (после [PR #375](https://github.com/saymer-alt/keenetic-auto-setup/pull/375), универсальный candidate-builder). Изначальная публикация была собрана с `b7d97c297a70c90980d932bf571cd0ff6ee52ad9`; это теперь исторический, а не действующий release SHA.
- [Интеграционный #363](https://github.com/saymer-alt/keenetic-auto-setup/pull/363) merged (`2f18c1742955f9b352d9131375ce43c10d9faec8`), [фикc имени артефактов #370](https://github.com/saymer-alt/keenetic-auto-setup/pull/370) merged. Не повторять интеграцию исходных PR #359–#362.
- **Действующая официальная цепочка beta.6:** [candidate 41709977498](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41709977498) → [publisher 41711796790](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41711796790) → [Pages deploy 41712854453](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/41712854453), всё completed/success на SHA `070faa90…` (GitHub API). Переизданы пять активов: IPK `aarch64-3.10` 2835820 байт, `armv7-3.2` 2854506, `mips-3.4` 2752307, `mipsel-3.4` 2730268, `SHA256SUMS`; агент сообщил попакетную SHA256/manifest сверку. По отчёту агента experimental Pages теперь ссылается на `070faa90…`; GitHub Pages deploy SUCCESS подтверждён через API, **независимый HTTP GET опубликованных JSON в этой сессии не удалось выполнить**. Проверять [channels.json](https://saymer-alt.github.io/keenetic-auto-setup/updates/channels.json) и [experimental/panel-update.json](https://saymer-alt.github.io/keenetic-auto-setup/updates/experimental/panel-update.json) при выпуске следующей беты. Старые candidate/publisher run `41701185022`/`41702447669` и Pages `41703509323` только исторические.
- **Hardware FIELD beta.6 пока PARTIAL (NC-4210); KN-1012 ещё требует приёмки.** На NC-4210 есть реальный upgrade с первой опубликованной сборки `b7d97c2…`, ручной перенос занятого legacy-порта 8081→18080, recovery self-update gate, рабочие кнопки обновлений, и standalone PASS всех метрик через script-file; **WEB metrics API установленной beta.6 FAIL** до отдельного исправления [Draft PR #381](https://github.com/saymer-alt/keenetic-auto-setup/pull/381). Установленная первая IPK beta.6 имеет **тот же package version** `0.1.0.beta.6-1`, но иной исходный SHA, чем переизданный релиз `070faa90…`: учитывать в provenance/identity checks, не считать новый релиз уже установленным. Продолжить проверки password-file 401/200, KeenDNS/Origin/Host и Doctor.
- **Workflow P0 ЗАКРЫТ через [PR #375](https://github.com/saymer-alt/keenetic-auto-setup/pull/375):** `main` содержит `.github/workflows/kas-web-candidate-build.yml`, а старый `.github/workflows/web-beta3-build.yml` удалён (GitHub API `404`); необходимые publisher/dryrun/docs обновлены и проверены агентом. Workflow dispatch на main требует явные `version`, `previous_version`, `tag`, `artifact_prefix`; push запускает тесты, без crossbuild IPK. Для beta.7 **использовать новый builder**, не переименовывать его повторно. Корректный выпуск beta.6 через него уже опубликован; впредь не пересоздавать одинаковую tag/package version без отдельного обоснованного решения.
- Дополнительные beta.6 production bugfix, обязательные для регрессии beta.7: watchdog `now_ms()` с zero-padded дробью uptime `090` (POSIX shell arithmetic) и `auth_mode:none` + `-password-file` (пароль 401/200). Они уже включены в релизную ветку main; не отменять.

## 1. Исходная точка и зависимости

- Репозиторий: https://github.com/saymer-alt/keenetic-auto-setup
- Историческая запись на момент первоначального плана (уже не текущий статус): **интеграционный Draft PR #363** https://github.com/saymer-alt/keenetic-auto-setup/pull/363 (порт `18080`, fallback `18081..18090`, Mihomo API `v1.19.33`, read-only `router-metrics/v1`, watchdog source/hash evidence). Не объявлять её опубликованной, пока это не подтверждено GitHub Release и Pages.
- Релиз beta.6 уже опубликован и переиздан; на NC-4210 проведены первые **частичные** аппаратные smoke/upgrade-проверки, обнаружены #377/#379/#380. Полного FIELD PASS пока нет; регрессии beta.6 исправляются раньше новых функций.
- Исходные PR #359/#360/#361/#362 и интеграционный #363 не сливать повторно. Проверять фактический новый `main` после завершения beta.6; будущие ветки beta.7 создавать от актуального `main`, а не от beta.6 Draft.
- Инженерный протокол beta.5/beta.6: PR #358 и `docs/kas-web-beta5-field-lessons-2026-11-03.md` (пока находится в его ветке); не путать этот документ с принятой реализацией.
- Историческая проблема имени `web-beta3-build.yml` **уже решена** PR #375: текущий release beta.6 официально пересобран через `kas-web-candidate-build.yml` на `070faa90…`. Для beta.7 не повторять переименование и не запускать publisher с retired workflow.

## 2. Зафиксированный предварительный состав beta.7

### FIELD NC-4210 — после recovery CLI, новые симптомы beta.6 (03.11.2026)

- После `-recover-panel-update` **управляющие кнопки заработали**: успешно выполнены read-only Web-проверки обновлений Mihomo и MagiTrickle, переключение в «Диагностика», вызов кнопки системных показателей. Общее утверждение «в beta.6 не работает JS» **опровергнуто полевыми данными**, initial failure вызван gated failed update. Общий UI FIELD PASS **не получен**, а только частичная приёмка.
- **P1 UI error:** карточка обновлений продолжает показывать `PANEL_RECOVERED_CHECK_VERSION` как `«Обновление панели не завершено; объяснение недоступно»`. Это ожидаемый sentinel после успешного верифицированного recovery (`panel_update_worker.go/recover()` оставляет историю `State:FAIL, Phase:recovered` и удаляет gate). Нужно человекопонятно показывать восстановление панели и инструкцию отдельной проверки версии; не считать прошлое failed-update успешной транзакцией. Уточнить RU/EN mapping и regression, см. [#379](https://github.com/saymer-alt/keenetic-auto-setup/issues/379).
- **P1 UI error:** beta.6 `v0.1.0.beta.6` в футере, но надпись «Стабильная версия» — ошибка версии/ветвления в `app.js/panelStageKey` (дотированная beta распознаётся как stable). Исправить семантику релизного канала с тестами (вкл. stable, beta, prerelease, unknown), без версии, заданной по одному отсутствию `~`.
- **FIELD PASS исходного collector отдельно от API:** На реальном NC-4210 BusyBox ash 1.37.0 после замены ошибочного `sh -s` на `/bin/sh /tmp/kas-sys-metrics-beta6.sh --json /tmp/kas-metrics-field.json` получен `COLLECTOR_RC=0`, валидный `router-metrics/v1` JSON и PASS по всем четырём основным измерениям: температура SoC `63.0 °C` (`soc_thermal`), load `0.10/0.14/0.10`, uptime `1336679.21s`, RAM `1015068/299280 kB`, swap INFO `1047548/1047548 kB`. Корень 503 локализован в Go launcher, датчики и сам скрипт работают. **Новый IPK/WEB API на железе НЕ проверен** — это отдельный field gate после CI/GO. Подробный лог: [#380](https://github.com/saymer-alt/keenetic-auto-setup/issues/380).
- **Draft fix prepared:** [PR #381](https://github.com/saymer-alt/keenetic-auto-setup/pull/381) на отдельной ветке от актуального `main`, изменяет только `router_metrics.go` + `router_metrics_test.go`: приватный embedded-script temp file + `/bin/sh <file> --json <result>`, регресс-тест отклоняет `-s`. CI ещё не завершён; в real NC-4210 фикс ещё не проверен (бета.6 релиз не изменён), merge/publish только по отдельному GO.
- **FIELD ROOT CAUSE CONFIRMED, #380:** BusyBox ash 1.37.0 на NC-4210 отвечает `Invalid option "-s"`, `COLLECTOR_RC=245` и не создаёт JSON на реальный launcher из `router_metrics.go`: `exec.CommandContext(ctx, "/bin/sh", "-s", "--", "--json", path)` + `cmd.Stdin=embeddedScript`. Поэтому метрики HTTP 503: `METRICS_UNAVAILABLE`. **Исправить именно production Go launcher:** перенести доверенный embedded script в `0600` файл под приватным `0700` временным каталогом и запускать `/bin/sh <scriptfile> --json <resultfile>` с ограничениями timeout/clean-up/closed env; не создавать глобальных файлов в /opt, не менять сам сборщик ради обхода бага. Подтвердить работающий JSON и показания на реальном NC-4210, добавить BusyBox-native regression.
- **P1 metrics FIELD FAIL:** [#380](https://github.com/saymer-alt/keenetic-auto-setup/issues/380) — «Получить показатели» на NC-4210 вернул `METRICS_UNAVAILABLE` (HTTP 503 из `router_metrics.go` при ошибке исполнения/JSON/валидации embedded `kas-sys-metrics.sh`). Не интерпретировать как отсутствие температурного датчика: отдельное `temperature.UNKNOWN` допустимо и не должно блокировать остальные показатели. Проверить BusyBox ash 1.37.0 / env / JSON, read-only stdout + отчёт.
- **Информационно, НЕ ошибка установки WEB:** `kas-core.ipk` отсутствует при работающих скриптах KAS (должно показывать явно необязательность пакета); watchdog hash `14611cd83b49` есть, но ревизия не подтверждена (не назначать версию по одному хешу). Mihomo runtime API `1.19.33`, opkg `1.19.32-2` — зафиксировать расхождение и проверить логическую формулировку «Установлена актуальная версия и выпуска пакета» без выполнения upgrade.

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
