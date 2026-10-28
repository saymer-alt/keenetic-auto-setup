# Optional experimental Control Center IPK

Это отдельный opt-in пакет `kas-control-center`, не часть автоматической установки
KAS. Пакет не устанавливает, не останавливает и не удаляет Mihomo, watchdog,
MagiTrickle, маршруты или конфиги ядра. Нужны уже работающий Entware и отдельно
проверенный KAS. Аппаратная приёмка нового пакета пока **не выполнена**.

Проблема: ручной lifecycle-helper владеет бинарником и init-файлом самостоятельно;
обновлять эти же пути через opkg без явного разделения владения опасно. Выбран
маленький отдельный рецепт opkg вместо изменения основного установщика. Альтернатива
— продолжать ручной helper — остаётся доступна. Польза: стандартный учёт payload и
удаление через opkg. Цена: четыре cross-build, отдельные hooks и аппаратная приёмка.
Критерии: отказ от чужих файлов, сохранение настроек, drain импортера перед
заменой/удалением, отсутствие операций над ядром. При непроверенном владельце или
незавершённом drain пакет останавливается с ошибкой; принудительного удаления нет.

## Сборка

Из корня checkout; Python 3, Go и обычный Linux build-host:

```sh
python3 web/control-center/packaging/build-ipk.py \
  --arch mipsel-3.4 --version 0.1.0-1 \
  --source-sha "$(git rev-parse HEAD)" --output /tmp/kas-ipk
(cd /tmp/kas-ipk && sha256sum ./*.ipk > SHA256SUMS)
python3 tests/test_ipk.py -v
```

Поддержаны `aarch64-3.10`, `armv7-3.2` (`GOARM=7`), `mipsel-3.4`, `mips-3.4`.
Все сборки — `CGO_ENABLED=0`, MIPS — `GOMIPS=softfloat`. В пакет включается
`/opt/share/kas-control-center/BUILD_INFO`: source SHA, архитектура, параметры Go и
SHA256 бинарника. Версия пакета задаётся явно. `--binary` предназначен только для
тестирования архива, а не для выпуска: происхождение переданного файла не проверяется.

Workflow `web-ipk.yml` собирает четыре IPK с SHA в версии и имени артефакта,
сохраняет `SHA256SUMS` и вывод `go version -m`. Он не создаёт релизов, не публикует
`latest`, не меняет `main`/`stable`. Пререлиз с правом записи требует отдельного
явного решения и привязки к конкретному source SHA.

## Ручная установка и запуск на тестовом устройстве

Выбрать IPK **точной архитектуры Entware**, проверить контрольную сумму, затем:

```sh
sha256sum -c SHA256SUMS
opkg install ./kas-control-center_VERSION_ARCH.ipk
/opt/etc/init.d/S98kas-control-center start
/opt/etc/init.d/S98kas-control-center status
```

`postinst` **никогда не запускает сервис** — также после upgrade. При upgrade
`preinst` останавливает старую панель через SIGTERM и ожидает drain до 60 секунд;
при ошибке замену следует прекратить. После успешного upgrade панель нужно запустить
вручную. Уже установленный init-файл запускает сервис при обычном Entware boot.
Не применять `--force-overwrite`/`--force-removal-of-dependent-packages` для обхода отказа.

Команда сервиса:

```sh
/opt/bin/kas-control-center -lan -listen auto \
  -settings-file /opt/etc/kas-control-center.settings.json
```

Свежая конфигурация использует Home LAN/br0 и порт **8081**. Отсутствующий settings-файл
означает defaults; файл создаёт приложение при сохранении. Импортированная ручная
настройка может сохранять **18081**. При занятом адресе старт возвращает ненулевой код и понятный `PORT_BIND_FAILED`;
другие сервисы и порты не меняются. Для первого запуска на свободном порту можно
явно создать **новый**, ещё не существующий settings-файл (не перезаписывать свои
настройки), затем запустить сервис:

```sh
umask 077
# Только если settings-файла ещё нет; 18082 — пример свободного порта.
(set -C; printf '%s\n' '{"version":1,"port":18082,"auth_mode":"none"}' > /opt/etc/kas-control-center.settings.json)
/opt/etc/init.d/S98kas-control-center start
```

Для существующей конфигурации менять порт через настройки панели либо подготовить
копию настроек отдельно, сохранив все поля и права 0600. Init выводит проверенный
адрес, полученный от запуска Go. Произвольные ошибки/секреты не сохраняются: FIFO
фильтр оставляет не более двух коротких служебных строк в tmpfs startup-файле.
Точный текущий адрес после изменения порта нужно смотреть в настройках панели;
init не утверждает, что импортированный порт равен defaults.

Совместимые необязательные пользовательские файлы:

| Файл `/opt/etc/kas-control-center.*` | Аргумент |
| --- | --- |
| `password` | `-password-file` (legacy password) |
| `proxy-origin` | `-proxy-origin` |
| `export-names` | `-provider-names-export` (явный opt-in) |
| `mihomo-api-secret` | `-provider-secret-file`, только вместе с export |

Settings и эти файлы не входят в package payload. Пакет не читает и не переписывает
секреты в hooks; init передаёт секретные файлы по пути, а не содержимое в argv.
В payload сохраняется BSD notice зависимости `github.com/GehirnInc/crypt` в
`/opt/share/kas-control-center/THIRD_PARTY_NOTICES`.

Файлы секретов должны быть обычными, принадлежать root и иметь права 0600;
проверки содержимого выполняет приложение. Симлинки отклоняются.

## Переход с ручной установки и удаление

IPK и `kas-web-manage.sh` имеют разные ownership markers. `preinst` отказывает,
если бинарник/init уже существуют без учёта этого пакета в opkg, либо остался
`kas-control-center.web.sha256`. Автоматического захвата/миграции нет.

Сначала сохранить настройки/секреты, записать текущий порт (для старой ручной установки
обычно 18081), остановить и удалить **только панель** исходным ручным helper. Проверить,
что процесс завершился, его binary/init/manifest убраны, а настройки сохранены. Затем
установить IPK и явно запустить его. Не удалять несовпадающий payload вручную ради
обхода проверки: сначала выяснить владельца.

```sh
/opt/etc/init.d/S98kas-control-center stop
opkg remove kas-control-center
```

Удаление вызывает graceful stop; SIGKILL отсутствует. При незавершённом импорте
удаление/upgrade должны завершиться ошибкой: дождаться окончания и повторить.
Файлы настроек, паролей, API secret и proxy origin сохраняются после удаления,
поскольку opkg их не устанавливал. Не использовать ручной helper для удаления IPK.

## Границы проверки

Тесты читают **реальный gzip-tar IPK** и исполняют извлечённые hooks в изолированном
`IPKG_INSTROOT`/`PKG_ROOT`; это не имитация положительного ответа opkg. Проверяются состав,
metadata, свежая установка, upgrade ownership, отказ от ручного init и сохранение
пользовательского settings. Offline hooks не запускают сервисы хоста.

Реальный Entware opkg 38eccbb1 (2024-10-16), официальный статический x64 installer,
прошёл install → upgrade → remove в offline-root с `--force-postinstall`: исполнялись
также hooks. Этот тест выявил и закрепил три требования Entware: gzip-tar внешний
контейнер вместо Debian ar; явные directory members внутри data tar; `PKG_ROOT`
для offline hooks. SHA256 installer: `08c8feb2ef3153f025ba687f8df02adf915e4252a3605cc6798f8d105162cb38`.
CI скачивает его по HTTPS и проверяет закреплённый SHA256 перед запуском.

Локально тест реального Entware `opkg --offline-root` выполняется при наличии
`KAS_TEST_OPKG=/path/to/entware/opkg`; без него явно SKIP. Ни host-архив, ни hooks
не доказывают поведение BusyBox/proc на роутере или фактический
importer drain. Перед продвижением нужны тестовый роутер каждой заявляемой архитектуры,
install/start/reboot/upgrade/remove, занятый порт, изменённый/чужой PID, рабочий импорт
во время SIGTERM и сохранность конфигов ядра. Не выполнять на production автоматически.
