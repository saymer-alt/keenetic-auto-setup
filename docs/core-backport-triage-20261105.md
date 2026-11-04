# Core Sync Guard: триаж расхождений main/stable после v1.8.7 (issue #401)

> Снимок: `main=2ae4a29121f6c7124895d3ece7cf496c74abad54`, `stable=40e175f81cf67ae9ea19597d67e46b3a9f3bdb8c` (2026-11-05).
> Метод: `git rev-parse <ref>:<file>` для blob SHA, `git diff stable..main -- <file>` для содержимого,
> `git log --oneline stable..main -- <file>` + `git log -S` для атрибуции коммитов.
> Read-only анализ. Этот документ не является разрешением на backport или изменение baseline.

## 1. Полная матрица (8 REVIEW-находок)

Guard run 41818637702 показал 7 находок; восьмая (`uninstall.sh`) добавлена merge #403 после написания issue.

| # | Файл | stable blob | main blob | Диф | Источник (коммит → PR) | Классификация |
|---|---|---|---|---|---|---|
| 1 | `config-import.sh` | `892224586a0d` | `9978c9d0a061` | +118/−2 | `5513aa5` → **#366** | **BACKPORT-CANDIDATE (P1)** |
| 2 | `install.sh` | `aa5fde5ba483` | `3b181b61fdad` | +84/−11 | `5513aa5` → **#366** | **BACKPORT-CANDIDATE (P1)** |
| 3 | `update-mihomo.sh` | `caf8bea819f9` | `9627ba1ff11b` | +66/−4 | `5513aa5` → **#366** | **BACKPORT-CANDIDATE (P1)** |
| 4 | `mihomo-watchdog.sh` | `e07797c1fca9` | `0a430a155d7e` | +115/−27 | `5513aa5` → **#366** (весь диф) | **BACKPORT-CANDIDATE (P1, split-замечание)** |
| 5 | `mihomo-doctor.sh` | `9100087e64ee` | `5df0f6ff9abd` | +195/−49 | `de4fa1b` → **#386** + `082fa22` → **#402** | **BACKPORT-CANDIDATE (P2)** |
| 6 | `kas-download-check.sh` | отсутствует | `e6d21c5ccaf9` | +437 | `5ea5453` → #306, `b6530ef` → #378 | **MAIN_ONLY_BY_DESIGN** (решение владельца) |
| 7 | `kas-entware-preflight.sh` | отсутствует | `b6ca6f467298` | +234 | `487a9bc` → #400 | **NEEDS_FIELD_EVIDENCE** (#356/#408 активны) |
| 8 | `uninstall.sh` | отсутствует | `f534cc7144ee` | +284 (файл целиком main-only) | `2ae4a29` → #403 (+ история #300+) | **MAIN_ONLY_BY_DESIGN** (осознанно вне stable) |

Каждый диф проверен по содержимому, не только по списку коммитов.

## 2. Производственное влияние на stable сегодня

Upstream Entware (`entware-go` `ee4b689`) переименовал packaged init-скрипт `S99mihomo` → `S28mihomo`.
stable=v1.8.7 содержит жёстко прописанный `S99mihomo`:

| Сценарий на S28-only установке (новая Entware-лента) | stable v1.8.7 сегодня | С RESOLVER-СРЕЗОМ #366 |
|---|---|---|
| `config-import.sh` | **импорт конфигурации невозможен** (hardcoded `INIT_SCRIPT=.../S99mihomo` → error до импорта) | работает через резолвер |
| `install.sh` (start/restart/check) | «S99mihomo not found, cannot manage Mihomo service» | работает |
| `install.sh` fresh-Entware detection | **S28-only стек неправильно классифицируется как не-fresh** (пути без S28) | оба пути в списке |
| `mihomo-watchdog.sh` restart | `[RESTART-FAIL]`-цикл при реальной деградации | перезапуск через резолвер с identity-проверкой |
| `update-mihomo.sh` | `find -name '*mihomo*' \| head -1` — **произвольный выбор при S28+S99** (риск второго экземпляра) | fail-closed «ambiguous» |
| `mihomo-doctor.sh` | S28-only: INFO «non-standard name» (функционально, косметика); iptables v1.8.9 prefixed-текст классифицируется как generic read error (#386) | верная классификация + packaged-init verification (#402) |

S99-only (существующие инсталляции, fork-лента `saymer-alt/entware-go`) не затронута: резолвер возвращает
S99 как валидный второй кандидат.

## 3. Верификация safety-контрактов (выполнена по фактическому содержимому диффов)

| Контракт | Результат | Доказательство |
|---|---|---|
| `now_ms()` v1.8.7 (десятичная дробь, не octal) | **СОХРАНЁН в обеих ветках** | функции побайтно идентичны (diff пуст); `faf73a7` — main-копия того же фикса, вошедшего в v1.8.7 через squash #372 |
| One-Mihomo при S28+S99 | **FAIL-CLOSED во всех 4 runtime-скриптах** | идентичный блок `MIHOMO INIT RESOLUTION v1`; updater: «ownership is ambiguous … a second Mihomo instance must not be started»; регрессия `tests/mihomo-init-contract-regression.py`: «both usable → ambiguous fail closed» (exit 2) |
| Подмена произвольным `head -1` | **устранена** | `update-mihomo.sh`: явный текст в диффе; ранее `find\|head -1` мог выбрать любой из двух |
| Watchdog: cooldown/lock/jitter/«no WAN → no restart» | **не изменены** | хунк диффа не затрагивает lock (`mkdir`-lock), jitter, порядок WAN→port→SOCKS проверок; рестарт идёт через `"$MIHOMO_INIT_RESOLVED" restart` с identity-верификацией `wd_restart_identity` (before/after, старый PID исчез) — строго консервативнее stable |
| Cooldown при каждой попытке | **усилен** | «Consume cooldown for every attempted command, including failures» — new в #366 |
| config-import транзакция (TTY, backup, atomic commit, rollback) | **не изменена** | диф +118/−2 — только выбор `INIT_SCRIPT` и диагностика |
| update-mihomo rollback/one-instance | **не изменён** | диф +66/−4 — только резолвер |
| Чужие ресурсы / ownership | **не изменены** | диффы не трогают ownership-журнал и foreign-ресурсы |

Итог: дельта #366 — это **выбор пути init-скрипта + диагностика**, без изменения транзакций, rollback и порядка проверок.

## 4. Предлагаемая последовательность выборочного backport

**Фаза 1 — один селективный PR от `stable` (S28-совместимость production):**
файлы 1–4 (`config-import.sh`, `install.sh`, `mihomo-watchdog.sh`, `update-mihomo.sh`) —
единый атомарный срез `MIHOMO INIT RESOLUTION v1` + точки вызова, плюс
`tests/mihomo-init-contract-regression.py` и хуки в `tests/lifecycle-regression.py`/`tests/contracts.sh`,
плюс минимальные CI-правки (dash/ash + native E2E release gate).

Обоснование атомарности: четыре файла несут один и тот же контракт; половинный срез
(например importer без watchdog) оставит production с mixed-поведением при рестартах.

Watchdog-замечание: диф включает identity-верифицированный рестарт (усиление из того же
коммита #366). Он строго консервативнее (больше путей RESTART-SKIPPED, ни одного нового
автоматического действия) — рекомендован к включению, но владелец может потребовать
отдельного split «только резолвер»; технически резолвер-блок и точка вызова отделимы.

**Фаза 2 — отдельный PR от `stable` (Doctor-диагностика):** файл 5 (`mihomo-doctor.sh`) —
#386 (prefixed iptables v1.8.9 absence-классификация + безопасные рекомендации) + #402
(packaged S28/S99 init verification). Не блокирует Фазу 1 (косметика + диагностика), но
рекомендована до следующего Core-релиза: новые Entware-ленты несут iptables 1.8.9+.

**Фаза 3 — решения владельца по каждому файлу индивидуально (не массово):**
- №6 `kas-download-check.sh`: standalone read-only диагностический инструмент (#306/#378).
  В stable, только если владелец намерен официально поддерживать его там; иначе
  acknowledgement точечной парой (`e6d21c5ccaf9`/absent, reason: main-only diagnostic).
- №7 `kas-entware-preflight.sh`: тема BusyBox 1.38 (#356) активно разрабатывается в lab (#408);
  классификация NEEDS_FIELD_EVIDENCE до полевых результатов.
- №8 `uninstall.sh`: full uninstall сознательно вне stable (существующий acknowledgement);
  #403 обновил файл в main → обновить acknowledgement на пару (`f534cc7144ee`/absent) после
  индивидуального review.

**Запрещено (по issue #401):** перенос всего `main` в `stable`; массовое признание всех
расхождений обновлением baseline; изменение семантики Core Sync Guard (SYNC-проверка
раньше acknowledged — новое расхождение всегда всплывает как REVIEW).

## 5. Риски и контрольные тесты backport-PR

| Риск | Митигация |
|---|---|
| Watchdog — чувствительный файл (docs/04) | диф не трогает порядок проверок/lock/jitter; требовать `tests/watchdog-diagnostics-regression.py` + `lifecycle-regression.py` + native E2E |
| Расхождение содержимого main/stable после backport | backport-PR режется от `stable`; squash-дифф должен быть подмножеством диффа #366 (проверяемо `git diff`); main не переписывать |
| Branch-specific тесты stable | переносить только резолвер-регрессию + её хуки; branch-specific docs stable не трогать |
| Ревью-усталость | один PR Фазы 1 (4 файла + 2 теста), один PR Фазы 2 (1 файл + регрессии) — два маленьких, не мегапатч |
| Очередной Core release | вопрос выпуска решается владельцем ТОЛЬКО после наличия доказательств (issue #401 п.6); без авто-релиза |

Контрольные тесты до merge Фазы 1 (все существуют в main, переносятся в PR):
`tests/mihomo-init-contract-regression.py` (включая negative-кейсы: both-usable, dangling link,
foreign-link, notexec), `tests/lifecycle-regression.py` (watchdog extraction carries resolver),
`tests/contracts.sh`-хуки, `sh -n`/busybox `ash -n`, native E2E release gate на итоговом SHA.

## 6. Что уже проверено и не требует действий

- `mihomo-doctor.sh` на stable уже читает Netfilter pair-probe (#310) — #386 добавляет только
  prefixed-классификацию поверх, конфликтов нет.
- Core Sync Guard остаётся advisory/read-only; REVIEW-статус 8 файлов — ожидаемое поведение,
  а не регрессия guard.
- Гонка «PR #389 маскирует новое расхождение» — не подтвердилась: SYNC-ветка чекера
  (`main_sha == stable_sha`) вычисляется до acknowledged-lookup.
