# Agent Orchestration POC-1 — готовые решения и локальный POC (issue #430)

**Дата proof: 07.11.2026. Режим: reuse-first, read-only. Base `main` `db36be0d3bfc0408fd8a98793fd83f26450c9bc2`.**
Все факты проверены на этой Windows 10.19045 машине и снабжены командой-доказательством; гипотезы помечены явно.

## 1. Сравнение готовых вариантов

| Вариант | Задачу получает по ID | Результат в GitHub | Windows | Авторизация | Стоимость | Ручные действия | Статус |
|---|---|---|---|---|---|---|---|
| **gh CLI + POC-скрипт** (выбран) | да, `gh issue view N` | checkpoint-файл/комментарий вручную после GO | да | существующий `gh` keyring (`saymer-alt`) | 0 | 1 команда запуска | **VERIFIED** (17/17 unit + live-демо) |
| ZCode CLI headless (`--prompt`) | да (через handoff) | stdout/JSON локально, в GitHub — не сам | да (v0.17.1 найден) | общая с приложением — **NOT_VERIFIED** | Coding Plan если заработает | 1 команда | **NOT_VERIFIED** (нет выбора модели, см. §2) |
| OpenCode GitHub Actions | да (`/opencode` в issue) | да, сам пишет PR/комментарии | hosted runner | GitHub App OIDC или PAT + **API-ключ модели** | платный API модели | установка интеграции | **NOT_VERIFIED/BLOCKED**: Coding Plan в Actions не подтверждён документацией; локальная установка = отдельный GO |
| Symphony (openai) | Linear-centric spec | PR/reference | — | Codex App Server | — | долгоживущий supervisor | OVERKILL для 1 исполнителя, не исследовался глубже (по условию) |
| Gas Town | мультиагентная память | свой daemon | — | — | — | постоянная инфраструктура | OVERKILL, отвергнут |

Вывод: минимум ручных переносов уже достигается связкой **Issue → `gh` (чтение) → contract → dry-run executor → checkpoint → ChatGPT читает GitHub**. Все переходы состояний `READY → CLAIMED → RUNNING → REVIEW_READY/BLOCKED → OWNER_DECISION` реализованы и покрыты тестами.

## 2. Проверенные факты (доказательства, 07.11.2026)

1. **ZCode CLI v0.17.1 присутствует** в Windows-инсталляции, но отдельного `zcode.exe` на PATH нет; запуск подтверждён:
   `ELECTRON_RUN_AS_NODE=1 "...\ZCode.exe" "...\resources\glm\zcode.cjs" --help` (node v24.21.0).
2. **Headless-интерфейс есть**: `-p/--prompt`, `--json`, `--cwd`, `--attach`, `--resume`, `-c`, `--disallowed-tools`, `--target`, `app-server`. В `--help`: `--mode` default **yolo** для `--prompt` — предупреждение из #430 подтверждено на фактической сборке.
3. **Флагов `--model`/`--provider` в CLI нет** (parse-level probe: `Unknown option '--model'`; найденные в бандле строки — из встроенных чужих CLI-схем).
4. **Выбор модели в headless идёт из первого включённого правила personal provider config** (`~/.zcode/v2/provider_config.json`): у владельца первым стоит «Gemini API Key» → CLI ушёл на `generativelanguage.googleapis.com` и получил **HTTP 429** с экспоненциальными ретраями (визуально «зависание», нет быстрого fail). С пустым personal-config — корректный быстрый fail `Error: Select a model before sending a message`.
5. **Z.AI Coding Plan в инсталляции есть** (`~/.zcode/v2/coding-plan-cache.json`: `builtin:zai-coding-plan: available`; модели GLM-5.3 / GLM-5.3-Flash), но headless CLI его **не выбрал**; механизм выбора Coding Plan в CLI **NOT_VERIFIED**. Проверка через `zcode.cjs login zai` не выполнялась сознательно: это изменение credential-состояния = отдельный owner GO.
6. **Windows-ловушка кодировки**: `gh auth status` печатает UTF-8 (`✓`); subprocess в cp1251-локали падает на декодировании. В POC применён `encoding="utf-8", errors="replace"` (совпадает с «environment facts» из `docs/agent-token-efficiency.md` §3).
7. **gh 2.100.0** авторизован (`saymer-alt`, scope repo+workflow); live-чтение Issue #430 и негативные кейсы POC отработали на реальном GitHub. Транзиентный сетевой сбой GitHub в live-прогоне корректно завершён `STOP_NETWORK` (fail-closed подтверждён на реальном отказе).
8. **Поддерживаемый способ выбора модели в headless CLI v0.17.1 (статически, по бандлу):** `ZCODE_MODEL` **не существует**; схема personal provider config (`provider_config.json`, путь перекрывается env `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE`) содержит поля `config.providerOrder` (массив id) и `config.defaultModelSelection` со схемой `{providerId, modelId, options.reasoningLevel?}`. `builtin:zai-coding-plan` — валидный `providerId`. Отбор модели в headless: `intent.modelSelection ?? defaultModelSelection` (ошибка `Select a model before sending a message` возникает, когда оба пусты). Пробные конфиги без обязательного `schemaVersion` отбрасываются ЦЕЛИКОМ (молча) — поэтому тест с неполным файлом дал «Select a model». **Эмпирическое подтверждение end-to-end требует одного реального модельного вызова → отдельный GO-A**; модельные вызовы в этом исследовании не выполнялись, авторизация не менялась, секреты не выводились.

## 3. Что делает POC (`scripts/orchestration-poc/kas_orchestrate.py`)

- `fetch --issue N` — валидация (gh auth; **gh-аккаунт = владелец репозитория** через `gh api user` → `STOP_BAD_ACCOUNT`; repo-allowlist; схема Issue: number/title/body/url/updatedAt — любое расхождение = `STOP_MALFORMED_ISSUE`; `state==OPEN`), чтение ровно одной Issue, фиксация `base_sha` из `git rev-parse`, генерация компактного task contract (поля из Stage 1 #430: `task_id, issue, repo, base_sha, allowed_paths, intent, DoD, required_gates, token_budget_soft, stop_conditions, owner_go_scope, status`) и handoff, где исполнитель получает команду `gh issue view N --repo R` — **текст задачи никем не перепечатывается**.
- `dispatch --executor dry-run|mock|zcode-cli` — **stale SHA перепроверяется перед dispatch** (`HEAD != base_sha` → `STOP_STALE_SHA`, state не меняется); dry-run печатает точную команду (всегда `--mode plan`, yolo/build/edit запрещены конструкцией, обязателен env `ELECTRON_RUN_AS_NODE=1`) и **не занимает задачу** (state остаётся READY); mock имитирует полный цикл для тестов — **это НЕ доказательство полноценной автоматизации**; zcode-cli запускает headless с таймаутом: **ненулевой exit code → `STOP_EXECUTOR_FAILED`, задача → BLOCKED — ложный PASS невозможен**; таймаут → `STOP_EXECUTOR_TIMEOUT`, BLOCKED; при любом сбое исполнителя задача переводится в BLOCKED в журнале.
- `checkpoint` — **stale SHA перепроверяется** перед генерацией; локальный структурированный чекпоинт (`task_id | base/head SHA | PASS/FAIL/BLOCKED/NOT_TESTED | evidence | blocker | next owner decision`); публикация в GitHub заблокирована двойным opt-in и в POC не вызывается.
- **Межпроцессная блокировка**: OS-lock (`fcntl`/`msvcrt`) на `<state-dir>/.lock` на время любой команды; конфликт → `STOP_LOCKED`; lock освобождается ОС при смерти процесса, stale-файл невозможен.
- STOP-условия (exit 2): `NO_AUTH, BAD_ACCOUNT, BAD_REPO, ISSUE_CLOSED, MALFORMED_ISSUE, NETWORK, DUPLICATE, ACTIVE_TASK, STALE_SHA, OVERSIZE (тело >50 KB усекается маркером), WRITE_NOT_ALLOWED, UNSAFE_MODE, EXECUTOR_MISSING/TIMEOUT/FAILED, LOCKED, STATE_CORRUPT, CONFIRM_REQUIRED`.
- State: `<state-dir>/current_task.json` + append-only `events.jsonl` (кэш; GitHub остаётся источником истины). По умолчанию вне репозитория.

**Live-демо на Issue #430 (read-only, ветка POC `7791868`):** `fetch` → `task_id issue-430-7791868268f9`, base SHA = HEAD ветки, account-проверка пройдена; `dispatch dry-run` → корректная команда, state READY сохранён; `checkpoint NOT_TESTED` → файл создан; `reset --confirm` → state очищен. Отдельным прогоном подтверждён live fail-closed: реальный транзиентный сбой GitHub → `STOP_NETWORK`, повтор после сбоя успешен.

## 4. Ручные переносы до/после (демонстрационный цикл)

| Шаг | До (сегодня) | После (POC) |
|---|---|---|
| Постановка задачи в исполнитель | владелец копирует промпт ChatGPT → ZCode | 0: исполнитель читает Issue по ID |
| Возврат результата/логов | владелец копирует ответ | 0: checkpoint-файл/PR читает ChatGPT из GitHub |
| Логи CI | копирование вручную | 0: ссылки/SHA |
| Owner GO | сохраняется | сохраняется (отдельные GO на запись/merge/dispatch) |
| Токены/стоимость | **NOT_AVAILABLE** | **NOT_AVAILABLE** (в POC модель не вызывалась; жёсткие вызовы 3 × мини-промпт ZCode CLI — на Coding Plan не списаны, ушли в 429 чужого провайдера) |

## 5. Следующий минимальный шаг до полного конвейера (нужны owner GO)

1. **GO-A (model selection, самый дешёвый путь):** способ найден статически (§2.8): задать `config.defaultModelSelection = {"providerId": "builtin:zai-coding-plan", "modelId": "GLM-5.3-Flash"}` (+ опционально `providerOrder`) — либо в постоянном `provider_config.json` (изменение общих настроек = GO), либо одноразово через env `ZCODE_PERSONAL_PROVIDER_CONFIG_FILE` на копию конфига с обязательным `schemaVersion`. После GO-A — один read-only `--prompt --mode plan --json` закрывает NOT_VERIFIED исполнителя. Альтернатива, если defaultModelSelection не сработает: `zcode.cjs login zai` (отдельное изменение credentials = свой GO).
2. **GO-B (write):** разрешить `gh issue comment` для публикации checkpoint — включить существующий, уже реализованный путь `--post` (двойной opt-in уже в коде).
3. **GO-C (установка, опционально):** локальный OpenCode для проверки «Z.AI Coding Plan локально»; только затем — проверка GitHub Actions-интеграции (там модель = API-ключ, Coding Plan документацией не подтверждён).
4. После 1–2 — заменить `dry-run` на реального исполнителя на одном небольшом Issue (не #430) и заполнить таблицу метрик из `docs/agent-token-efficiency.md`.

## 6. Границы

POC не содержит: авто-merge, тегов/релизов, изменений `main`/`stable`, Actions/webhooks/серверов, доступа к роутерам, секретов. ChatGPT в контуре только читает GitHub сам и даёт владельцу развилку решений; LLM↔LLM-циклов нет. Публикация raw-транскриптов исключена: в checkpoint попадают только поля-факты.
