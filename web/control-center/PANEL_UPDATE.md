# Ручное обновление панели (#273)

Реализация разработана поверх #278 и #279 (см. также #283, #285).
**Обновление статуса, 30.10.2026:** experimental channel index опубликован,
тестовый KN-1010 (KeeneticOS 5.1.8, Entware mipsel-3.4) успешно обновлён
через WEB **с test16 на test17**, интерфейс подтвердил работу нового процесса
`0.0.1~test44.9c715283d525-1`. Это реальная аппаратная приёмка
положительного сценария, но не всех отказов, ARM64-железа или автоматического отката.
Матрица и план первой ограниченной беты: [BETA_RELEASE.md](BETA_RELEASE.md).

## Проверено в disposable service-lab (aarch64 GitHub VM, реальные процессы)

`tests/test_panel_selfupdate_service.sh` (job `selfupdate-lifecycle`,
`ubuntu-24.04-arm`) ведёт сквозной сценарий на настоящих процессах: старый
daemon, Web check/apply, detached session worker, реальный Entware opkg с
preinst stop/drain, явный init start нового payload, приватный runtime
receipt и свежий авторизованный `/api/components` с точной версией/SHA.
github.com и api.github.com резолвятся на локальный HTTPS-сервер лаборатории
с её CA в системных хранилищах; TLS/CA проверка не отключается, процессы
проекта не подменяются. Это host-фикстура, а не приёмка KeeneticOS.

Честно воспроизведённые отказы: нехватка места до скачивания, сбой скачивания,
подменённый channel index, подменённый asset, чужой ABI, занятый реальный
opkg-lock (fcntl), отказ старта после реальной установки плюс явный
`-recover-panel-update`, отказ конкурирующих мутаций под durable gate,
побайтовая сохранность настроек/порта/YAML. Полный список маркеров — в логе
задания `selfupdate-lifecycle`.

Лаборатория вскрыла два поведения реального Entware, которые x64-лаборатория
не показывала, и оба закрыты в реализации:

1. opkg aarch64-фида (сборка 2022) на реальной (не offline-root) установке
   пишет `lib/opkg/info/<pkg>.list` с режимом 0666, игнорируя umask; сборка
   x64 2024 пишет 0600. Режим opkg-владельческого списка — дело opkg, поэтому
   worker читает список как evidence (структурные проверки сохранены), а
   приватные файлы панели остались под строгим контрактом.
2. Entware-opkg скомпилирован с префиксом /opt: «голый» `opkg install` worker'а
   читает `/opt/etc/opkg.conf`. Лаборатория зеркалирует этот путь.

Также исправлен найденный лабораторией дефект init-скрипта: untracked-скан
стартового процесса считал сам recovery-CLI (`-recover-panel-update`,
запущенный из того же бинарника) второй панелью и отказывал контролируемому
рестарту; фиксированные CLI-режимы (worker/recovery) теперь не считаются
панелью, они не биндят листенеров. И вторая гонка: процесс мог завершиться
между чтением состояния и проверкой identity в цикле drain — зомби отвечал
kill -0 и давал ложный «pid identity changed»; теперь состояние
перечитывается, зомби корректно завершает drain.

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

Локальные проверки подтверждают парсеры/отказы, реальный Entware version comparison,
реальную offline установку/upgrade, сохранение настроек, сохранность runner/stage
после opkg и detached session. Полный native ARM64 service-lab на GitHub runner
подтвердил install→Web upgrade→runtime receipt→reconnect с новым процессом.
**Он не является аппаратным тестом KeeneticOS.** Дополнительно KN-1010 подтвердил
именно положительный аппаратный сценарий test16→test17. Потеря соединения,
занятость opkg, повреждения кандидата и отказ запуска отрицательно проверены
в disposable CI, а не на физическом роутере. Нельзя расширять этот PASS до
проверки всех отказов на железе или заявлять автоматический откат.

Исторически test15 требовал обычного IPK upgrade для получения кнопки self-update;
в реальном тесте исходным IPK был test16, а новым test17.
