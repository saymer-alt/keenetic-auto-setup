# Независимые офлайн-проверки KAS

Тесты проверяют логику установки, Watchdog, откат TUN и достоверность результатов без подключения к маршрутизатору. Все сценарии используют синтетические данные и изолированную временную директорию. Сеть подменяется локальными заглушками, установленное ПО на реальных устройствах не затрагивается.

## Запуск

На Linux/WSL2 с `sh`, `dash`, `busybox`, `python3` и `git`:

```sh
python3 tests/qa-independent/test_evidence_gate.py
sh tests/qa-independent/run-all.sh --out-dir /tmp/kas-independent-qa
```

Публичный GitHub Actions workflow `qa-independent.yml` запускает ту же проверку на pull request, касающихся соответствующего кода, а также вручную.

## Сценарии

- `bb-mt-opkg-gate.sh` — MagiTrickle: наличие реального процесса после установки
- `bb-watchdog-wan.sh` — при отказе WAN Watchdog не перезапускает Mihomo
- `fi-watchdog-restarts.sh` — ограничение повторных перезапусков и защита от сбоев
- `fi-tun-rollback.sh` — откат TUN при ошибке и сигнале завершения
- `mutation-kas.py` — отрицательные мутационные проверки
- `evidence_gate.py` и `test_evidence_gate.py` — проверка доказательств и принципа fail-closed
- `run-all.sh` — запуск набора и формирование JSON/Markdown отчётов

**Границы доказательств:** локальный `PASS` не заменяет тестирование на Keenetic, в QEMU или на реальном VPS. `NOT_TESTED` и `BLOCKED` не становятся `PASS`.
