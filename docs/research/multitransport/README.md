# MultiTransport — Provider Contract v0 (MT-001)

**Статус:** DESIGN / CONTRACT ONLY, 2026-10-21. Это контракты и синтетические данные, **не** transport manager: здесь нет runtime-кода, supervisor'а, CI и ничего исполняемого на устройствах. Реализация — [MT-001 в MULTITRANSPORT-MVP.md](../../research/MULTITRANSPORT-MVP.md) (ред. PR #171); архитектура — KAS Core → on-demand manager → независимые процессы провайдеров → loopback SOCKS5.

## Состав

| Файл | Назначение |
|---|---|
| `schemas/provider-v0.schema.json` | immutable-манифест доверенного пакета провайдера (`code`/`build` уровни capabilities, порог допуска + его источник + наличие измерений, provenance, loopback-bind) |
| `schemas/status-v0.schema.json` | redacted локальный статус: ownership-подтверждённый PID, слушатель с владельцем, независимые TCP/UDP E2E, `observed_at`+TTL, ресурсы, причина завершения |
| `schemas/acceptance-v0.schema.json` | отдельные mutable полевые доказательства: запись привязана к точному SHA артефакта, синтетическому device_id, профилю, длительности; не наследуется между версиями/устройствами |
| `fixtures/valid/` | 8 синтетически корректных документов (WDTT, будущий OpenFlux, статусы, acceptance) |
| `fixtures/invalid/` | 7 документов, которые схема обязана отклонять (wrong schema_version, bad SHA256, `0.0.0.0` bind, missing `server_wire`, bad capability, противоречие code/build, running без подтверждённого PID) |

Все SHA, идентификаторы, адреса и профили в fixtures — **синтетические**; совпадения с реальными серверами/аккаунтами исключены по построению.

## Что гарантирует JSON Schema

- типы/обязательные поля/`additionalProperties: false` у всех объектов;
- `inbound_bind` — строго `127.0.0.1:port` (консервативное правило v0; прочие адреса 127/8 — только по отдельному обоснованию): `0.0.0.0`, LAN-адреса, `localhost`, IPv6, прочие `127.x`, порт 0/99999 отклоняются (проверено);
- `artifact_provenance.sha256` — ровно 64 hex-символа; `source_commit` — 7–64 hex; явное отклонение «полусгенерированных» значений;
- enum-уровни: `code/build ∈ {PRESENT, ABSENT, UNKNOWN}`; вердикты `PASS/FAIL/UNKNOWN/NOT_TESTED/UNSUPPORTED/STALE` (`UNSUPPORTED` = доказанное отсутствие в сборке; `UNKNOWN`/`NOT_TESTED` = отсутствие данных/пробы — не путать);
- инвариант монотонности `build=PRESENT ⇒ code=PRESENT` (для известных полей capability);
- `admission_min_mb` (integer) ⇒ `admission_source` обязателен; `measured=true` ⇒ `measurement_ref` обязателен; `admission_min_mb=null` = «порог не определён, старт только по owner GO» (контракт ≥512 MB KAS+WDTT из #137 сохранён как документированная политика, не как доказанная достаточность);
- `state=running` ⇒ `pid` обязателен и `pid_verified=true` (схема не даёт заявить running без ownership-подтверждения).

## Что схема НЕ гарантирует (проверки MT-002+, не выдавать за сделанное)

1. Реальное совпадение бинарника с `sha256`/`source_commit` (это runtime admission, гейты уже есть в KAS PR #125).
2. Владение PID/слушателем (starttime/zombie/exe/argv-сверки `owned_running()` PR #125 — схема лишь требует поле `pid_verified`).
3. Семантику нестандартных имён capabilities (схема проверяет формат имени и уровни известных полей; словарь известных features — MT-002).
4. Кросс-файловые проверки: acceptance-записи соответствуют SHA манифеста; UDP-проба не запускается при `build != PRESENT`; перенос записей на новый артефакт запрещён.
5. Вычисление `STALE` (сравнение `observed_at`+`freshness_ttl_sec` с текущим временем) и все фактические E2E-пробы.
6. Секрет-сканирование значений свободных полей (`notes`, `evidence_ref`) — фикстуры чисты по построению, runtime-проверка — MT-002.
7. Проверку коллизий портов и MemAvailable-admission.

## Совместимость с KAS PR #125

Контракт — **только данные**: supervisor, ownership-проверки (`owned_running()`), установщик, RAM-admission и lifecycle `experimental/wdtt/` не копируются и не изменяются; манифест/acceptance/status — аддитивные файлы рядом с существующим layout. Новых постоянно живущих процессов контракт не требует. Известная проблема логирования STDIN-секретов в WDTT уже зарегистрирована отдельно (wdtt-suite #40) и здесь не дублируется и не исправляется.

## Локальная проверка (offline, без CI)

`jsonschema` 4.26 (Draft 2020-12): все три схемы валидны против мета-схемы; 8/8 valid-фикстур проходят; 7/7 invalid-фикстур отклонены; серия bind-значений (`localhost`, `127.0.0.1` без порта, порт 0/99999, `0.0.0.0`, LAN, IPv6) — все отклонены, `127.0.0.1:1081` принят. Валидационный скрипт в репозиторий не включён сознательно (лёгкая локальная проверка, не новый CI-pipeline).
