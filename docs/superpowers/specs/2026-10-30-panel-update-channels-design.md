# KAS WEB: схема каналов обновлений и переход beta → stable (ADR)

Дата: 2026-10-30. Статус: предложено (PR `release/kas-web-v0.1.0-beta.2-prep`).
Задачи: #289 (P1), #273, #282. База: `v0.1.0-beta.1` (92e301d, experimental).

## Контекст

beta.1 опубликована и неизменяема. Её код: канал зашит (`panelBuildChannel=experimental`),
`handlePanelCheck` читает только `kas-web-channel-experimental/panel-update.json`,
`parsePanelIndex` принимает тег только формата `kas-web-ipk-<SHA>` и только prerelease,
worker требует `j.Channel=="experimental" && j.Channel==panelBuildChannel`,
`validatePanelIPK` сверяет `BUILD_INFO.Channel` с каналом кандидата. Никакой выбор
канала не предусмотрен. Требование #289: beta.1 → beta.2 без SSH; из беты — явный
переход на stable; публичные beta-релизы без обязательных двойников `kas-web-ipk-<SHA>`;
fail-closed безопасность сохраняется полностью.

## Решение

1. **Хранение выбора канала** — приватный файл
   `/opt/etc/kas-control-center-update/channel` (0600, одна строка `experimental\n`
   или `stable\n`). Отсутствие файла = канал сборки. Отдельный файл выбран вместо
   поля в `kas-control-center.settings.json`, потому что парсер настроек строгий
   (`DisallowUnknownFields`): неизвестное поле сломало бы чтение настроек у
   beta.1 при любом движении версии вниз, а отдельный файл beta.1 просто не читает.
2. **API выбора** — `GET/POST /api/updates/panel/channel`. POST требует те же
   Origin/Host/Sec-Fetch-Site/confirm-заголовки, что остальные мутации, отклоняется
   под gate/busy и **ничего не запускает**: ни проверку, ни установку. Смена канала
   сбрасывает `p.checked` — кандидат, найденный на одном канале, нельзя применить
   после переключения. `panelChannelTargets` отдаёт выбор: experimental-сборка —
   `experimental|stable`, stable-сборка — только `stable`.
3. **Теги каналов** — experimental: `kas-web-ipk-<SHA>` (legacy-фоллбэк, чтение
   установленной beta.1) ИЛИ канонический `v0.1.0-beta.N` / `kas-web-v0.1.0-beta.N`
   (prerelease). stable: только `kas-web-vX.Y.Z`, только обычный релиз. Проверка
   release-метаданных (draft/prerelease/asset size/digest/state/URL) не менялась
   ни для одного канала.
4. **Воркер** — предикат `panelJobChannelAllowed(build, job, candidate)`:
   известный канал + тег принадлежит каналу джобы. Кросс-канальные джобы
   допускаются в обоих явных opt-in направлениях (experimental → stable миграция;
   stable → experimental переход на бету) по контракту beta.2; кандидат обязан
   нести канал джобы в `BUILD_INFO.Channel`, а реальное сравнение opkg блокирует
   любой downgrade независимо от канала — stable-панель не видит experimental-
   предложение, пока не появится строго более новая бета.
5. **Джоба** — `j.Channel` берётся из канала проверенного кандидата
   (`candidate.Channel` из index), а не повторным чтением выбора: смена канала
   инвалидирует кандидата, поэтому рассинхрон невозможен.
6. **Публикация beta.2** — один канонический prerelease `v0.1.0-beta.2`
   (source-pinned, 4 IPK + SHA256SUMS) **без** alias `kas-web-ipk-<SHA>`: по
   контракту beta.2 публичные беты больше не дублируются, а единственный пилотный
   KN-1010 с beta.1 владелец обновляет вручную до beta.2; experimental index
   переключается сразу на канонический тег. Legacy-парсер `kas-web-ipk-<SHA>`
   остаётся в коде только как фоллбэк чтения. beta.3+ и stable публикуются так же
   канонически. stable: релиз `kas-web-v0.1.0` (не prerelease), IPK с
   `--channel stable`, отдельный index `kas-web-channel-stable`. GitHub `latest`
   (ядро KAS v1.8.x) не используется ни одним каналом.

## Отвергнутые альтернативы

- **Переименовать канал/выдать stable IPK за experimental**: ломает
  `validatePanelIPK` (Channel в BUILD_INFO) — и это правильно.
- **Выбор канала в settings.json**: несовместимо со строгим парсером настроек
  beta.1 (`DisallowUnknownFields`); выбран изолированный приватный файл.
- **Автообновление или авто-проверка при смене канала**: противоречит #273/#289
  (только ручной check/apply).
- **Использовать GitHub latest или сканирование релизов**: явно запрещено.
- **Запретить stable → experimental**: контракт beta.2 требует явный opt-in в
  обе стороны; безопасность обеспечивает строгая новизна версии + неизменные
  пакетные проверки, поэтому запрет не нужен и был бы нечестным ограничением.
- **Ограничить выбор канала каналом сборки**: `panelBuildChannel` — происхождение
  сборки, а не политика; ограничение сломало бы будущий stable-релиз при
  осознанном переходе на бету.

## План проверки (честная матрица)

- Go-тесты: матрица допуска каналов воркера (обе стороны opt-in + отказы по
  тегу/каналу), allowlist тегов, несовпадение `BUILD_INFO.Channel`, хранение/сброс
  выбора, guards эндпоинта. Linux (root) + QEMU aarch64 (эмулированный CPU).
- Реальный Entware opkg: лестница `0.1.0~beta.1-1 < 0.1.0~beta.2-1 < 0.1.0-1`
  и отказ в обратную сторону.
- service-lab aarch64 CI (`tests/test_panel_selfupdate_service.sh`, расширена):
  полный сквозной эксперимент: experimental-панель → выбор stable → проверка →
  применение stable-кандидата через реальный opkg → receipt; opt-in обратно в
  experimental без даунгрейда; подменённый stable index. Это host-фикстура на
  ARM64 VM, не приёмка KeeneticOS и не физическое устройство.
- Эмулятор/физический KN-1010: отдельное контролируемое решение владельца,
  эмуляция не объявляется аппаратной приёмкой.
