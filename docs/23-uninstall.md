# KAS — транзакционное удаление: проверяемый кандидат

Инструкция относится к **кандидату**, а не к опубликованной stable-версии:
KAS `aef221f80904ff1d8dd639c6f85b308b063b749e` содержит #215 **и** защиту процессов
#227 поверх него. Самостоятельный #215 без #227 не считается принятым.
Виртуальная приёмка с Emulator `07e537976a2a6260239b758213a1e73f416f53bd`:
[19/19 PASS, E2E №5](https://github.com/saymer-alt/router-emulator/actions/runs/40202096816).
Аппаратная приёмка **NOT_TESTED**. Ни merge, ни публикация stable этим не разрешены.

Пошаговая инструкция владельцу запасного устройства:
[KN-1010-UNINSTALL-ACCEPTANCE.md](KN-1010-UNINSTALL-ACCEPTANCE.md).
На физическом роутере настоящее удаление требует отдельного **Owner GO**.

## Команды кандидата

Все скрипты должны находиться рядом и происходить из одного указанного SHA.
Не скачивать один uninstall.sh из меняющейся main поверх другой версии helpers.

| Команда | Действие |
|---|---|
| `sh uninstall.sh --check` | Read-only inventory; exit 0 не доказывает безопасность удаления |
| `sh uninstall.sh --plan` | Read-only план зависимостей; REVIEW требует проверки, чужие ресурсы сохраняются |
| `sh uninstall-snapshot.sh --check` | Read-only проверка возможности сделать снимок |
| `sh uninstall-snapshot.sh --create` | Создаёт приватные recovery-файлы и READY под `/opt/kas-uninstall-backups/`; это запись файлов |
| `sh uninstall-snapshot-verify.sh SNAP` | Независимо сверяет структуру, права и свежесть снимка с живым состоянием |
| `sh uninstall-transaction-gate.sh --check SNAP` | Read-only строгий ownership/dependency gate |
| `sh uninstall-transaction.sh --prepare SNAP` | Берёт lifecycle-lock, повторяет проверки, пишет prepare record, загружает точные IPK и MANIFEST; настройки/пакеты не удаляет |
| `sh uninstall.sh --remove SNAP` | **DESTRUCTIVE:** настоящая журналируемая транзакция; после успешного удаления повтор идемпотентен |
| `sh uninstall-transaction.sh --remove SNAP` после прерывания | Resume после аудита journal, recovery inputs и допустимого состояния; отдельного `--resume` нет |
| `--purge` | NOT_IMPLEMENTED / BLOCKED; не заменять ручным стиранием каталогов |

В этом SHA остались **исторические сообщения**: финальная строка --plan
`not implemented` и строка --prepare `Actual --remove/--purge still require…`.
Verifier также печатает историческое INFO `remove still blocked` после PASS.
Они не описывают реализованный native remove. Это несогласованность текста,
а не разрешение игнорировать другие BLOCKED. Runtime здесь не изменён.
Для GO нужны настоящий независимый gate, проверенные cache/backup и Owner GO.
Prepare может завершиться 0 с **REVIEW / cache incomplete**: отсутствие полного
cache означает BLOCKED для удаления.

## Владение и сохранность

Ledger `/opt/etc/keenetic-auto-setup/ownership.v1` — creation-only evidence,
не разрешение удалять любой одноимённый объект. Переиспользованные ресурсы
нельзя задним числом объявлять своими. Строгий профиль требует девять claims:
один owned Proxy0…Proxy9, policy bypass_wa, enabled DNS intercept, два пакета,
feed, hook и два watchdog-файла. Дополнительный claim, включая S00ubifs,
не входит в этот первый profile: BLOCKED, а не редактирование ledger.

Proxy определяется ledger + canonical signature + single-consumer scan +
сравнение со снимком. Единственный положительный ip global N выделяется NDMS:
350 или 32767 не доказывают владение. WAN alias ISP допускается только при
единственном проверенном rename ISP у GigabitEthernet1. Чужой Proxy на 7890
блокирует удаление Mihomo даже при down.

Транзакция снимает собственные cron/watchdog, точные Netfilter jump/chain,
hook, policy, Proxy, owned пакеты/feed/ledger. Не выполняет глобальный flush,
не удаляет Entware, curl/jq/nano/cron, swap/zRAM и чужие правила/маршруты.
DNS intercept оставляет включённым: ledger не исключает поздних потребителей.
Пользовательские YAML сохраняются; если OPKG удалил YAML, engine восстанавливает
его из снимка. Это не гарантия пережить произвольный отказ питания: независимый
backup всё равно обязателен.

## Службы: ручное предусловие

Native remove не посылает TERM/KILL и не вызывает пакетный init-stop.
Живой Mihomo/MagiTrickle либо недоступный/ограниченный proc — **BLOCKED/3**
до lock/marker/journal и изменений ресурсов. Под lifecycle-lock и перед
удалением пакетов отсутствие процессов проверяется повторно.

Имя, PID-файл, inode/executable, UID, argv и starttime проверяют идентичность,
но **не доказывают происхождение**. MagiTrickle PID-файл содержит только PID;
ручной запуск того же бинарника может записать такой же файл. Владелец должен
независимо доказать запуск именно испытательной установкой и отсутствие чужих
потребителей. Неизвестное происхождение — BLOCKED. Не применять killall/pkill,
массовый KILL, пакетный init-stop или удаление locks.

KN-вариант MagiTrickle 0.8.2-1 имеет собственный фоновый startup_loop до uptime
>300, шаг 5 секунд. Он возвращает остановленный демон независимо от watchdog
lock. Нужно дождаться **и** uptime >300, **и** естественного окончания init shell.
Проверить установленный init: обычный Entware-вариант с rc.func отличается.
Неизвестный/продолжающийся launcher — BLOCKED; argv не доказывает его владельца.

В контролируемом shell используются существующие per-run watchdog/lifecycle
locks. Перед адресным TERM обе подтверждённые владельцем идентичности сверяются
повторно, без эскалации KILL. Затем parent освобождает lifecycle, сохраняя
watchdog lock через verify/gate/cache и дочерний native remove. Child берёт свой
lifecycle. Готовая последовательность дана в аппаратном плане. VM provenance
не переносится на произвольный роутер.

## Прерывание и восстановление

Journal, prepare, snapshot, cache и recovery hashes не редактировать и не удалять.
Для resume вызывать engine `uninstall-transaction.sh --remove SNAP` с тем же
снимком: wrapper uninstall.sh имеет ранний already-removed no-op, exit 0 которого
не доказывает целостность journal после прерывания около удаления ledger.
Engine продолжает только допустимый префикс шагов после аудита состояния.
Отсутствующий ресурс не разрешает resume. Drift, повреждённые
recovery inputs или неизвестный процесс — остановка и приватная диагностика.

Snapshot содержит оба YAML, ledger, crontab, hook/watchdog/feed/init и NDMS/mangle/
OPKG evidence; cache — точные пакетные версии и SHA256 MANIFEST. Это не полный
образ Entware и не автоматический rollback KeeneticOS. Основной recovery первой
аппаратной приёмки — проверенный **холодный образ внешнего EXT4-носителя** и
startup-config вне opt, с подготовленным отдельным носителем. Он доступен при
сломанном OPKG. Подробности — этап B аппаратного плана.

YAML, startup-config, running-config, source URLs и логи могут содержать секреты.
Хранить приватно; публично — статусы, версии, хеши публичных исходников и безопасные
категории. 19/19 PASS остаётся виртуальным доказательством, не натурной приёмкой.
