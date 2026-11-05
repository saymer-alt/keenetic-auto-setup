# 31 — Entware/BusyBox preflight и устойчивость /opt (issue #356)

`kas-entware-preflight.sh` — **read-only** диагностика состояния Entware-окружения (`/opt/bin/sh`, busybox, апплеты, wget, opkg). Скрипт запускается системным `#!/bin/sh` и **не зависит ни от одного бинарника /opt** в собственном управлении, поэтому работает даже когда `/opt/bin/sh` сломан.

## Механизм полевого отказа (Entware, 2026-11-03)

Официальный пакет BusyBox (Entware `package/utils/busybox/Makefile`):

1. `prerm` удаляет **каждую** ссылку в `/opt/bin` и `/opt/sbin`, чей resolved target — канонический busybox (`readlink -f`);
2. `postinst` восстанавливает ссылки по манифесту `/opt/share/busybox_applets.lst.dist`, но **только** для имён, которых нет: проверка `[ ! -e ]` **не покрывает dangling symlink** — такое имя будет «already exists, skipping» и не починится.

Обрыв между фазами (прерванный `opkg upgrade`, падение postinst) оставляет систему без `/opt/bin/sh`, `chmod` и других апплетов: `Bad interpreter "/opt/bin/sh"`, `chmod: not found`. Отдельный известный класс проблем: recovery-скрипт с безусловным `ln -sf` перезаписывает настоящий `/opt/bin/wget` (например, `wget-ssl`) ссылкой на BusyBox-апплет без HTTPS — затем `opkg update` на `https://` фидах падает с `wget returned 1` (Entware #887).

## Что печатает preflight

Каждая строка — `PASS:` / `WARN:` / `FAIL:` / `UNKNOWN:` (терминология Doctor):

- `busybox-binary` — есть ли `/opt/bin/busybox`, исполняется ли он (различаются missing / dangling / notexec / «не исполняется: битый ELF, неверный ABI или отсутствует dynamic loader — ручной rescue»);
- `opt-sh` — есть ли и исполняется ли `/opt/bin/sh`;
- `applet-<имя>` для chmod, ln, rm, cp, mv, ls, cat, grep, sed, awk, wget — отсутствующая ссылка на апплет, который **этот** busybox предоставляет, это FAIL (точное состояние «прерванного обновления»); dangling-ссылка — FAIL с объяснением, почему postinst её не чинит; настоящий файл чужого пакета — PASS (ownership не трогается);
- `wget-capability` — WARN, если `/opt/bin/wget` — ссылка на busybox-апплет (нет HTTPS), FAIL, если wget отсутствует;
- `opkg-view` — PASS, если `opkg status busybox` читаем и отвечает `install ok installed`; иначе UNKNOWN (база пакетов повреждена или посреди транзакции);
- `poorbox-fallback` — информационный PASS при наличии `/opt/usr/bin/poorbox`.

Коды возврата: `0` — нет FAIL/UNKNOWN; `1` — есть FAIL; `2` — нет FAIL, но есть UNKNOWN (нужно смотреть вручную).

Preflight **ничего не меняет**: не создаёт, не переименовывает, не делает `chmod`, не трогает пакеты и фиды. Это диагностика, а не ремонт: единственный санкционированный механизм восстановления ссылок — официальный `postinst` пакета; безусловный `ln -sf` по `--list` для всех апплетов **запрещён** (ломает ownership: `/opt/bin/wget` от `wget-ssl`, GNU grep/sed/awk от своих пакетов).

## Почему Doctor здесь не спасает

Если сломан сам `/opt/bin/sh`, shell-скрипты Entware (включая Doctor и KAS-инструменты) не запускаются. Preflight честно сообщает о состоянии, но тяжёлый случай решается вне KAS — через штатный CLI Keenetic и ручные шаги ниже.

## Решающее дерево восстановления (operator-only)

1. **Не перезагружать** без необходимости; сохранить журнал сессии.
2. Прямым вызовом проверить ядро: `/opt/bin/busybox --help`, затем `/opt/bin/busybox --list`.
   - не исполняется → битый ELF/ABI/loader: нужен проверенный бинарник той же архитектуры (aarch64-3.10 и т.п.) — **вручную**, с проверкой SHA256 и provenance; ничего не запускать вслепую.
3. Собрать факты (read-only): `/opt/bin/busybox ls -l /opt/bin/sh /opt/bin/chmod /opt/bin/wget /opt/bin/busybox`; `/opt/bin/busybox readlink -f /opt/bin/wget`; `opkg status busybox wget-ssl` (если opkg исполняется).
4. Различить: missing ссылка vs dangling ссылка vs настоящий файл чужого пакета. **Не перезаписывать** настоящие файлы.
5. Если подтверждено именно «прерванное обновление busybox» (ссылок нет, busybox цел, база opkg читаема) — минимальный путь: дождаться возможности корректно завершить `opkg upgrade busybox` (тот же фид/версия) или переустановить пакет busybox через opkg — официальный postinst восстановит ссылки по манифесту. Альтернатива вручную — **только** недостающие ссылки на апплеты, которых нет на диске, после сверки с `busybox_applets.lst.dist` и проверки, что путь не принадлежит другому пакету.
6. wget: если `/opt/bin/wget` — ссылка на busybox и в системе должен быть `wget-ssl` (`opkg status wget-ssl`) — переустановить `wget-ssl` через opkg после восстановления базовых утилит; не создавать ссылки wget вручную.
7. После восстановления: повторить preflight (ожидаемо `exit 0` без FAIL/UNKNOWN), затем `opkg status`, инвентаризация незавершённых транзакций (`/opt/lib/opkg/status` на предмет полу-настроенных пакетов). При неоднозначном ownership или повреждённой базе — ручная переустановка Entware с резервной копией пользовательских конфигураций (`/opt/etc/mihomo/config.yaml*`), не автоматический destructive reset.

## Запуск

```bash
# доставить скрипт на роутер и выполнить системным shell:
sh /tmp/kas-entware-preflight.sh
# код возврата: 0/1/2 — см. выше
```

Тесты контракта: `tests/busybox-preflight-regression.py` (матрица состояний под dash и BusyBox ash: healthy, прерванное обновление, dangling-ссылка, не-исполняемый busybox, exec-отказ, wget→апплет, отсутствие opkg; статическая проверка read-only).


### `opkg-view` в нативной Entware — узкий безопасный fallback (#356)

В нативной QEMU-лаборатории Router Emulator Draft #56 `opkg list-installed` подтверждал установленный BusyBox 1.37, однако восстановленный `kas-entware-preflight.sh` возвращал `UNKNOWN opkg-view` (`RESTORED_PREFLIGHT_RC=2`) из-за несовпадения формата/результата `opkg status busybox`. Это было обнаружено в исследовательском workflow [41968076595](https://github.com/saymer-alt/router-emulator/actions/runs/41968076595). **Прямой вывод `opkg status` в лог не экспортировался**, поэтому конкретный формат ответа пока неизвестен.

Обновлённый read-only-контракт: первичный `opkg status busybox` с точной строкой `Status: install ok installed` по-прежнему даёт `PASS`. **Только когда этот вызов успешно завершился, но не вернул вообще никаких данных**, разрешено прочесть `opkg list-installed` и, при успешном завершении и **ровно одной** строке `busybox - <непустая версия>`, вывести `PASS` с пометкой *limited package-view evidence*. Это подтверждает доступность инвентаризации, **не** целостность всей базы opkg и не разрешает никакие обновления. Если `status` вернул явно неполное/противоречивое состояние, остаётся `UNKNOWN` независимо от `list-installed`; когда строк нет, их несколько или команда завершается ошибкой, тоже `UNKNOWN`.

Реализация использует только POSIX shell builtins для анализа строк (без зависимости от пропавших `/opt/bin/grep`, `awk`, `sed`, `wc`), ничего не меняет и оставляет `FAIL` для повреждённых ELF/`sh`/апплетов. В `tests/busybox-preflight-regression.py` добавлены позитивный и отрицательные сценарии для dash/BusyBox ash. Вне указанного формата ответа или при сомнении диагностический статус обязан оставаться `UNKNOWN`: нельзя сделать зелёный QEMU ценой обхода повреждённой базы.
