# Ручное обновление панели (#273)

Разработка поверх #278. Не опубликовано; аппаратная приёмка самообновления и
сквозной firmware/service-lab сценарий ещё не выполнены. Test15 не изменяется.

## Поведение

В обзоре отдельная карточка панели. «Проверить» вручную читает один channel index,
проверяет release metadata и сравнивает внутреннюю Version по Entware opkg.
Installed и runtime отображаются отдельно; при расхождении установка запрещена.
`compare-versions A >> B` означает строго новее; `>` у проверенного Entware
возвращает успех и для равных версий. Сравнение запускается в приватном offline-root,
чтобы не брать lock рабочего opkg и не требовать его индексов для сравнения строк.

Подтверждённое обновление запускает независимую session/process group из приватного
runner. Browser cancellation не отменяет его. Перед остановкой панели проверяются
SHA256, размеры, структура IPK, точные package/Version/ABI/Source/Channel/ELF и
отсутствие dependency/replacement metadata. Из архива ничего не исполняется при
проверке. Только opkg запускает проверенные package hooks при установке.

Опубликованный index должен указывать на source-pinned пакет после CI. Нельзя
публиковать manifest для локальной dirty-сборки как проверенный release.

## Релизный протокол

- Compiled identity и BUILD_INFO содержат Channel. Первый этап установки поддерживает
  только experimental; наличие stable parser не означает готовность stable канала.
- Index `panel-update.json` находится в выделенном release
  `kas-web-channel-experimental`; его обновление отдельно подтверждает владелец.
- Index указывает на immutable prerelease `kas-web-ipk-SHA` и содержит для ABI
  internal Version, SourceSHA, имя/размер/SHA256 IPK, размер unpacked data и digest binary.
- Candidate release API должен подтверждать uploaded asset, имя, размер, SHA256 и
  точный download URL проекта. Неизвестные/неполные данные дают отказ.
- Существующие релизы без index не выбираются автоматически. `latest` не используется.
- GitHub может нормализовать имя asset при upload (`~` → `.`). Сначала сверить
  фактические имена опубликованных assets; генератор читает internal Version из
  control независимо от имени файла. Переименовать локальные копии в фактические
  имена перед созданием index. Не угадывать Version по имени.

Создать index из уже проверенных IPK (не публикует его):

```sh
python3 web/control-center/packaging/update-manifest.py \
  --channel experimental --tag kas-web-ipk-SHA package.ipk > panel-update.json
```

`SHA` в примере заменить действительным коротким hexadecimal SHA. Этот документ
не является разрешением на публикацию release/index или установку на устройство.

## Состояние и восстановление

Private root-owned `/opt/etc/kas-control-center-update/` (0700):
`job.json` и `runtime.json` (0600), gate directory, worker flock.
Фазы: queued → download → install → starting → complete. До opkg отказ безопасно
снимает gate; начиная с install ошибка сохраняет gate и требует recovery.
Не полагаться на существование pid-файла/нулевой opkg exit. Новый процесс после
bind пишет receipt с operation nonce, версией, SHA, PID и starttime+boot identity;
worker сверяет executable inode. Браузер дополнительно проверяет свежий
авторизованный `/api/components`. Ошибка получения runtime не объявляется успехом.

Все mutating admission checks повторно сверяют durable gate под app mutex.
Это закрывает запросы, прошедшие middleware до начала обновления. Server TERM ждёт
обычные import/update workers, но не самообновление, иначе preinst/deamon deadlock.

Временные IPK/runner находятся в `/opt/tmp/.kas-panel-update-ID` (0700) и удаляются
после успеха/безопасного отказа. Нет истории IPK, предыдущей копии для отката или
автоматического rollback. При неопределённом результате opkg payload не заменяется
ручным копированием и не объявляется исправным.

Для явно прерванной установки: после проверки причин оператор может вызвать
`/opt/bin/kas-control-center -recover-panel-update`. Команда не устанавливает пакет:
проверяет отсутствие worker/активного opkg, ownership/metadata/digest установленного
payload, перезапускает только панель и снимает gate только после runtime receipt.
Если факты не подтверждены, остаётся ошибка и ручная диагностика. При повреждённом
бинарнике потребуется обычное ручное восстановление проверенным IPK.

## Ресурсы и доказательства

Conservative preflight на каждой затронутой ФС: 4 × IPK + 3 × unpacked payload +
runner + 8 MiB metadata reserve, минимум 64 свободных inode, если ФС их сообщает.
До скачивания и перед opkg проверка повторяется. Все размеры ограничены (IPK
16 MiB, data 32 MiB); tar/gzip/binary hash читаются потоково. Обычные package
operations не создают дополнительной постоянной версии на `/opt`.

Локальные проверки подтверждают парсеры/отказы, реальные Entware version comparison,
реальную offline установку/upgrade, сохранение настроек, сохранность runner/stage
после opkg и detached session. Это не доказательство полного самообновления на
KeeneticOS: namespace PID/proc текущего executor отличается от обычного firmware.
Нужен отдельный service-lab/firmware install→Web upgrade→runtime receipt→reconnect
с запуском новой службы, потере соединения, занятой opkg и start failure. До этих
проверок сборку не публиковать для аппаратного использования.

Первый переход с test15 до версии с этой функцией потребует одного обычного upgrade
IPK после CI; только следующий переход проверяется через Web. Сейчас переустановка
test15 не выполняется.
