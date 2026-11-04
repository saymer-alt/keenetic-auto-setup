# Readable Doctor overview (experimental)

After an explicit Doctor run, Diagnostics displays a RU/EN overview derived from
that same redacted report. Language changes redraw the overview without another
probe. The original report and its copy button are unchanged; neither report nor
parsed facts are persisted in browser storage.

The bounded parser currently supports Doctor 1.2.18, 1.2.19, 1.2.20, 1.2.21 and 1.2.22. It requires the
anchored complete footer, matching API summary counts and exit status, and one
recognized version line. Truncation, conflicting verdicts or unknown versions show
an unavailable notice; missing or duplicated facts show “Could not determine”.
Parsing is section-scoped. Later Doctor changes need a fixture and parser review.

Cards cover model/KeeneticOS, the deepest /opt mount's internal/external/RAM class,
filesystem/source, free/total /opt and /tmp space, available RAM and swap, process
observations, watchdog scheduling, heartbeat count, restart/rate-limit counts and
the available history interval. These are observations from the report, not fresh
live readings. Heartbeats are not uptime or proof of a stable ISP; timestamps are
shown as recorded by the source, without assigning an invented timezone.

WARN/FAIL findings remain visible with localized severity/category and expandable
original evidence, rendered only through textContent. Unfamiliar finding text is
not discarded or guessed at. This first stage does not translate every technical
message or diagnose why a specific website is unavailable. See issue #270 for the
separate development of new diagnostic tools.

Later #274 work: explicit panel installation path/version/storage in Doctor and a
more detailed supported finding vocabulary. #273 tracks the independent panel
self-update. This change adds no rollback history or automatic updates.

## Beta.6: отдельные системные показатели по кнопке

Блок «Системные показатели» в «Диагностике» читает **канонический**
`kas-sys-metrics.sh` v0.1.0 через встроенную копию исходного скрипта.
Запуск только вручную, по отдельной кнопке; он **не является** новой версией
`mihomo-doctor.sh`, не выполняется при каждом открытии страницы и не запускает
сетевые пробы. JSON `router-metrics/v1` с ограниченным размером ответа передаёт
температуру CPU/SoC только при подтверждённом названии датчика, load average
1/5/15 (не CPU%), uptime Linux, RAM и swap. Не найденный или недостоверный датчик
отображается как «Не удалось определить», без выдуманного 0°C и порогов перегрева.

JSON создаётся во временной private-директории и удаляется после чтения;
данные не пишутся в browser storage, не содержат подписок, ключей, IP-адресов
и серийных номеров. Запрос POST защищён same-origin и отдельным подтверждающим
заголовком; никакого cron и постоянного фонового опроса нет.

Старый парсер `doctor-report.js` по-прежнему работает только с форматами
Doctor 1.2.18/1.2.19. Системные метрики — **отдельная карточка** и не выдаются
за часть полного текстового отчёта. Для новой версии основного Doctor парсер
требует отдельного обновления по fixture и тестам.

## beta.6: подтверждённый исходник watchdog в карточке «Версии»

У `mihomo-watchdog.sh` нет самостоятельной проверяемой semver-версии.
Раньше скриптовые установки без доверенного receipt показывали только короткий SHA256.
Теперь Web может дополнительно **подтвердить совпадение содержимого** установленного
`/opt/bin/mihomo_watchdog.sh` с каноническим `mihomo-watchdog.sh` внутри
проверенной сборки Web. Сравниваются полные SHA256; если хеши равны и есть
корректный 40-символьный source SHA сборки, отображается этот **снимок исходников**
и короткий SHA256 watchdog. Это **не отдельная версия Watchdog**, не гарантирует
отсутствие локального изменения/подмены при отсутствии root-owned proof и не
доказывает, что watchdog выполняется cron.

Для старого, неизвестного, локально изменённого или неузнаваемого watchdog,
а также для development-сборок без исходного SHA, остаётся честный SHA-only
fallback. Даже при наличии валидного bundle receipt его `bundle_version`
нельзя выдавать за standalone semver watchdog. Полный Doctor-отчёт по задаче
#337 требует отдельной интеграции общей модели идентичности; этот Web PR
не заявляет, что #337 реализована.
