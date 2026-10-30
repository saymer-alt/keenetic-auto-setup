# Передача Z AI: завершить проверку самообновления WEB KAS (#273)

Репозиторий: https://github.com/saymer-alt/keenetic-auto-setup
Ветка: `feat/kas-web-self-update`.
База: `fix/kas-web-operation-navigation-label`, PR #278, SHA `fe9db3a`.
Задача: #273. Работать поверх текущего diff, не начинать реализацию заново.

## Разрешения владельца

29.10.2026 владелец утвердил схему и реализацию, затем явно разрешил commit/push
и draft PR для CI и передачу Z AI. Продолжить разработку, исправления, коммиты
и проверки в этой экспериментальной ветке. Это не разрешение merge, release,
channel-index publication, main/stable/latest или операций на реальных роутерах.
На KN-1010 остаётся test15; переустановка сейчас не нужна. Снятие фильтров уже
подтверждено. Названия сети нейтральные; доступ через VPN/другие подсети допустим,
ограничение по подсети br0 выключено по умолчанию.

## Прочитать

- AGENTS.md и docs/CONSTITUTION.md.
- docs/superpowers/specs/2026-10-29-panel-self-update-design.md — согласованная схема.
- docs/superpowers/plans/2026-10-29-panel-self-update.md — план/проверенный checkpoint.
- web/control-center/PANEL_UPDATE.md — фактическое поведение и ограничения.

## Уже написано

- panel_update_package.go: строгий channel/index и streaming gzip-tar IPK preflight,
  SHA256/size/control.Version/ABI/Source/Channel/ELF, запрещены links/traversal,
  лишние payload paths и dependency/replacement/recommendation metadata.
- packaging/update-manifest.py читает настоящую внутреннюю версию control,
  а не имя файла. GitHub может заменить `~` в asset name на `.`.
- Версии сравнивает реальный Entware opkg `compare-versions A >> B`: оператор
  `>` допускает равенство! Сравнение в приватном offline-root без lock рабочего opkg.
- panel_update.go / panel_update_worker.go: persistent private state/gate,
  detached session worker со stdio напрямую /dev/null, bounded download,
  conservative space/inode check, штатный opkg install, init start, runtime receipt,
  явный CLI recovery. No force, rollback или истории IPK.
- Каждый mutating handler повторно проверяет gate под app mutex. Сам worker не
  включён в importer drain: иначе preinst и daemon shutdown взаимно ждут друг друга.
- web/panel-update.js: RU/EN, explicit check/confirm, reconnect, ID/baseline в
  sessionStorage, старый success не выдаётся за новый, свежий /api/components
  с точной версией/SHA обязателен. При заблокированном storage история не объявляется
  успехом нового запуска. Installed/runtime версии различаются.
- Компиляция канала в BUILD_INFO и runtime identity; отдельные API panel/check,
  panel/apply, panel/operation; UI и CI wiring.

## Что действительно проверено локально

- Полный Go suite, race, vet — PASS.
- 69 Node tests — PASS; Python 9 IPK tests + 1 manifest test — PASS.
- Реальный официальный Entware opkg, SHA256
  08c8feb2ef3153f025ba687f8df02adf915e4252a3605cc6798f8d105162cb38:
  version ordering, offline install/upgrade/remove и сохранение user settings;
  source-built MIPSel IPK проходит generator → Go index parser → full preflight;
  opkg не удаляет private stage/runner/candidate при install с --tmp-dir.
- Linux arm64, armv7, mipsel softfloat, mips softfloat compile PASS.
- Реальный detached runner подтверждает отдельную session и /dev/null stdio.
- Независимое review: 3 дефекта воспроизведены RED и исправлены GREEN:
  admission race; normal `~` filenames; stale operation after reload. Также покрыты
  dead worker, interrupted gate admission и отсутствие лишних dependency fields.
- Workflow YAML syntax и git whitespace PASS.

## Не проверено — основное задание

1. Проверить CI текущего draft PR на точном HEAD. Найти конкретные упавшие jobs,
   исправить реальные причины, не запускать десятки одинаковых прогонов.
2. Новый Chromium job и расширенный panel-browser-check.cjs подготовлены, но
   локально не запускались: browser executable отсутствовал. Проверить cancel,
   потерю apply response, reload, busy controls, несовпадающий runtime, RU/EN.
3. Нужен полный реальный service-lab/firmware сценарий: old daemon → Web apply →
   independent worker → opkg/preinst stop/drain → new init start → private receipt
   → fresh browser runtime identity. Сейчас это ещё НЕ ДОКАЗАНО. Существующий
   service-lifecycle job проверяет обычный IPK lifecycle, не весь новый self-update.
4. Проверить ошибки download/checksum/ABI/место, занятый opkg, start failure,
   потерю браузера/worker, concurrent mutation, сохранность настроек/пароля/порта/YAML.
   Использовать существующий router-emulator и реальные процессы/opkg; не строить
   новую универсальную лабораторию и не подменять процессы положительными моками.
5. Проверить достаточность space budget (4*IPK + 3*unpacked + runner + 8MiB) и cleanup.
6. До доказанного сквозного сценария не публиковать сборку для аппаратной установки
   и не создавать/обновлять публичный channel index. Сейчас index ещё не опубликован.

Локальный executor имеет несовпадение PID namespace и mounted /proc: это не
Keenetic runtime. Нельзя выдавать такой host fixture за доказательство init/PID/
receipt на реальной прошивке. Нужна нормальная disposable VM/firmware.

После зелёного exact-head CI и доказанного сквозного сценария обновить PR/документацию
с точными фактами. Не закрывать #273 только по количеству тестов. Аппаратная приёмка
отдельно владельцем: одна обычная установка версии с этой функцией после CI,
затем следующий upgrade через Web. Сейчас test15 не переустанавливать.
