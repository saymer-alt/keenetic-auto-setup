# Coordinator C0 — офлайн-модель решений (Issue #456)

**Текущий рубеж: дизайн и проверяемая симуляция; НЕ готовый агент или автозапуск.**
Родительские зависимости: #430 (transport), #454 (GitHub checkpoint), #453 (подтверждённый исполнитель и квота).
Реальную интеграцию C1 не выполнять до завершения этих зависимостей и отдельного GO владельца.

## Что реализовано

Чистая функция `decide(Observation) -> Decision` в `scripts/orchestration-poc/coordinator_policy.py`.
Нет доступа к сети, `gh`, CLI, ключам, устройствам, CI, GitHub Actions и LLM. **Она не выполняет** действие, а лишь
выдаёт ограниченное *предложение* с `source=C0_OFFLINE_UNVERIFIED`.

`Observation` — недоверенный снимок. Даже `ci_verified=True` является только входным утверждением: сама политика
не доказывает подлинность CI. В будущем этот флаг сможет выставлять исключительно отдельный read-only verifier, который
независимо получает GitHub Actions run и сверяет точный head SHA/URL/состояние Issue. Не пытаться получать доказательство
успеха из текста Issue, PR description, ответа LLM или комментария агента.

## Decision table v0

| Условие | Ответ политики | Реальное действие |
|---|---|---|
| Kill switch, чужой repo, неверный task/run/SHA, закрытая/изменённая Issue, запрещённый scope, вторая задача | `STOP` | Никаких |
| Не подтверждён транспорт/исполнитель/квота или бюджет закончился | `STOP` | Никаких |
| Исполнитель есть, но владелец не дал GO на запуск | `OWNER_REVIEW` | Никаких |
| Всё подтверждено, READY, GO на исполнителя, ≥1 вызов в бюджете | `PLAN_DISPATCH` | **Только план** |
| CLAIMED/RUNNING до таймаута | `WAIT` | Никаких |
| CLAIMED/RUNNING после таймаута | `STOP` | Никаких автоматических повторов |
| REVIEW_READY, CI ещё неизвестен | `WAIT` | Никаких |
| CI нельзя независимо связать с точным head SHA/разрешённым run URL | `STOP` | Никаких |
| CI FAILURE, причина исправима, проверен SHA, бюджет есть и было менее двух разных попыток | `PLAN_REWORK` | **Только план** |
| Повтор идентичного CI failure после исправления или две попытки исчерпаны | `OWNER_REVIEW` | Никаких |
| CI SUCCESS, но Native E2E ещё не проверен | `WAIT` | Никаких |
| Shell CI SUCCESS, Native E2E FAILURE | `OWNER_REVIEW` / `NATIVE_E2E_FAILED` | Никаких, требуется разбор |
| Native workflow SUCCESS, но `gates.json` содержит FAIL | `OWNER_REVIEW` / `NATIVE_GATES_FAILED` | Никаких |
| Native workflow SUCCESS, но совокупный `gates.json` BLOCKED | `OWNER_REVIEW` / `NATIVE_GATES_BLOCKED` | Никаких, явно обозначить ограничения |
| Shell CI SUCCESS + Native workflow SUCCESS + независимо подтверждённый `gates.json` PASS + ревью APPROVED | `OWNER_REVIEW` с `OWNER_DECISION` | Merge не выполняется |
| REVIEW blocked/changes requested | `OWNER_REVIEW` | Никаких |

**Никакой путь не возвращает команду `merge`, `release`, `deploy`, shell-команду или право на изменение роутеров.**
Ошибочные поля, bool вместо int, испорченные идентификаторы, подменённые ссылки CI — FAIL CLOSED.
Один активный исполнитель, не более двух запланированных исправлений, никаких бесконечных agent-to-agent циклов.

## Прогон (не требует токенов и сети)

```sh
python3 -m unittest discover -s scripts/orchestration-poc/tests -v
```

Тесты `tests/test_coordinator_policy.py` проверяют стоп-условия, исчерпание бюджета, лимиты,
подмену CI SHA, неподтверждённый PASS, ограничения повторов и отдельный owner GO.

## C0 evidence split — обязательная проверка Native E2E после инцидента #465

В PR #458 Shell CI был SUCCESS, а Native E2E FAILURE из-за `KAS_FOREIGN_RESOURCES = FAIL`
(`native_rules_not_ready`). В сравнительном запуске #463 GitHub Actions Native E2E завершился SUCCESS,
но загруженный `gates.json` имел общий outcome BLOCKED. **Workflow success ≠ aggregate acceptance PASS**.
Обычная строка из вывода агента «тесты прошли» также не служит доказательством.

В `Observation` раздельно описаны `ci_*` (Shell contracts) и `native_e2e_*` (Native E2E),
а также `native_gates_outcome` и `native_gates_verified`. Ветвь `REVIEW_READY` не может
перейти в `OWNER_DECISION` при одном только Shell CI SUCCESS. Для полного предложения
`REVIEW_READY_OWNER_MERGE_GO_REQUIRED` требуются **два независимых URL GitHub Actions**
с совпадающими `head SHA`, результаты SUCCESS обоих workflow и отдельно подтверждённый
`gates.json` outcome PASS. `FAIL` / `BLOCKED` в агрегате передаются владельцу
с отдельной причиной, не превращаясь в CI/FIELD PASS.

**Доверительная граница:** эти поля по-прежнему передаются как *недоверенный вход*.
`native_gates_verified=True` не доказывает подлинность артефакта. Для следующей стадии
необходим самостоятельный read-only verifier, который сверяет run ID, commit SHA,
тип workflow, загруженный артефакт `gates.json` и его содержимое (включая отдельные
FAIL/BLOCKED gates) с указанным запуском. В этой C0-ветке ни verifier, ни настоящая
публикация, ни автоматический merge **не реализованы**. Причину
`native_rules_not_ready` в эмуляторе по #465 эта правка не исправляет.

## Что НЕ готово

- Нет доказанного `Issue → исполнитель → PR/CI → checkpoint → координатор` без ручного копирования.
- Нет живого Github read-only verifier для CI; mock-only evidence не превращать в CI PASS.
- Нет автоматики, фонового сервиса, расписания, второго агента или синхронизации с Windows-процессом.
- `#458` разрабатывается другим агентом и не изменяется этим C0 PR.
- Нет права на merge без отдельного решения владельца.

**Rollback:** удалить два новых Python-файла и этот документ; существующие KAS и orchestration CLI не затрагиваются.
