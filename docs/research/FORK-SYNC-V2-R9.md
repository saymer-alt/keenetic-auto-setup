# Fork fleet: upstream sync v2 — система, аудит, статус (2026-10-22)

**Статус:** сопровожденческая документация задания №9. Draft, без merge. Результаты реальных прогонов — ссылками; ничего на устройствах не устанавливается.

## 1. Что делает система

Каждый из семи форков (`saymer-alt/{OpenFlux,csqtt,swinter-android,swinter-ios,maxcalls,whitelist-bypass,whitetransport-public}`) имеет:

- `.github/workflows/upstream-sync-review.yml` — ежедневный cron (разнесён по времени: 08:11…09:31 UTC) + `workflow_dispatch`; explicit `permissions: contents: write, pull-requests: write`; repo-guard `if: github.repository == 'saymer-alt/<fork>'`; `concurrency` (сериализация); `actions/checkout` pinned by SHA.
- `.github/scripts/upstream-sync-review.sh` — вся логика (тестируемая, 46/46 локальных синтетических сценариев).

**Канал A (branch tracking):** upstream default branch → при опережении форка создаётся `sync/upstream-<sha12>` + **Draft PR**; открытые предложения **обновляются обычным merge-коммитом** (никогда force-push); конфликт → предложение не трогается, остаётся WARN-комментарий (один на SHA); неразрешимое расхождение → явный failure (без reset/-X theirs).

**Канал B (release tracking):** upstream `releases/latest` (stable only — drafts/prereleases исключены контрактом API) + точный SHA тега; новый релиз → `sync/upstream-release-<tag>` + Draft PR с анализом отношения к default branch (содержит/опережает/расходится), release notes, категориями-подсказками (workflows/зависимости/лицензия/протокол-auth/build-deploy) и разбором prereleases. Кейс «релиз опубликован, а main стоит» (OpenFlux v0.13.0) покрывается именно этим каналом.

**Кросс-дедупликация:** branch-предложение не создаётся, если его контент уже покрыт открытым release-предложением (и наоборот); тег, чей PR был закрыт без merge, повторно не предлагается; существующая ветка без PR → WARN, без перезаписи. Десять запусков подряд — ноль дублей.

**Запреты (by design):** нет merge в default branch, нет force-push/reset, нет `gh release create`, нет исполнения upstream-кода (только git fetch/rev-list/merge), нет изменения DNS/маршрутов/устройств.

**Известное ограничение платформы:** GitHub не выдаёт GITHUB_TOKEN permission `workflows` ни на каком уровне (422 «Unexpected value 'workflows'» — проверено прогонами). Следствие: sync-ветку, чей diff изменяет `.github/workflows/*`, бот запушить не может; скрипт распознаёт этот случай и выдаёт понятное сообщение с ручным fallback (owner-account создаёт предложение; пример — OpenFlux v0.13.0, PR #7).

## 2. Этап D — доказательство создания PR ботом

`csqtt` workflow `bot-pr-smoke.yml` (dispatch-only): прогон [39812107606](https://github.com/saymer-alt/csqtt/actions/runs/39812107606) → бот `app/github-actions` создал Draft PR #8 с синтетической веткой `test/bot-pr-smoke-39812107606`. CI на PR от GITHUB_TOKEN **не запустился** (подтверждено отсутствием `pull_request`-прогонов; документированное ограничение GitHub). После проверки PR закрыт, ветка удалена.

## 3. Этап E — аудит двух отключённых workflow

### OpenFlux `nightly.yml` (наследие upstream; state: disabled_manually)

- Автор: upstream p1neappleXpress. Триггеры: push в ветку `nightly`, ежедневный schedule, workflow_dispatch; `contents: write`.
- Публикует **пререлизы** `nightly-<date>-<commit>` (кросс-компиляция CLI), хранит последние 7 (старые release+tag удаляет).
- Защита от лишней публикации встроена: план-шаг строит только если существует ветка `nightly` с непокрытым коммитом; в нашем форке ветки `nightly` нет → при включении workflow был бы ежедневным no-op.
- Решение: **остаётся отключённым** (нам не нужен собственный nightly-канал; это исследовательский тестовый канал upstream). Восстановление = создать ветку `nightly` (opt-in by design); правок кода не требуется. Sync-PR и merge в main этот workflow не будят.

### whitetransport-public `public-provisioning-release.yml` (наследие upstream; state: disabled_manually)

- Автор: upstream meanwebuser. Триггеры: push тегов `v*-public.*`, workflow_dispatch c input tag, push в main **по paths** (`.github/workflows/<self>`, `.github/public-release-request`, `.github/public-release-trigger`); `contents: write`.
- Действие: пересборка и **загрузка assets к уже существующему public-релизу** (verify exact tag: `git describe --exact-match`, checkout --detach).
- Риск: sync-merge в main, затрагивающий paths-набор (например, upstream изменил собственный workflow-файл), запустил бы пересборку/загрузку автоматически. Поэтому отключение оправдано.
- Решение: **остаётся отключённым**. Если когда-нибудь понадобятся собственные provisioning-сборки — отдельный Draft PR с manual-only триггером (только workflow_dispatch + явный tag input), без push-путей. Сейчас потребности нет.

## 4. Этап G — supply-chain итоги по v2

| Проверка | Статус |
|---|---|
| Минимальные permissions | PASS — только `contents: write` + `pull-requests: write` (верхний уровень); `workflows`-scope недоступен GITHUB_TOKEN вовсе (подтверждено 422 на fix2/fix3) |
| Постоянные PAT/секреты | PASS — только GITHUB_TOKEN; никаких PAT не создано |
| `pull_request_target` | PASS — отсутствует во всех 7 |
| Исполнение upstream-кода до ревью | PASS — только git-операции; checkout — форковой default branch |
| Upstream не может молча изменить release-автоматику | PASS — CI/release workflow изменения попадают только через Draft PR + ruleset-защищённый main (и именно этот кейс дал документированный ручной fallback) |
| Автопубликация при PR/push sync-веток | PASS — ни один активный workflow не публикует по этим событиям; релизные — только по тегам v*/node-v*; nightly/provisioning отключены |
| Проверка upstream URL | PASS — UPSTREAM_REPO фиксирован в workflow + repo-guard + format-check в скрипте |
| Подмена Git-тега | PARTIAL — тег резолвится в точный SHA и сравнивается по SHA; криптоподписи тегов не проверяются (upstream теги не подписаны); верификация — человеком на ревью PR |
| Гонки двух запусков | PASS — `concurrency` per-repo, cancel-in-progress: false |
| 403/404/409/rate limit | PASS с оговоркой — 404 релизов → idle; ошибка API → WARN + branch-трекинг продолжается; отказ создания PR → явный failure с инструкцией; конфликты → явный failure. Rate-limit на `releases/latest` завершит release-канал с WARN до следующего запуска |

## 5. Этап H — статусная матрица (снята 22.10.2026 после fix4-прогонов)

| Fork | Upstream | Default branch | Latest upstream release | Fork release status | Pending Draft PR | Protection | Actions | Последний прогон | Blocker / действие |
|---|---|---|---|---|---|---|---|---|---|
| saymer-alt/OpenFlux | p1neappleXpress/OpenFlux | main | v0.13.0 @ 2026-10-16 | UPDATE AVAILABLE | #7 release v0.13.0 (manual fallback) | PASS (ruleset) | PASS | [39814779544](https://github.com/saymer-alt/OpenFlux/actions/runs/39814779544) | ревью+merge #7 — отдельно владельцем |
| saymer-alt/csqtt | amurcanov/csqtt | main | v2.5.0 @ 2026-10-20 | UPDATE AVAILABLE | #3 branch sync; release-PR по итогу прогона | PASS | PASS | [39814791587](https://github.com/saymer-alt/csqtt/actions/runs/39814791587) | ревью #3 (MERGE RECOMMENDED);-license: Cargo 2.5.0 = Unlicense при PolyForm в корне — уточнить |
| saymer-alt/swinter-android | somewhat-industries/swinter-android | main | нет релизов | UNKNOWN (no releases) | нет | PASS | PASS | [39814803260](https://github.com/saymer-alt/swinter-android/actions/runs/39814803260) | нет |
| saymer-alt/swinter-ios | somewhat-industries/swinter-ios | main | нет релизов | UNKNOWN | нет | PASS | PASS | [39814815973](https://github.com/saymer-alt/swinter-ios/actions/runs/39814815973) | нет |
| saymer-alt/maxcalls | icyfalc0n/maxcalls | master | нет релизов | UNKNOWN | нет | PASS | PASS | [39814827858](https://github.com/saymer-alt/maxcalls/actions/runs/39814827858) | нет |
| saymer-alt/whitelist-bypass | kulikov0/whitelist-bypass | main | v0.4.4 @ 2026-09-22 | CURRENT (тег в форке) | #1 branch sync (MERGE RECOMMENDED) | PASS | PASS | [39814839982](https://github.com/saymer-alt/whitelist-bypass/actions/runs/39814839982) | ревью+merge #1 владельцем |
| saymer-alt/whitetransport-public | meanwebuser/whitetransport-public | main | v0.5.1 @ 2026-09-05 | UPDATE AVAILABLE, **конфликт** | нет — предложение блокировано | PASS | PASS | [39814853202](https://github.com/saymer-alt/whitetransport-public/actions/runs/39814853202) | **ручной merge релиза v0.5.1** (форк расходится с релизной линией; автоматика корректно отказалась без reset) |

Прогоны: pass = предложение создано/обновлено/подтверждено актуальным либо корректный NO CHANGES; явные failure остаются только там, где требуется человек (конфликт релиза в wtp).

## 6. Хронология дефектов, пойманных реальными прогонами

1. `branch_pr: unbound variable` при behind=0 + доступный релиз (OpenFlux-кейс) → инициализация + сценарий 16b.
2. `KeyError: tag_name` на 404-теле `/releases/latest` → jq-фильтр + сценарий 17.
3. `workflows: write` в permissions — GitHub отвергает на любом уровне (422) → revert (fix4) + helper `push_branch` с внятной диагностикой.
4. Push-блок GITHUB_TOKEN на diff с `.github/workflows/*` → документированный ручной fallback (реализован на OpenFlux#7).
