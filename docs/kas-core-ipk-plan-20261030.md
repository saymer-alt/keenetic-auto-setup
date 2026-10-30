# KAS Core IPK (kas-core) — аудит и план доведения до пользовательского состояния

Дата: 2026-10-30. Статус: план (P2, issue [#295](https://github.com/saymer-alt/keenetic-auto-setup/issues/295)).
Отдельная задача: не смешивается с выпуском KAS WEB beta.2 и не блокирует его.
База реализации: Draft PR [#267](https://github.com/saymer-alt/keenetic-auto-setup/pull/267)
(`feat/kas-core-ipk`), чей содержимое уже входит в дерево `main` через интеграцию #291.

## 1. Аудит текущего состояния (что уже есть в main)

| Компонент | Состояние | Примечание |
|---|---|---|
| `packaging/core/build-ipk.py` | lab-реализация | source-pinned bundle, per-file хэши, `/opt/libexec/kas` |
| `packaging/core/{preinst,postinst,prerm,hook-common}.sh` | lab-хуки | **live-root установка намеренно заблокирована**; разрешён только `--offline-root` |
| `packaging/core/kas-core-watchdog.sh` | prototype | упакованный watchdog (подход 2: bundle + активация) |
| `packaging/core/lab-opkg.sh` | lab | оффлайн-транзакции реальным Entware opkg |
| `tests/test_core_ipk.py`, `test_core_activation.py`, `test_core_preflight.py`, `watchdog-package-regression.py` | CI | kas-core-package-proof workflow |
| `docs/superpowers/specs/2026-10-28-kas-core-ipk-design.md` | approved | владелец одобрил направление 2026-10-28: `kas-core` (скрипты) + `kas-control-center` (UI) + опциональный `kas-full` |

## 2. Доказанные ограничения raw opkg (характеризация 2026-10-28, disposable offline-root)

Это главный технический риск, определяющий архитектуру миграции:

| Проверка | Результат |
|---|---|
| Failed postinst автоматически восстанавливает предыдущий payload | **Нет** — ревизия 2 остаётся в operational path |
| Удаление пакета сохраняет operational watchdog | **Нет** — файл удаляется |
| Raw extraction участвует в KAS lifecycle lock | **Нет** |

Вывод: подход 1 (живые init/watchdog/netfilter файлы прямо в data.tar.gz) unsafe;
рабочее направление — **подход 2**: IPK как validated script bundle (пассивный),
активация operational-файлов через существующие транзакционные инсталляторы
(`update-watchdog.sh` и штатный lifecycle с блокировкой), атомарный rename.

## 3. Фазы доведения (по #295, с конкретикой)

**Фаза A — аудит и контракты (без изменений роутера).**
- Свести ownership-леджер: какие файлы принадлежат script-installed KAS
  (`setup.sh`/`bootstrap.sh`/`update-watchdog.sh`), какие — будущему `kas-core`,
  какие — `kas-control-center`; правила коллизий (modified/foreign/symlink → block
  upgrade, уже реализовано для bundle).
- Зафиксировать независимую монотонность версий: `kas-core` vX.Y.Z отдельно от
  WEB `kas-control-center` и от скриптовых релизов v1.8.x; real `opkg
  compare-versions`, source-pinned identity в BUILD_INFO ядра.
- Канонический список «single watchdog» и init-записей; запрет второго Mihomo/MagiTrickle.

**Фаза B — пассивная установка (passive IPK).**
- Разрешить live-root установку ТОЛЬКО пассивного bundle (`/opt/libexec/kas`),
  без касания init/cron/netfilter пространств; hooks продолжают отказывать при
  любых признаках live activation.
- Квалификация на disposable Entware + router-emulator: install/upgrade/reinstall/
  downgrade-отказ/uninstall; сохранение пользовательских YAML, политик, MT-настроек;
  поведение при отсутствии/наличии WEB-панели; прерванный opkg (power loss).

**Фаза C — guarded activation (переход к работающему watchdog).**
- Атомарный guarded transition через существующий transactional installer:
  явное подтверждение, idempotent retry, recovery после сбоя/питания;
  receipt активации (по образцу WEB self-update receipt).
- Двухфазная модель: «установлен» ≠ «активирован»; состояние и владелец активации
  фиксируются приватным receipt; откат — через прежний installer, не через opkg.

**Фаза D — миграция со скриптовой установки.**
- Детектор script-installed KAS (инвентарь файлов+хэшей), отчёт коллизий,
  миграционный receipt; никакого `--force-overwrite`, никакого молчаливого
  удаления/замены активных скриптов; пользовательский YAML/MT не трогается.
- Update путь: `kas-core` upgrade через bundle + повторную guarded activation;
  uninstall: удаление пакета не удаляет operational watchdog, активация снимается
  штатным uninstaller с подтверждением.

**Фаза E — приёмка и документация.**
- Disposable real-Entware + router-emulator матрица (install/upgrade/reinstall/
  uninstall/recovery/прерванная транзакция), затем — аппаратная приёмка на
  тестовом Keenetic по отдельному GO владельца (как WEB beta.2: emulator ≠ hardware).
- README-раздел только когда существует реальный поддерживаемый пакет; скриптовая
  установка остаётся основным способом до явного решения владельца.

## 4. Гейты

- Не выпускать production `kas-core.ipk` и не включать live-root activation
  без отдельного GO владельца (#295).
- Не смешивать версионирование/релизы с WEB beta.2 и ядром v1.8.x.
- Оценка трудоёмкости: фазы A–B — ближайшая инкрементальная работа на базе
  уже существующего lab-кода; C–D — основная новая разработка; E — приёмка.
