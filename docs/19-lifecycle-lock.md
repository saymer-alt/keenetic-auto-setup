# 19 — взаимное исключение операций Mihomo

Installer, Mihomo/watchdog updater, config import, MIPS/TUN migration и watchdog restart используют
один lock: `/tmp/mihomo-lifecycle.lock.d`. Doctor и `--check` migrator используют
его только для краткого резервирования времени ELF-проверки. Они не меняют сервис,
конфигурацию или маршруты; временная координация в `/tmp` не является настройкой роутера.

## Владелец

В `owner` записаны PID и starttime из поля 22 `/proc/PID/stat`. Имя скрипта в
cmdline не используется: запуск из файла и `curl | sh` имеют одинаковые гарантии.
Совпадение только PID недостаточно — после PID reuse starttime должен отличаться.
Поле comm может содержать пробелы и `)`, поэтому parser удаляет его целиком перед
выбором starttime. Неопределённая/повреждённая identity означает отказ от захвата.

Короткий каталог `.guard` сериализует **все** изменения metadata: acquire,
проверку stale owner, reclaim и release. Это закрывает гонку между двумя
stale-recoverer: один не может удалить новую generation lock другого. Рабочий
lifecycle lock держится до завершения восстановления сервиса и cleanup.

После смерти обычного владельца следующий запуск восстанавливает lock. Cleanup
проверяет свою identity; marker удаляется только при точном совпадении сохранённого
owner-record. Повторный EXIT cleanup updater не удаляет данные новой транзакции.

## Watchdog

Watchdog сохраняет отдельный lock всей cron-итерации. Общий lifecycle lock ему нужен
только непосредственно перед restart, после WAN/port/proxy checks и cooldown.
Захват неблокирующий: при занятости или неопределённости watchdog пишет SKIP,
не меняет restart timestamp и не перезапускает Mihomo в этой итерации.

Поэтому maintenance, начавшийся **после** ранней проверки marker, тоже защищён.
Полный WAN outage по-прежнему заканчивается без restart. Marker остаётся удобным
операторским признаком; он больше не заменяет взаимное исключение.

## Неопределённое состояние и обновление старых инструментов

Если процесс погиб ровно внутри короткой операции изменения metadata, может
остаться `/tmp/mihomo-lifecycle.lock.d.guard` (или `.guard` cron-lock watchdog).
Такой guard **не отбирается автоматически**: иначе проверка stale и удаление вновь
становятся гонкой. Операции отказываются от работы, watchdog пропускает restart.

Для ручного восстановления сначала остановите запуск всех maintenance-инструментов
и cron watchdog и убедитесь, что их процессов/ELF-проверок больше нет. Только после
этого удаляйте оставшийся guard/повреждённый lock и marker. При невозможности доказать
отсутствие владельцев используйте контролируемую перезагрузку: `/tmp` непостоянен.
Не удаляйте lock работающей операции ради повторного запуска.

Старые per-tool locks сохраняются как блокирующее evidence; новые инструменты их
не удаляют. Смешанные старые и новые скрипты не имеют общего протокола. Обновляйте
инструменты и canonical watchdog в спокойном состоянии, без параллельного запуска
старых копий. Прямой ручной запуск init/ELF и сторонние supervisor не подчиняются
этому lock: во время обслуживания их запуск должен быть исключён оператором.

Оставшиеся проблемы rollback, downloader, отсутствующего pidof и resource scanner
не исправляются этим изменением. Lock не является обещанием crash-durable filesystem
transaction или гарантией восстановления после аппаратного отключения питания.

## Проверки

`python3 tests/lifecycle-regression.py` исполняет production helper-блоки и функции
stop/restore/restart/cleanup в настоящих процессах под `sh` и `busybox ash`.
Проверяются file/stdin, dead owner, PID reuse, concurrent stale recovery, чужой
cleanup, TERM, SIGKILL в metadata section, interleaving updater×import/MIPS/TUN,
поздний watchdog restart, running/stopped state и повторный EXIT cleanup.
Полный watchdog запускается с отказавшими WAN transports; Doctor re-observes
процессы под lock. Init/ELF и пути подменены, реальные роутеры не используются.

Helper намеренно встроен одинаковым блоком в standalone scripts: `curl | sh`
не должен зависеть от дополнительной библиотеки. Regression сравнивает все копии,
чтобы одинаковый protocol не начал расходиться.
