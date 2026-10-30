# GitHub inventory and safe cleanup plan — snapshot 30.10.2026

Status: **plan only**. Nothing is deleted, closed, unpublished or force-pushed by
this document. Every irreversible action requires a separate explicit owner GO,
as fixed in #282 and the release-hygiene ledger (#292). Numbers are a snapshot,
not a deletion list: between the original cleanup request and this snapshot the
owner already retired 9 short-lived prereleases into
[`kas-web-legacy-tests-archive-20261030`](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/kas-web-legacy-tests-archive-20261030)
with metadata and SHA256 evidence (#292, runs 41031652114+) and removed 9
publish-only branches.

Snapshot: **52 branches, 26 releases (8 of them WEB prereleases), 35 tags, 33
open PRs**. Live updater state: `kas-web-channel-experimental` →
`kas-web-ipk-92e301d` (v0.1.0~beta.1-1); the pilot KN-1010 runs test17
(`0.0.1~test44.9c715283d525-1`).

## KEEP — обязательно сохранить

Product lines and live updater wiring:

| Объект | Почему нельзя трогать |
|---|---|
| `main`, `stable` | продуктовые линии ядра KAS; защищены ограничениями задачи |
| release `kas-web-channel-experimental` | **действующий индекс обновлений** WEB; единственный asset `panel-update.json` читают установленные панели |
| release `kas-web-ipk-92e301d` | цель действующего индекса (beta.1); updater проверяет его assets по SHA256 |
| release `v0.1.0-beta.1` | первая публичная бета; source-pinned на 92e301d |
| release `kas-web-ipk-9c71528` (test17) | версия, фактически стоящая на пилотном KN-1010; цель предыдущего индекса |
| release `kas-web-ipk-62a97a3` (test16) | hardware acceptance на KN-1010; regression reproducer; source SHA совпадает с веткой `feat/kas-web-night-acceptance` |
| release `kas-web-legacy-tests-archive-20261030` | сам архив метаданных/дайджестов удалённых тестовых релизов |
| releases `v1.0.0`…`v1.8.4` | история ядра KAS; `v1.8.4` — текущий GitHub latest (ядро, не WEB) |
| release `mihomo` (1.19.23-1, 2 assets) | реальные бинарные assets; скрипты обновления Mihomo ходят по GitHub releases этого репозитория (`update-mihomo.sh` использует `releases/tags/latest` с fallback) — перед любой уборкой сверить пути загрузки |
| tag `mihomo` и все 35 тегов | теги удалённых prerelease оставлены намеренно (#282: удаление тегов — отдельное решение); теги релизов ядра неизменяемы |

Branches — активная WEB-линия и открытые PR (33 открытых PR ссылаются на 33
head/base-ветки; удаление любой ломает открытый PR):

- `feat/kas-web-beta2-integration-20261030` (#291), `feat/kas-web-beta2-channels-20261030` (#293), `ops/kas-web-release-hygiene-20261030` (#292);
- `release/kas-web-v0.1.0-beta.1-prep` (92e301d) — source beta.1 и alias; теги `v0.1.0-beta.1` и `kas-web-ipk-92e301d` указывают сюда;
- `ops/publish-kas-web-beta1-20261030`, `ops/kas-web-beta1-experimental-channel-20261030`, `ops/kas-web-test17-publish-20261030` — one-shot workflows, опубликовавшие действующие релизы и индекс; CI-evidence и записанные процедуры публикации (переиспользуются как шаблон beta.2);
- вся цепочка стековых WEB PR #252→#287 (heads и bases: `feat/kas-control-center-stage1`, `feat/kas-control-center-yaml-import`, `feat/kas-web-opt-in-lifecycle`, `feat/kas-web-simple-lan`, `feat/kas-web-provider-names-export`, `feat/kas-web-exclude-filter-editor/apply`, `feat/kas-web-navigation`, `feat/kas-web-settings-ipk`, `feat/kas-core-ipk`, `feat/kas-web-mihomo-updates`, `feat/kas-web-component-updates`, `feat/kas-web-links-theme`, `fix/kas-doctor-package-selection`, `feat/kas-web-doctor-readable-report`, `fix/kas-web-editor-default-and-router-link`, `fix/kas-web-import-banner-scope`, `feat/kas-web-doctor-readable-report`, `fix/kas-web-operation-navigation-label`, `feat/kas-web-self-update`, `feat/kas-web-night-acceptance`, `feat/kas-web-test17-copy-20261030`, `feat/kas-web-ipk-panel` и связанные fix/feat-ветки);
- независимые линии с открытыми PR: `docs/autonomous-layer-contract-20261018` (#157), `docs/research-multitransport` (#171), `feat/mt001-provider-contract-v0` (#175), `feat/mt002-offline-validator` (#181), `docs/fork-sync-v2-r9` (#206), `docs/readme-interactive-yaml-import-20261022` (#200), `docs/keenetic-ip-global-priority-20261025` (#228), `fix/issue41-netfilter-apply-errors` (#260), `feat/bootstrap-config-import-fetch` (#284), `docs/pstack-verification-20261030` (#286).

## CANDIDATE LATER — убрать после явных условий (не сейчас)

Условие для всей группы: merge #291 (интеграция WEB в main), затем merge #293 и
beta.2-реализации; после этого содержимое цепочки физически в main и история
сохранена в PR. Только тогда — отдельным GO владельца, одним проверяемым проходом:

1. Закрыть драфты #252–#287 (superseded by #291) — **после** merge #291, не раньше.
2. Удалить ветки цепочки WEB PR (перечислены выше в KEEP как heads/bases открытых PR — статус меняется после закрытия PR).
3. Удалить оставшиеся 10 веток `publish/kas-web-ipk-*` (08ae70e, 57ea99c, 66d976e, 77ac40e, 894a524, b0e3c0c, c0dac74, c3cc2ce, c8f7c58, kas-web-ipk-checksums-c0dac74, kas-web-ipk-control, kas-web-kn1010-ui-66ab147): открытых PR на них нет, релизы удалены в #292, теги сохранены, бинари в архиве. Проверить перед удалением, что ни один issue/док/агентский пейнтборд не ссылается на ветку (ссылки на **теги** допустимы и сохраняются).
4. Releases `kas-web-ipk-77ac40e` (test15) и `kas-web-ipk-c0dac74`: по #282 сохранить 2–3 диагностически значимых тест-релиза — уже сохранены test16/test17/beta.1, поэтому test15 и c0dac74 — кандидаты на архивирование тем же способом (метаданные + SHA256 в архив-релиз, затем удаление release; теги остаются).
5. `research/wdtt-csqtt-wg-obfuscator-20261011`, `feature/wdtt-experimental-poc-20261011` — research-ветки без PR; заархивировать выводы в docs, затем удалить ветки.
6. `feat/kas-web-secure-lan` (e2149ec) — содержимое входит в интеграцию; кандидат после merge #291.

## UNKNOWN — нужна проверка перед решением

| Объект | Что проверить |
|---|---|
| `ci/emulator-pin-final` (41246cc) | PR нет, в main не влит. Сравнить pin эмулятора с `ported-native-e2e.yml` в main/#291: если значение перекрыто — кандидат на удаление, иначе довести отдельным PR |
| `ops/kas-web-integration-20261030` (a54d964) | предшественник `feat/kas-web-beta2-integration-20261030` (5a881ba); убедиться, что 5a881ba включает его содержимое (diff пуст), затем кандидат |
| release `mihomo` и путь обновления Mihomo | подтвердить, использует ли `update-mihomo.sh`/`install.sh` этот релиз/тег напрямую; до проверки — KEEP |
| ссылки в issues/агентских заданиях на `kas-web-ipk-77ac40e`, `kas-web-ipk-c0dac74` | поиск упоминаний перед архивированием (grep по issues/PR/docs) |
| 35-й тег из `git ls-remote --tags` | сверить полный список тегов со списком релизов: аннотированные дубликаты `^{}` не должны остаться «висячими» |

## Как интегрировать WEB в main, не трогая стабильное ядро

Порядок слияний (каждый шаг — отдельный PR с зелёным CI и ревью):

1. `#292` (release-hygiene ledger) → main: только docs/ops-workflows, риск нулевой.
2. `#291` (интеграция, 141 файл) → main: ревью полного диффа + полный CI; это единственная точка, где WEB попадает в main.
3. `#293` (канальный контракт) → поверх #291, затем beta.2-реализация (`release/kas-web-v0.1.0-beta.2-prep`, стоит на голове #293) → тот же стек.
4. После merge: пуш ветки `ops/publish-kas-web-beta2-20261030` с запиненными `SOURCE_SHA`/`VERIFIED_RUN` — канонический prerelease `v0.1.0-beta.2` и переключение индекса (backup + restore-on-failure) — **только по отдельному GO**.
5. Владелец вручную обновляет пилотный KN-1010 с test17/beta.1 на beta.2; индекс к этому моменту канонический.
6. Stable-путь панели (`kas-web-v0.1.0`, `kas-web-channel-stable`, сборка `--channel stable`) — после hardware acceptance по #282; GitHub latest остаётся за ядром v1.8.x.

На всём пути: `stable` ядра не меняется; latest не переключается; установленные
KAS/Mihomo/MagiTrickle не затрагиваются; ничего не удаляется.

## Способ восстановления

- Код: ветки восстанавливаются из git (reflog/event API хранит 90 дней) и из сохранённых бандлов/патчей; стековая история полностью содержится в закрытых PR даже после удаления веток.
- Релизы: бинари удалённых prerelease — в `kas-web-legacy-tests-archive-20261030` (3 assets, SHA256); метаданные 16 prerelease заархивированы в #292 (коммит 9506287).
- Действующие ссылки updater: `kas-web-channel-experimental` + `kas-web-ipk-92e301d` + `v0.1.0-beta.1` + `kas-web-ipk-9c71528` не удалять никогда без переноса индекса.

---

## Исполнено 30.10.2026 (после интеграции #291/#293)

### Ветки удалены (независимые устаревшие, не базы открытых PR; SHA записаны, восстановление из локального клона/Actions)

| Ветка | SHA | Причина |
|---|---|---|
| ops/kas-web-integration-20261030 | a54d9641e18ef043c5a2936cafe81e25cb0362d6 | полностью перекрыта #291 (5a881ba: тот же WEB-набор + workflow staging больше не нужен) |
| ops/publish-kas-web-beta1-20261030 | 6f91e3683a45a0b7da3d8e766b10c36602107c9c | one-shot публикация beta.1 исполнена; шаблон заменён beta.2 ops-workflow |
| ops/kas-web-beta1-experimental-channel-20261030 | 6e34f3a7ba0157e1c8fb6a471e5ff41c14af5d1d | one-shot переключение индекса на beta.1 исполнено |
| ops/kas-web-test17-publish-20261030 | f3ef0824a0bec22f4d844f71345ef1d3b3cd1ad2 | one-shot публикация test17 исполнена |
| publish/kas-web-ipk-c8f7c58 | 991b1fd2c1d117dfcfb0d19e9193eefa79c4bd48 | publish-only; релиз удалён в #292, бинарники в архиве |
| publish/kas-web-ipk-checksums-c0dac74 | 6b21edd939d67555b17292a07e93f3beb8c2ba73 | разовая нормализация чек-сумм удалённого c0dac74 |
| publish/kas-web-ipk-control | 5b2d2cfc19adf802cf0db81227836335e2b2fc18 | остановка superseded-публикации |
| ci/emulator-pin-final | 41246cc607c224e22628c3acd9907692cc4c80da | пин 36a63b6 перекрыт 94d447d в интеграции |

Ранее владельцем уже удалены: publish/kas-web-ipk-{08ae70e,57ea99c,66d976e,77ac40e,894a524,b0e3c0c,c0dac74,c3cc2ce}, publish/kas-web-kn1010-ui-66ab147.

### Осознанно сохранены (не WEB-консолидация / активные)

`ops/gitlab-mirror-sync` (активная работа владельца, PR #296 слит), `research/wdtt-*`,
`feature/wdtt-*`, все `docs/*` с PR, MultiTransport (#171/#175/#181), WDTT (#124/#125),
`feat/bootstrap-config-import-fetch` (#284), `fix/issue41-netfilter-apply-errors` (#260),
`feat/kas-core-ipk` (база будущих работ по #295), `release/kas-web-v0.1.0-beta.1-prep`
(source живой beta.1 — до завершения перехода на beta.2).

### Релизы: архивирование кандидатов

`kas-web-ipk-77ac40e` (test15) и `kas-web-ipk-c0dac74`: оригинальные бинарники + SHA256SUMS
проверены (test15 — с учётом нормализации GitHub `~`→`.`) и добавлены в архив
`kas-web-legacy-tests-archive-20261030` как `legacy-test-releases-2-20261030.tar.gz`
(sha256 7746779e31d2ab37dd917423ce4b3b86ae8a8031fb4569367ec60e48ab6f521c) + `SHA256SUMS-2`.
Сами релизы предлагаются к удалению отдельным GO владельца (пока сохранены);
исходные теги остаются в репозитории.
