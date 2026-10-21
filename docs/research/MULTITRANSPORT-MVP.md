# MultiTransport MVP — план первого прототипа и спецификация provider v0

**Статус:** PLAN / DESIGN ONLY, 2026-10-21 (ред. 2 после ревью PR #171). Документ ничего не создаёт на роутерах/VPS и не разрешает merge/release; реализация любого этапа — только по отдельному owner GO. JSON Schema, парсер и тестовый код — **следующий** этап, здесь только Markdown-спецификация.
**Основание:** [MULTITRANSPORT-FEASIBILITY.md](./MULTITRANSPORT-FEASIBILITY.md), [ADR MT-001](https://github.com/saymer-alt/keenetic-auto-setup/issues/139#issuecomment-6324031186), [KAS #139](https://github.com/saymer-alt/keenetic-auto-setup/issues/139), [KAS #164](https://github.com/saymer-alt/keenetic-auto-setup/issues/164) (этап M2), [KAS PR #125](https://github.com/saymer-alt/keenetic-auto-setup/pull/125) (существующий адаптер `experimental/wdtt/`), ревью PR #171 (2026-10-21).

## Главный вопрос MVP

**Как минимальными усилиями и минимальным RAM превратить существующий WDTT в первый модуль будущей транспортной системы, не ломая работающий проект?**

Ответ: не писать новый транспорт и не трогать сетевой код WDTT вообще. Первый «модуль» = существующий бинарник + уже прошедший CI адаптер из PR #125, надетые на формальный контракт **provider v0**: JSON-манифест + 8 CLI-операций + redacted статус. Всё, что добавляется нового, — только схема, fixtures и тонкая shell-обёртка `doctor/status`, без второго supervisor и без изменения lifecycle WDTT.

## 1. Схема первого прототипа

```text
Keenetic (Entware)                                   VPS (владельца)
────────────────────────────────────────────         ─────────────────
KAS Core (setup.sh, Mihomo, Doctor)                  wdtt-suite/server.go
   │  работает как раньше, транспорт не обязан       (DTLS exit + WG wdtt0,
   │  существовать; пунктов меню не добавляет          10.66.66.1/16)
   │
   ├─ [on-demand] kas-transport <id> <op>            ← НЕТ резидентного демона:
   │    ├── читает manifest.json + status.json         живёт только пока
   │    ├── вызывает существующий adapter PR #125      выполняется команда
   │    └── отказ = exit-code + status, не «ремонт»
   │
   └─ transport.d/
        └── wdtt/ (адаптер PR #125, layout НЕ меняется)
             ├── manifest.json        (НОВОЕ: возможности, provenance)
             ├── status.json          (НОВОЕ: redacted, пишет только adapter)
             ├── versions/<v>/worker  (как в PR #125, SHA256-pinned)
             ├── STATE/               (pid+time+version — как в PR #125)
             ├── init.d, install.sh   (как в PR #125)
             └── config.json 0600     (owner-секреты, путь знает только adapter)
                    │
                    ▼
             worker (= wt-client, сеть не тронута, owner-lab guard — свойство сборки)
                    │
             127.0.0.1:1081 SOCKS5 TCP   ──> Keenetic Proxy Client (native)
                                             (привязка/выбор — вручную владельцем)
```

Схема — логическая: **файловый layout и механизмы остаются авторскими у PR #125**; `manifest.json`/`status.json` — только аддитивные файлы (см. §6).

Инварианты прототипа:
- **Один активный транспорт**, запуск только вручную (автозапуск — отдельный opt-in режим уже существующего адаптера).
- **Ноль новых постоянно живущих процессов**: manager — shell, выполняется по вызову; единственный supervisor — существующий механизм KAS PR #125.
- **Ноль изменений** в сетевом коде WDTT, в KAS Core, в Proxy0/Proxy1/DNS/firewall/IPv6/Mihomo; нет автоматического DIRECT/WAN fallback.
- RAM-пороги KAS не изменяются; MIPSel не объявляется поддержанным без физических испытаний.

## 2. Спецификация provider v0

### 2.1 Операции

`kas-transport <provider-id> <op>` (обёртка вызывает `transport.d/<id>/…`; имена — развитие словаря #139, механика — PR #125):

| Оп | Семантика | Идемпотентность | Примечание |
|---|---|---|---|
| `install` | проверить ABI/arch/MemAvailable, верифицировать артефакт (SHA256, ELF-арх, размер), положить `versions/<v>/worker` + `manifest.json`, записать state | да, повторный = no-op | гейты уже реализованы в PR #125 — расширять, не дублировать |
| `start` | manual-start процесса с owner-конфигом через существующий supervisor | повторный start при **owned_running** = no-op | до старта: admission MemAvailable (совместный KAS+WDTT ≥512 MB, #137) |
| `stop` | graceful (SIGTERM → таймаут → SIGKILL) **только** процесса, подтверждённого `owned_running()` | да | fail-closed: SOCKS-порт освобождается, ничего не «перекидывается» на DIRECT/WAN |
| `status` | redacted JSON: state-файл + ownership-проверка + проверка слушателя с владельцем | да, read-only, без внешних соединений | никогда не отправляет сигналы; никогда не печатает cmdline/секреты |
| `doctor` | локальные пробы — по умолчанию; E2E (TCP/UDP) — только явный owner opt-in | manual | см. §2.4 |
| `update` | staged: новый артефакт → проверка → атомарная подмена `versions/` → манифест | при ошибке = откат на предыдущую версию | требует свежего owner-GO на новый SHA; автозапуск не наследуется |
| `rollback` | возврат к предыдущей версии артефакта + state | да | автозапуск после rollback выключается (правило PR #125) |
| `uninstall` | удалить только свои файлы/процесс/PID | да | чужие процессы/порты не трогать |

Exit-codes контракта: `0` ok; `10` not installed; `11` admission fail (RAM/arch); `12` start failed; `13` doctor FAIL; `20` usage error. Тексты — на stderr; машиночитаемое — в stdout (только `status`/`doctor`).

### 2.2 Идентификация процесса (ownership) — переиспользовать PR #125 без упрощений

`kill -0` (или `-d /proc/PID`) **недостаточно**: PID мог быть переиспользован чужим процессом. `status` и `stop` обязаны подтверждать принадлежность PID существующей функцией `owned_running()` из `experimental/wdtt/service.sh` (ветка PR #125), которая уже реализует:

1. чтение `pid time version` из state-файла (файл — не symlink, поля валидны);
2. сверку времени запуска: поле starttime из `/proc/PID/stat` == записанному `time` (защита от переиспользованного PID);
3. отказ для zombie (`state != Z` в `/proc/PID/stat`);
4. сверку `/proc/PID/exe` с артефактом конкретной версии (`versions/<version>/worker`);
5. точную сверку argv из `/proc/PID/cmdline` против ожидаемого шаблона — **без печати command line**;
6. аналогичную ownership-проверку supervisor-процесса (`auto.pid` + SHA `service.sh`).

Правила контракта: сигнал посылается только PID, прошедшему все проверки; расхождение любой проверки трактуется как `state=stopped` + `last_exit_reason=OWNERSHIP_MISMATCH`, а не как «чужой процесс надо убить». Проверка слушателя (`LISTEN`) также требует связать сокет с подтверждённым PID (через `/proc/net/tcp` + fd-инспекцию того же процесса), а не только констатировать занятый порт. Новые адаптеры копируют эти механизмы у PR #125, не изобретают свои.

### 2.3 Манифест провайдера (manifest.json)

Манифест — статический файл из **доверенного пакета адаптера** (поставляется и хешируется вместе с артефактом), а не из runtime-конфига. Имена полей финализированы:

| Поле | Обяз. | Тип/значения | Смысл |
|---|---|---|---|
| `schema_version` | да | `1` | версия контракта |
| `provider_id` | да | kebab-case (`wdtt`) | идентификатор, = имени каталога |
| `adapter_version` | да | semver | версия адаптера (не бинарника) |
| `server_wire` | да | точная строка варианта | wire-протокол **с точным вариантом**; разные wire не взаимозаменяемы |
| `server_class` | да | класс сервера | какой тип сервера совместим (`wdtt-exit-vps`, `openflux-exit-l4`, …) |
| `architecture` | да | массив `{arch, abi}` | целевые архитектуры артефакта (`aarch64`/…); admission сверяет с устройством |
| `capabilities` | да | карта feature → 4 уровня | см. ниже |
| `inbound_bind` | да | `127.0.0.1:<port>` | только loopback; порт резервируется после runtime-проверки коллизий |
| `resource_requirements` | да | см. ниже | требования RAM с честным basis |
| `artifact_provenance` | да | см. ниже | pin артефакта |
| `configuration_reference` | да | строка-ссылка | где описан формат owner-конфига (template/docs); самих секретов здесь нет |

**Четыре уровня capabilities** — принципиальное разделение (не один булев статус):

| Уровень | Вопрос | Кто подтверждает | Где живёт |
|---|---|---|---|
| `code` | функция реализована в исходниках провайдера | source audit | манифест |
| `build` | функция присутствует/включена в данном артефакте (ELF/сборка) | admission при install | манифест |
| `field` | подтверждено физическим E2E на устройстве (SHA+дата) | физический тест, owner | манифест (после теста) |
| `live` | доступно прямо сейчас, в этот момент | только runtime | **только status.json**, никогда не манифест |

Значение уровня: `YES` / `NO` / `UNKNOWN`. Правило монотонности: `field=YES` требует `build=YES` требует `code=YES`; нарушение = манифест невалиден. Пример для текущего WDTT (честно): `socks_tcp {code:YES, build:YES, field:NO}`, `socks_udp {code:UNKNOWN, build:UNKNOWN, field:NO}` — UDP нет в default-ветке, статус кандидата PR #34 не проверялся этим исследованием.

`resource_requirements`: `{ "mem_min_mb": 512, "mem_scope": "combined_with_kas" | "standalone", "mem_basis": "MEASURED" | "DOCUMENTED" | "UNKNOWN", "notes": "…" }`. `mem_basis=UNKNOWN` допустим и обязан сопровождаться `mem_min_mb=null` (admission тогда требует явного owner-GO). Порог KAS+WDTT ≥512 MB (#137) не наследуется другими провайдерами автоматически.

`artifact_provenance`: `{ "sha256": "…", "source_commit": "…", "build_ref": "CI-run/tag/URL", "artifact_path": "versions/<v>/worker" }` — обязательны `sha256` и `source_commit`.

**Что не берётся из недоверенного источника.** `server_wire`, `server_class`, `architecture`, `capabilities`, `inbound_bind`, `resource_requirements`, `artifact_provenance` приходят только из манифеста доверенного пакета. Профиль/конфиг от сервера, share-link или ручной правки может заполнять **только** runtime-параметры, описанные в `configuration_reference` (адрес/ключи/вариант соединения), и не может ни добавлять capability, ни менять bind, ни «переквалифицировать» wire-протокол.

**Пример корректного манифеста (иллюстративный, не рабочий конфиг):**

```json
{
  "schema_version": 1,
  "provider_id": "wdtt",
  "adapter_version": "0.1.0",
  "server_wire": "wdtt/qwdtt-vkturn-dtls-wg (точный вариант из owner-профиля)",
  "server_class": "wdtt-exit-vps",
  "architecture": [{ "arch": "aarch64", "abi": "musl-static" }],
  "capabilities": {
    "socks_tcp": { "code": "YES", "build": "YES", "field": "NO" },
    "socks_udp": { "code": "UNKNOWN", "build": "UNKNOWN", "field": "NO" },
    "tun":       { "code": "NO",  "build": "NO",  "field": "NO" }
  },
  "inbound_bind": "127.0.0.1:1081",
  "resource_requirements": { "mem_min_mb": 512, "mem_scope": "combined_with_kas",
                             "mem_basis": "UNKNOWN",
                             "notes": "требует замера A/B (MT-004) до любых заявлений" },
  "artifact_provenance": { "sha256": "<pinned-digest>", "source_commit": "<pinned-commit>",
                           "build_ref": "<ci-run-or-tag>", "artifact_path": "versions/<v>/worker" },
  "configuration_reference": "docs/wdtt-owner-config-v0.md (template: client.json.template)"
}
```

**Примеры некорректных манифестов (fixture INVALID):**
- `socks_udp: {code:UNKNOWN, build:YES, …}` — нарушена монотонность (build=YES без code=YES).
- `inbound_bind: "0.0.0.0:1081"` — не loopback → отказ install/старта.
- `server_wire: "auto"` / отсутствует — wire должен быть точным вариантом.
- `resource_requirements.mem_basis: "MEASURED"` без ссылки на замер, либо `mem_basis: "DOCUMENTED"` при `mem_min_mb: 256` для WDTT — противоречит #137.
- `artifact_provenance.sha256` не совпадает с фактическим файлом → install отказ.
- манифест, лежащий рядом с артефактом, но не покрытый проверкой целостности пакета → недоверенный, игнорируется.

### 2.4 Статусы: формат, правила, redaction

Единый вердикт-набор для всех осей: `PASS / FAIL / UNKNOWN / NOT_TESTED / UNSUPPORTED / STALE`. Оси статуса: `process` (ownership-проверенный), `listener` (с владельцем), `transport_state{turn, dtls, wg}` (только если провайдер экспонирует), `tcp_e2e`, `udp_e2e`, `resources` (RSS/VmHWM/FD). Разделение уровней как в манифесте: `UNSUPPORTED` приходит из capabilities (`build:NO`), `NOT_TESTED` — поле не проверяли, `UNKNOWN` — проверяли/стартовали, результата нет, `STALE` — `observed_at` старше `freshness_ttl_sec`.

**Пример redacted-статуса (иллюстративный):**

```json
{
  "provider_id": "wdtt",
  "state": "running",
  "pid": 12345,
  "pid_verified": true,
  "started_at": "2026-10-21T12:00:00Z",
  "listener": "127.0.0.1:1081",
  "listener_state": "LISTEN",
  "listener_owner_verified": true,
  "transport_state": { "turn": "UNKNOWN", "dtls": "UNKNOWN", "wg": "UNKNOWN" },
  "tcp_e2e": "UNKNOWN",
  "udp_e2e": "UNSUPPORTED",
  "egress": "SOCKS_LISTEN_ONLY",
  "observed_at": "2026-10-21T12:00:05Z",
  "freshness_ttl_sec": 120,
  "rss_kb": 26900, "vsz_kb": 0, "fd_count": 34,
  "last_exit_reason": null
}
```

**Правила обновления status.json:** пишет **только** adapter (status/doctor), атомарной подменой (tmp+rename); `observed_at` обязателен; manager и KAS Doctor только читают; в файле и в логах запрещены credentials, TURN-токены, cookies, HWID, приватные URI и cmdline процесса (argv-сверка в service.sh уже не печатает командную строку — этот же запрет наследуется). Известный дефект WDTT (STDIN-строки с `TURN_CREDS|` попадают в лог процесса, см. feasibility §A.1) — красная линия: **логи wt-client не пересылать в status/telemetry** до исправления отдельной задачей.

**Контракт doctor (данные и безопасность):**
- `status` и локальная часть `doctor` — без внешних соединений; E2E-проба — только явный owner opt-in с разрешённым endpoint, таймаутами и однократностью (fresh nonce не требует протокол — но повтор пробы не должен быть автоматическим).
- TCP и UDP проверяются **независимо**; UDP не тестируется, если capabilities `socks_udp.build != YES`.
- Недоступный транспорт не заменяется прямым WAN — проба идёт только через loopback SOCKS; результата «через DIRECT получилось, значит OK» не существует.
- `UNKNOWN / STALE / UNSUPPORTED` никогда не выдаются за `PASS`; `SOCKS_LISTEN_ONLY ≠ интернет работает`.
- E2E-пакеты расходуют трафик и могут расходовать TURN-квоту и вызывать события авторизации аккаунта — врач предупреждает об этом до пробы, обещать «бесплатность» до замера нельзя.

## 3. Этапы разработки (порядок и стоп-точки)

| Этап | Содержимое | Выход / стоп-точка |
|---|---|---|
| **MT-001 (сейчас, только docs)** | JSON Schema манифеста + статуса; VALID/INVALID fixtures; redacted sample status; сверка с PR #125 и WDTT ADR #18. **Без runtime-кода, без `kill -0`-логики, без нового supervisor** | схема и fixtures в `docs/research/`; ревью владельца |
| **MT-002 (после GO, только синтетика)** | BusyBox ash/dash проверка schemas/fixtures offline: все INVALID-манифесты отклоняются, монотонность capabilities, non-loopback bind, wrong SHA, wrong arch, zombie/foreign PID fixtures, insufficient MemAvailable, partial install, rollback; максимально переиспользовать существующие тесты PR #125 (`tests/wdtt-*.py`), не дублировать | зелёный offline-CI, wt-client не запускается |
| **MT-003 (после физической приёмки WDTT PR #34)** | минимальный wdtt-провайдер = **расширение PR #125**: добавить manifest.json + status/doctor в контракт v0; никаких новых клиентов/стеков; layout и ownership — без изменений | owner-lab NC-4210, ручной старт |
| **MT-004 (после MT-003)** | A/B: (A) wt-client standalone baseline vs (B) под контрактом, одинаковый профиль/нагрузка/длительность; RSS/VmHWM/CPU/MemAvailable/FD; **сравнимые нагрузки — обязательное условие** (урок WDTT #25) | воспроизводимый baseline → числа вписываются в feasibility как «измерено» |
| **MT-005 (решение о репозитории)** | см. §7 | только по факту ≥2 работающих провайдеров |
| следующие кандидаты | OpenFlux (по #142) или CSQTT (по #139) — **один за раз**, по критериям #164 M3 | каждый — свой `server_wire`, свой порт, свои замеры |

Стоп-правила: никакой реализации раньше приёмки WDTT PR #34; никакого второго watchdog; никаких изменений RAM-порогов KAS; owner-lab 30-мин guard (exit 75) — свойство конкретной сборки, не снимается и не «переносится» молча; >30 мин soak — только отдельная разрешённая тестовая сборка.

## 4. Перечень тестов (минимальный набор)

1. **Схема/фикстуры (offline):** каждый INVALID-манифест из §2.3 отклоняется; монотонность `field→build→code`; `inbound_bind≠127.0.0.1` → отказ старта; отсутствие `server_wire` → отказ.
2. **Артефакт:** wrong SHA256 / wrong ELF-arch / усечённый файл → отказ (гейты PR #125 — прогнать, не переписать).
3. **Ownership (на fixture-процессах):** PID переиспользован (starttime не совпал) → `stopped`, сигнала нет; zombie → `stopped`; чужой exe при верном PID → `OWNERSHIP_MISMATCH`, сигнала нет; argv не совпал → отказ; cmdline никогда не попадает в вывод.
4. **Lifecycle на POSIX sh/BusyBox:** install→install (no-op); start без сети → `12`; stop при отсутствии подтверждённого PID → чисто; partial install → `uninstall` дочищает; rollback возвращает прежнюю версию и выключает автозапуск.
5. **Admission:** MemAvailable ниже порога → `11`; для обычного KAS 256 MB порог **не** повышается (проверка отсутствия регрессии); `mem_basis=UNKNOWN` блокирует старт без owner-GO.
6. **Статус/redaction:** после stop `state=stopped`, порт свободен и владелец не числится; `observed_at` старше TTL → оси E2E `STALE`; grep-тест фикстурных секретов (токены/cookies/HWID/URI/cmdline) в status.json и логах — ноль совпадений.
7. **Doctor (синтетика):** TCP E2E через поднятый dummy-SOCKS fixture → `PASS`; недоступный порт → `FAIL`, не «DIRECT»; `socks_udp.build != YES` → UDP-проба не выполняется (`UNSUPPORTED`), а не «попытка и UNKNOWN».
8. **Физические (после GO, owner-lab NC-4210):** ручной start → HTTPS 200 через SOCKS → doctor TCP `PASS`; stop → fail-closed (тестовая политика падает, прямого WAN нет, DNS/IPv6 не текут); перезагрузка роутера → транспорт не поднимается сам.

## 5. Критерии готовности MVP (DoD)

- Контракт v0 зафиксирован схемой + fixtures, offline-проверки зелёные на BusyBox-матрице.
- `kas-transport wdtt status|doctor` отдают redacted JSON по схеме на реальном NC-4210 (owner-lab).
- Ноль изменений в: сетевом коде WDTT, KAS Core-путях, существующих RAM-порогах, Proxy/DNS/firewall/IPv6.
- Ownership-проверки в новых операциях — вызов существующих механизмов PR #125, ослаблений нет (fixture-тесты §4.3).
- A/B (MT-004) дал воспроизводимый RSS/CPU baseline на сопоставимой нагрузке; результаты вписаны в feasibility как «измерено».
- Владелец подтвердил: KAS без transport-каталога работает как раньше (smoke: install → uninstall → обычный setup не изменил поведение).

## 6. Совместимость с KAS PR #125 (проверено, противоречий по существу нет)

Сверка спецификации с `experimental/wdtt/` ветки PR #125 (service.sh 529 строк, install.sh, init.d, preflight, sandbox-lifecycle, tests/wdtt-*.py):

1. **Ownership:** `owned_running()` уже делает starttime/zombie/exe/argv-сверки (§2.2) — спецификация **переиспользует** их и явно запрещает упрощения. Противоречия нет.
2. **Layout:** первая редакция MVP упоминала `state.json`/`config.json` вне контекста — уточнено: авторитетный layout PR #125 (`versions/<v>/worker`, `STATE/pid`, `init.d`, `install.sh`, `config.json`) сохраняется; `manifest.json`/`status.json` — **аддитивные** файлы. Минимальное решение против расхождения — принято в этой редакции (переименование и отображение полей на существующий layout), переписывать адаптер не требуется.
3. **argv-контракт:** service.sh сверяет точный шаблон `worker -config-file <path>` и не печатает cmdline — doctor/status не должны требовать новых argv-паттернов у существующего воркера (иначе это изменение lifecycle WDTT, запрещённое скоупом).
4. **Порты/admission/rollback:** 1081, MemAvailable-гейты, отключение автозапуска при rollback — совпадают с PR #125 без правок.
5. **Открытый пункт (не противоречие, фиксация):** `status.json` — новый файл; место его записи (каталог STATE или отдельный run-dir) и права 0600 фиксируются в MT-001 при написании схемы, чтобы не конфликтовать с transactional-логикой PR #125.

## 7. Отдельный репозиторий MultiTransport Core?

**Рекомендация: не сейчас.** Обоснование:
- Сегодня существует **ноль** реализаций контракта v0 — репозиторий был бы пустым каркасом, который #164 прямо запрещает создавать раньше пользы («не создавать пустой новый репозиторий», ADR MT-001 MT-005).
- Первая реализация живёт там, где уже прошла CI и приёмку: адаптер — в KAS (PR #125 ветка), документы — в `docs/research/`. Двигать код между ними позже — дешёвая операция (один каталог `transport.d/` + схемы).
- Критерий создания репозитория (наследник MT-005): **≥2 работающих реализации** провайдера (например, wdtt + openflux или wdtt + csqtt), доказанное переиспользование схем/fixtures и появление общего кода, которому тесно в двух репо. Тогда выносить: схемы, `kas-transport` обёртку, fixtures и provider-SDK — адаптеры остаются в продуктах-владельцах (WDTT в wdtt-suite, OpenFlux-обёртка отдельно), чтобы не смешивать лицензии GPL/MIT и релизные циклы.
