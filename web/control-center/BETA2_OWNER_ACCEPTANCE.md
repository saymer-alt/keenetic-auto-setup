# Аппаратная приёмка KAS Web v0.1.0-beta.2 на KN-1010 (владелец, SSH)

> **Статус:** READY FOR OWNER ACCEPTANCE. Подготовлено агентом 30.10.2026 по проверенному
> кандидату; сама приёмка — отдельное ручное действие владельца на физическом роутере.
> Агенты не подключаются к физическим роутерам (ограничение ночной очереди).

## Проверенный кандидат

| Параметр | Значение |
|---|---|
| Source SHA | `e5e8a54b41b4afa93b8fe8681fda0e38822ca0e3` (текущий HEAD `main`) |
| CI-сборка | GitHub Actions run **41099642234** (SUCCESS, все 4 архитектуры, metadata-tests + real-opkg version ladder) |
| Версия пакета | `0.1.0~beta.2-1` (внутренняя Entware-версия; в имени asset GitHub `~` нормализуется в `.`) |
| Пакет | `kas-control-center`, Architecture `mipsel-3.4` (KN-1010) |
| SHA256 mipsel IPK | `b5ba6afde77d48d933f2d4922e0aa74a5a35ae0accc957fb1912dbe7f50ace0a` |
| SHA256 остальных | aarch64 `357382c1…`, armv7 `3d67a8cc…`, mips `9f36076c…` (полные значения в `SHA256SUMS` артефакта) |
| Независимая верификация агента | SHA256SUMS OK, ELF соответствует архитектуре (MIPS32 little endian, GOMIPS=softfloat, CGO_ENABLED=0), BUILD_INFO/Source/manifest согласованы, архив артефактов скачан и проверен байт-в-байт |

GitHub Actions артефакты хранятся **21 день** (сборка от 30.10.2026 — не позднее ~20.11.2026).
Публичного релиза `v0.1.0-beta.2` на момент подготовки ещё нет: до его публикации приёмка
идёт по артефакту CI, после — по asset релиза с тем же SHA256.

## Порядок операций (важно)

Канал `experimental` сейчас указывает на `kas-web-ipk-92e301d` (beta.1). Панели beta.1 и
test17 принимают только теги вида `kas-web-ipk-<sha>`; канонический тег `v0.1.0-beta.2`
они не прочитают. Поэтому:

1. **Сначала** владелец вручную обновляет пилотный KN-1010 на beta.2 по этой инструкции
   (прямая установка IPK через SSH, без индекса).
2. **Потом** публикуется релиз и переключается индекс (см.
   [BETA2_PUBLISH_RUNBOOK.md](BETA2_PUBLISH_RUNBOOK.md)) — новая beta.2-панель уже читает
   канонический тег.

## Шаг 0. Предусловия

- SSH-доступ к KN-1010 работает; панель не публикуется в WAN.
- KAS (Mihomo) работает штатно; выполнение `mihomo-doctor.sh` перед началом фиксируется.
- Есть доверенный ПК с браузером и SSH/SCP-клиентом.

## Шаг 1. Зафиксировать состояние до обновления

```sh
opkg print-architecture                                   # ожидаем mipsel-3.4
opkg list-installed | grep kas-control-center             # какая версия пакета стоит сейчас
/opt/bin/kas-control-center -version                      # runtime-версия панели
sh /opt/etc/init.d/S98kas-control-center status           # статус службы
```

Установленной может оказаться beta.1 (`0.1.0~beta.1-1`) или test17
(`0.0.1~test44.9c715283d525-1`) — путь обновления одинаковый. Запишите обе строки в журнал
приёмки.

## Шаг 2. Резервное копирование пользовательских файлов

```sh
mkdir -p /opt/tmp/beta2-acceptance-backup
cp -a /opt/etc/kas-control-center.settings.json /opt/tmp/beta2-acceptance-backup/ 2>/dev/null
for f in /opt/etc/kas-control-center.password /opt/etc/kas-control-center.proxy-origin \
         /opt/etc/kas-control-center.home-only; do
  [ -f "$f" ] && cp -a "$f" /opt/tmp/beta2-acceptance-backup/;
done
cp -a /opt/etc/mihomo/config.yaml /opt/tmp/beta2-acceptance-backup/
ls -la /opt/tmp/beta2-acceptance-backup/
```

На внешнем носителе (если `/opt` внутренний) дополнительно сохраните каталог
`/opt/tmp/beta2-acceptance-backup/` на ПК по SCP — tmpfs теряется при перезагрузке.

## Шаг 3. Скачать ровно подходящий IPK и проверить SHA256

На доверенном ПК скачайте артефакт `kas-web-beta2-mipsel-3.4-e5e8a54b41b4afa93b8fe8681fda0e38822ca0e3`
из run **41099642234** (репозиторий → Actions → «KAS Web v0.1.0-beta.2 candidate IPKs»).
Внутри артефакта: один IPK, `SHA256SUMS`, два манифеста.

```sh
# на ПК
sha256sum -c SHA256SUMS            # обязательно OK
scp kas-control-center_0.1.0~beta.2-1_mipsel-3.4.ipk root@<KN-1010>:/opt/tmp/
```

```sh
# на роутере — повторная проверка (не доверяем передаче)
cd /opt/tmp
sha256sum kas-control-center_0.1.0~beta.2-1_mipsel-3.4.ipk
# ожидаем b5ba6afde77d48d933f2d4922e0aa74a5a35ae0accc957fb1912dbe7f50ace0a
```

Если хеш не совпал — **остановиться**, не устанавливать, скачать заново.

## Шаг 4. Обновление через opkg

```sh
opkg install /opt/tmp/kas-control-center_0.1.0~beta.2-1_mipsel-3.4.ipk
```

Не использовать `--force-*`. Если opkg сообщает конфликт/занятость — зафиксировать вывод,
СТОП, разбирать до продолжения. `postinst` панель сам не запускает.

## Шаг 5. Проверка установленной и работающей версии

```sh
opkg list-installed | grep kas-control-center      # 0.1.0~beta.2-1
/opt/bin/kas-control-center -version               # runtime = 0.1.0~beta.2-1, source e5e8a54b41
sh /opt/etc/init.d/S98kas-control-center start
sh /opt/etc/init.d/S98kas-control-center status
netstat -ltnp 2>/dev/null | grep 8081 || ss -ltnp 2>/dev/null | grep 8081
```

Открыть `http://<KN-1010-на-br0>:8081/` (или сохранённый пользовательский порт):

- заголовок/«Обзор» показывает публичную версию **v0.1.0-beta.2** (префикс `v`);
- настройки порта/доступа/пароля сохранились (читаются из
  `/opt/etc/kas-control-center.settings.json`);
- YAML-конфиг, исключения фильтра подписок, Doctor — на месте и отвечают;
- Mihomo работает (порт 7890, Controller 9090 отвечает);
- обновление панели: «Проверить версию панели» на канале «Бета» — до публикации релиза
  и переключения индекса панель beta.2 по-прежнему видит текущий индекс beta.1 и честно
  сообщает «установлена более новая версия, чем в канале» (это ожидаемо: `0.1.0~beta.2-1`
  новее `0.1.0~beta.1-1`);
- перезапуск панели: `sh /opt/etc/init.d/S98kas-control-center restart`, затем повторно
  проверить веб-интерфейс.

## Шаг 6. Перезагрузка (проверка автозапуска)

```sh
reboot
# после загрузки:
sh /opt/etc/init.d/S98kas-control-center status
/opt/bin/kas-control-center -version
```

Проверить порт, YAML, фильтры и Mihomo ещё раз.

## Восстановление после ошибки (без автоматического rollback)

- Обновление не завершилось, панель не стартует, код `PANEL_RECOVERY_REQUIRED`:
  не выключать питание. `sh /opt/etc/init.d/S98kas-control-center stop`, проверить
  `opkg list-installed`, затем `/opt/bin/kas-control-center -recover-panel-update`.
- Пакет повреждён или панель так и не работает: `opkg remove kas-control-center`
  (пользовательские настройки сохраняются), затем установить тот же проверенный IPK заново.
- Откат на beta.1 возможен только вручную установкой сохранённого IPK beta.1 —
  автоматического отката нет, и это осознанное поведение панели.
- KAS/Mihomo обновлением панели не затрагивается: при проблемах Mihomo чинить Mihomo,
  не переустанавливая KAS целиком.

## Журнал приёмки (заполнить и приложить к Issue #273/#289)

| Проверка | Результат |
|---|---|
| Версия до / после (opkg и runtime) | |
| SHA256 проверен дважды (ПК + роутер) | |
| Порт 8081/пользовательский, веб-интерфейс отвечает | |
| Публичное отображение v0.1.0-beta.2 | |
| YAML / фильтры / Doctor / Mihomo сохранены и работают | |
| Настройки доступа/пароля сохранены | |
| Перезапуск службы и перезагрузка роутера | |
| Сообщение канала обновлений до публикации релиза | |
| Восстановление не потребовалось / потребовалось (что делали) | |
