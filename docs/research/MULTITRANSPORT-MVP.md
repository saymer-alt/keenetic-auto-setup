# MultiTransport MVP — план первого прототипа

**Статус:** PLAN / DESIGN ONLY, 2026-10-21. Этот документ ничего не создаёт на роутерах/VPS и не разрешает merge/release; реализация любого этапа — только по отдельному owner GO.
**Основание:** [MULTITRANSPORT-FEASIBILITY.md](./MULTITRANSPORT-FEASIBILITY.md), [ADR MT-001](https://github.com/saymer-alt/keenetic-auto-setup/issues/139#issuecomment-6324031186), [KAS #139](https://github.com/saymer-alt/keenetic-auto-setup/issues/139), [KAS #164](https://github.com/saymer-alt/keenetic-auto-setup/issues/164) (этап M2), [KAS PR #125](https://github.com/saymer-alt/keenetic-auto-setup/pull/125).

## Главный вопрос MVP

**Как минимальными усилиями и минимальным RAM превратить существующий WDTT в первый модуль будущей транспортной системы, не ломая работающий проект?**

Ответ: не писать новый транспорт и не трогать сетевой код WDTT вообще. Первый «модуль» = существующий бинарник `wt-client` + уже прошедший CI адаптер из PR #125, надетые на формальный контракт **provider v0**: JSON-манифест + 8 CLI-операций + redacted статус. Всё, что добавляется нового, — только схема, fixtures и тонкая shell-обёртка `doctor/status`, без второго supervisor и без изменения lifecycle WDTT.

## 1. Схема первого прототипа

```text
Keenetic (Entware)                                   VPS (владельца)
────────────────────────────────────────────         ─────────────────
KAS Core (setup.sh, Mihomo, Doctor)                  wdtt-suite/server.go
   │  работает как раньше, транспорт не обязан       (DTLS exit + WG wdtt0,
   │  существовать; пунктов меню не добавляет          10.66.66.1/16)
   │
   ├─ [on-demand] kas-transport <id> <op>            ← НЕТ резидентного демона:
   │    ├── читает manifest.json + state.json          живёт только пока
   │    ├── (расширение адаптера PR #125)              выполняется команда
   │    └── отказ = exit-code + status, не «ремонт»
   │
   └─ transport.d/
        └── wdtt/                                    VK TURN cloud
             ├── manifest.json      (возможности)      │
             ├── wt-client ELF      (SHA256-pinned)    │ TURN UDP + DTLS
             ├── owner-config/ 0700 (секреты)          ▼
             └── wdtt.sh <op>  ── start/stop/status ──> wt-client процесс
                    │   (PID/supervisor-механика PR #125, 30-мин лимит сохранён)
                    ▼
             127.0.0.1:1081 SOCKS5 TCP   ──> Keenetic Proxy Client (native)
                                             (привязка/выбор — вручную владельцем)
```

Инварианты прототипа:
- **Один активный транспорт**, запуск только вручную (автозапуск — отдельный opt-in режим уже существующего адаптера).
- **Ноль новых постоянно живущих процессов**: manager — shell, выполняется по вызову.
- **Ноль изменений** в сетевом коде WDTT, в KAS Core, в Proxy0/Proxy1/DNS/firewall/Mihomo.
- Провайдер не создаёт ничего кроме: своего каталога, своего процесса, одного loopback TCP-слушателя, своих файлов состояния.

## 2. Provider API v0

### 2.1 Операции

`kas-transport <provider-id> <op>` (обёртка вызывает `transport.d/<id>/wdtt.sh <op>`; имена и структура — развитие словаря #139, механика — PR #125):

| Оп | Семантика | Идемпотентность | Примечание |
|---|---|---|---|
| `install` | проверить ABI/arch/RAM/MemAvailable, положить артефакт+манифест, записать state | да, повторный = no-op | gates из PR #125: SHA256, ELF-архитектура, размер |
| `start` | manual-start процесса с owner-конфигом; проверка PID-идентичности | повторный start при живом PID = no-op | до старта: admission MemAvailable (совместный KAS+WDTT ≥512 MB, #137) |
| `stop` | graceful (SIGTERM → таймаут → SIGKILL только своего PID) | да | fail-closed: SOCKS-порт освобождается, ничего не «перекидывается» на DIRECT |
| `status` | redacted JSON из state + `kill -0` + проверка слушателя | да, read-only | без активных сетевых проб |
| `doctor` | активные read-only пробы: TCP E2E через SOCKS; UDP E2E — только если манифест `socks_udp=SUPPORTED`; ресурсный срез RSS/VmHWM/FD | manual | единственное место, где тратится трафик/квота; результат с `observed_at` |
| `update` | staged: новый артефакт → проверка → атомарная подмена → манифест | при ошибке = откат на предыдущий каталог | требует свежего owner-GO на новый SHA |
| `rollback` | возврат к предыдущему каталогу артефакта + state | да | автозапуск после rollback выключается (правило PR #125) |
| `uninstall` | удалить только свои файлы/процесс/PID | да | чужие процессы/порты не трогать |

Exit-codes контракта: `0` ok; `10` not installed; `11` admission fail (RAM/arch); `12` start failed; `13` doctor FAIL; `20` usage error. Все тексты — на stderr, машиночитаемое — в stdout (только для `status`/`doctor`).

### 2.2 Манифест возможностей (manifest.json)

Развитие схемы ADR MT-001 §2. Значения — **пример заполнения для WDTT**, статусы отражают реальное состояние на дату:

```json
{
  "schema_version": 1,
  "provider_id": "wdtt",
  "adapter_version": "0.1.0",
  "server_wire": "wdtt/qwdtt-vkturn-dtls-wg (точный вариант из owner-профиля)",
  "server_class": "wdtt-exit-vps",
  "arch": ["aarch64"],
  "mem_min_mb": 512,
  "mem_scope": "combined_with_kas",
  "features": {
    "socks_tcp": "SUPPORTED",
    "socks_udp": "UNVERIFIED",
    "tun": "UNSUPPORTED"
  },
  "inbound_bind": "127.0.0.1:1081",
  "config_schema_ref": "schemas/wdtt-owner-config-v0.json",
  "lifecycle": ["install","start","stop","status","doctor","update","rollback","uninstall"],
  "egress_policy": "FAIL_CLOSED",
  "artifact": { "sha256": "<pinned>", "source_commit": "<pinned>" },
  "secrets": { "source": "owner_private_config", "redact": true }
}
```

Правила чтения: `SUPPORTED` = реализация присутствует в артефакте; `UNVERIFIED` = заявлено, но не подтверждено E2E; `UNSUPPORTED` = отсутствует. `mem_scope` отличает «порог совместного KAS+WDTT ≥512 MB» (#137) от порога самого провайдера — другие транспорты **не наследуют** 512 автоматически. `server_wire` обязан указывать точный вариант (разные wire не взаимозаменяемы).

### 2.3 Формат статуса (state.json / doctor output, без секретов)

```json
{
  "provider_id": "wdtt",
  "state": "running",
  "pid": 12345,
  "started_at": "2026-10-21T12:00:00Z",
  "listener": "127.0.0.1:1081",
  "listener_state": "LISTEN",
  "transport_state": { "turn": "UNKNOWN", "dtls": "UNKNOWN", "wg": "UNKNOWN" },
  "tcp_e2e": "UNKNOWN",
  "udp_e2e": "NOT_TESTED",
  "egress": "SOCKS_LISTEN_ONLY",
  "observed_at": "2026-10-21T12:00:05Z",
  "freshness_ttl_sec": 120,
  "rss_kb": 26900, "vsz_kb": 0, "fd_count": 34,
  "last_exit_reason": null
}
```

Вердикт-набор единый для всех осей: `PASS / FAIL / UNKNOWN / NOT_TESTED / UNSUPPORTED / STALE`. Явное правило: до успешного `doctor` состояние — `SOCKS_LISTEN_ONLY`, и это **не** «интернет работает» (соответствует health-контракту #139: отсутствие SOCKS-слушателя ≠ Proxy1 up, и слушатель ≠ маршрут до VPS).

## 3. Этапы разработки (порядок и стоп-точки)

| Этап | Содержимое | Выход / стоп-точка |
|---|---|---|
| **MT-001 (сейчас, только docs)** | JSON Schema манифеста + статуса; фиктивные fixtures (valid/invalid); сверка с PR #125 и WDTT ADR #18 | схема и fixtures в `docs/research/` или `experimental/`; ревью владельца |
| **MT-002 (после GO, только синтетика)** | BusyBox ash/dash тесты контракта: UNVERIFIED UDP, STALE, wrong SHA, non-loopback bind, port collision, wrong arch, zombie PID, missing server_wire, leaked secret, insufficient MemAvailable, partial install, rollback — значительная часть покрывается существующими fixture-тестами PR #125, **расширять, не дублировать** | зелёный CI на fixtures, без запуска wt-client |
| **MT-003 (после физической приёмки WDTT PR #34)** | минимальный wdtt-провайдер = расширение PR #125: добавить manifest.json + `status`/`doctor` в контракт v0; никаких новых клиентов/стеков | owner-lab NC-4210, ручной старт, A/B (B) из MT-004 подготовлен |
| **MT-004 (после MT-003)** | A/B замер: (A) wt-client standalone baseline vs (B) под контрактом, одинаковый профиль/нагрузка; RSS/VmHWM/CPU/MemAvailable/FD | воспроизводимый baseline → **вот здесь** впервые появляются измеренные числа для RAM-раздела |
| **MT-005 (решение о репозитории)** | см. §7 | только по факту ≥2 работающих провайдеров |
| следующие кандидаты | OpenFlux (по #142) или CSQTT (по #139) — **один за раз**, по критериям #164 M3 | каждый — свой `server_wire`, свой порт, свои замеры |

Стоп-правила: никакой реализации раньше приёмки WDTT PR #34; никакой второй watchdog; никаких изменений RAM-порогов KAS; >30 мин soak — только отдельная разрешённая тестовая сборка.

## 4. Перечень тестов (минимальный набор)

1. **Схема/фикстуры (offline CI):** манифест невалиден по схеме → `install` отказ; `features.socks_udp=UNVERIFIED` → `doctor` не пробует UDP; `inbound_bind≠127.0.0.1` → отказ старта; отсутствие `server_wire` → отказ.
2. **Артефакт:** wrong SHA256 → отказ; wrong ELF-arch (x86 на ARM64) → отказ; усечённый файл → отказ (гейты уже в PR #125 — прогнать, не переписать).
3. **Lifecycle на POSIX sh/BusyBox:** install→install (no-op); start без сети → `12`; stop при мёртвом PID → чисто; zombie/чужой PID в state → не убивать; partial install → `uninstall` дочищает; rollback возвращает прежний каталог и выключает автозапуск.
4. **Admission:** MemAvailable ниже порога → `11` и старт не выполняется; для обычного KAS 256 MB порог **не** повышается (проверка отсутствия регрессии).
5. **Статус:** после stop `state=stopped`, порт свободен; `observed_at` старше TTL → все E2E-оси `STALE`; в выводе нет токенов/cookies/HWID/URI (grep-тест на fixture-секреты).
6. **Doctor (синтетика):** TCP E2E через поднятый dummy-SOCKS fixture → `PASS`; недоступный порт → `FAIL`, не «DIRECT».
7. **Физические (после GO, owner-lab NC-4210):** ручной start → HTTPS 200 через SOCKS → doctor TCP `PASS`; stop → fail-closed (тестовая политика падает, прямого WAN нет, DNS/IPv6 не текут); перезагрузка роутера → транспорт не поднимается сам (manual по умолчанию).

## 5. Критерии готовности MVP (DoD)

- Контракт v0 зафиксирован схемой + fixtures, CI зелёный на BusyBox-матрице.
- `kas-transport wdtt status|doctor` отдают redacted JSON по схеме на реальном NC-4210 (owner-lab).
- Ноль изменений в: сетевом коде WDTT, KAS Core-путях, существующих RAM-порогах, Proxy/DNS/firewall.
- A/B (MT-004) дал воспроизводимый RSS/CPU baseline; результаты вписаны в feasibility-док как «измерено».
- Отдельным письмом-комментарием в #139 владелец подтвердил: KAS без transport-каталога работает как раньше (smoke: install → uninstall → обычный setup не изменил поведение).

## 6. Требования к будущей KAS-интеграции (после MVP)

- Пункт меню KAS «Transport providers (experimental)» появляется **только** при наличии каталога `transport.d/` и ведёт только к операциям §2.1; обычный `setup.sh` путь не пересекает.
- Никакой автозагрузки новых провайдеров без явного owner-GO; manual — дефолт навсегда для experimental.
- Каждый новый провайдер = новый каталог + манифест + порт после runtime-коллизии (рабочие кандидаты из #139: 1082 CSQTT, 1083 OpenFlux; не константы).
- Config Studio/Builder-экспорт (типизированные `wdtt://`/`openflux://` профили) — строго после подтверждения wire-совместимости (link-generators #261), вне этого MVP.
- Doctor KAS (существующий) добавляет только read-only секцию «transport», читая `status`-JSON; не запускает пробы сам.

## 7. Отдельный репозиторий MultiTransport Core?

**Рекомендация: не сейчас.** Обоснование:
- Сегодня существует **ноль** реализаций контракта v0 — репозиторий был бы пустым каркасом, который #164 прямо запрещает создавать раньше пользы («не создавать пустой новый репозиторий», ADR MT-001 MT-005).
- Первая реализация живёт там, где уже прошла CI и приёмку: адаптер — в KAS (PR #125 ветка), документы — в `docs/research/`. Двигать код между ними позже — дешёвая операция (один каталог `transport.d/` + схемы).
- Критерий создания репозитория (наследник MT-005): **≥2 работающих реализации** провайдера (например, wdtt + openflux или wdtt + csqtt), доказанное переиспользование схем/fixtures и появление общего Go/shell-кода, которому тесно в двух репо. Тогда выносить: схемы, `kas-transport` обёртку, fixtures и provider-SDK — адаптеры остаются в продуктах-владельцах (WDTT в wdtt-suite, OpenFlux-обёртка отдельно), чтобы не смешивать лицензии GPL/MIT и релизные циклы.
