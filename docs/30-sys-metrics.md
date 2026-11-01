# Метрики роутера: read-only сбор состояния (самостоятельный диагностический инструмент)

`kas-sys-metrics.sh` — необязательный одноразовый read-only сборщик штатных показателей ядра Linux/KeeneticOS (issue [#309](https://github.com/saymer-alt/keenetic-auto-setup/issues/309)): температура SoC/CPU из sysfs, load average, uptime и сводка памяти/swap из /proc. Решение владельца от 31.10.2026: **необязательная полезная функция на будущее** — сначала collector с честными UNKNOWN, затем отдельная необязательная интеграция с KAS Web; это не мониторинг и не блокер очередной бета-версии. Интеграция отложена до Web Beta 5 (решение от 01.11.2026).

## Что собирается

| Показатель | Источник | Правило |
| --- | --- | --- |
| Температура SoC/CPU | `/sys/class/thermal/thermal_zone*/{type,temp}`, затем `/sys/class/hwmon/hwmon*/{name,temp*_input}` | зона выбирается строго по `type`/`name`, содержащим cpu/soc (без учёта регистра); общий `*thermal*` не считается CPU-датчиком; пустое/не-число/отрицательное/вне диапазона −40…+150 °C → **UNKNOWN, без «подгонки»**; выбор и источник печатаются |
| Load average 1/5/15 | `/proc/loadavg` | это **load average, не процент CPU**; проценты не вычисляются |
| Uptime | `/proc/uptime` | время работы Linux с загрузки; это не uptime WAN/ISP/Mihomo/watchdog |
| RAM / swap | `/proc/meminfo` (MemTotal, MemAvailable, SwapTotal, SwapFree) | сводка; полный анализ RAM/storage остаётся в основном Doctor — вердикты здесь не дублируются |

## Чего сборщик не делает

- Ничего не меняет; один запуск = один проход; без демонов, cron, сети и пакетов (Fastfetch/flashfetch **не устанавливаются** и не требуются).
- **Порогов перегрева нет**: вендорские лимиты по моделям неизвестны, поэтому вердиктов «перегрев/OK» не существует — только наблюдение.
- Отсутствующий/неопределённый датчик → `UNKNOWN`/`N/A`, никогда не фиктивное значение и не FAIL.
- Секретов и серийников в выводе нет.

## Запуск

```sh
sh kas-sys-metrics.sh
sh kas-sys-metrics.sh --json /opt/tmp/metrics.json
```

Коды возврата: `0` — хотя бы одна метрика наблюдена; `1` — ничего не удалось наблюдать (всё UNKNOWN); `2` — ошибка использования. Для тестов предусмотрены корни-инъекции `KAS_SYSFS_ROOT`/`KAS_PROC_ROOT` (в нормальной работе не задаются).

## JSON-контракт `router-metrics/v1`

`--json FILE` пишет версию схемы, имя/версию инструмента, UTC-время, exit-код и блоки `temperature` (статус, °C, зона, type, source, note «no thresholds asserted»), `load` (статус, 1/5/15 мин, note «load average, not CPU percentage»), `uptime` (статус, секунды, note), `memory` и `swap`. Все статусы — `PASS / UNKNOWN / N/A / INFO`; формат готов для будущих карточек KAS Web.

## Тестирование и границы

- `tests/sys-metrics-regression.py` — офлайн-регрессия на fixture-деревьях sysfs/procfs (корни-инъекции): нормальная зона `soc_thermal`, вариант только через hwmon, несколько зон (первая CPU-зона выбирается, все печатаются), завышенное значение → UNKNOWN без «подгонки», отрицательное и текстовое значение → UNKNOWN, нечитаемый файл → UNKNOWN, отсутствие датчиков при рабочих /proc → 3 из 4, полное отсутствие всего → exit 1 «всё UNKNOWN», битый loadavg/uptime, отсутствие swap → N/A, валидность JSON и отсутствие «FAIL/WARN»-вердиктов в отчёте.
- Прогон выполнен на host sh и BusyBox ash 1.37: **MOCK PASS на обоих диалектах**.
- **QEMU (отдельный read-only прогон): PASS для запуска сборщика** в disposable KeeneticOS Ported 5.1.8 / Entware (DRIVER_OK, 254 с): `kas-sys-metrics.sh` завершился с exit 0, JSON `router-metrics/v1` валиден; прочитаны гостевые `/proc/loadavg`, `/proc/uptime`, `/proc/meminfo`. Зона `thermal_zone0` (type `cpu-thermal`) показала **45,3 °C в модели эмулятора** — это не доказательство температуры реального SoC; hwmon отсутствовал и не подменялся фиктивным датчиком. Fixture-проверки — отдельный **MOCK PASS**, а CI `native-kas / ported-lab` — отдельная проверка общего жизненного цикла KAS. **PHYSICAL: NOT TESTED** — KN-1010/KN-1012/NC-1812 и другие физические роутеры требуют отдельного GO.
