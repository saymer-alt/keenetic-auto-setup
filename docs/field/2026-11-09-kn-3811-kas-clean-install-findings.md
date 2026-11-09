# FIELD 2026-11-09 — «Охрана 126» (KN-3811): установка KAS, загрузка IPK, UBIFS и WEB

> **Тип свидетельства:** предоставленные оператором SSH/Doctor/Web-выводы 09.11.2026 + проверка кода KAS и GitHub Actions. Приватные данные намеренно не воспроизводятся. Важно различать *результат реальной установки*, *объяснение текущей реализации* и *предлагаемое исправление*. Лабораторный CI не заменяет FIELD на Keenetic.

## 1. Проверенное состояние устройства после установки (FIELD)

| Параметр | Подтверждённый результат |
| --- | --- |
| Устройство | Keenetic Hopper KN-3811, объект «Охрана 126» |
| ОС | KeeneticOS 5.1.8, release 5.01.C.8.0-2, stable, aarch64 |
| Entware | `/opt` на внутренней UBIFS, `/dev/ubi0_0` (`/storage`, bind mount); не USB/EXT4 |
| До установки | Чистая Entware: отсутствуют `mihomo`, `magitrickle`, `config.yaml`, init Mihomo и LISTEN 7890; около 86.2 MiB свободно на /storage |
| KAS | Core v1.8.8 (bootstrap из `stable`) установлен; KAS WEB v0.1.0-beta.8 RUNNING на штатном порту 18080 |
| Mihomo | 1.19.33, `opkg status`: **1.19.33-1**, работающий `/opt/bin/mihomo` **55 169 KiB**; порт 7890 LISTEN, controller 9090 отвечает |
| MagiTrickle | 0.8.2-1, процесс RUNNING, DNS 3553 LISTEN, NAT port-53 remap обнаружен |
| Native routing | Каскад `Proxy0` SOCKS5 UDP → локальный 7890 и `bypass_wa` присутствуют; Proxy0 после установки UP/CONNECTED (read-only Keenetic MCP) |
| Safety/runtime | `S00ubifs` enabled, `/opt/tmp`, `/opt/var/log`, `/opt/var/run` — tmpfs; zRAM ~511 MiB; UBI rw `ro_mode=0`, `bad_peb_count=0` |
| Место после установки | Doctor: **/opt 48 из 98 MB свободно**, /tmp 239 из 243 MB; RAM available ~154/486 MB |
| Watchdog | cron и wrapper настроены; в доступном журнале один restart после «Mihomo port unreachable», затем healthy heartbeat; это **восстановление на момент проверки**, а не доказательство стабильности за длительный срок |
| Doctor | На установленном роутере **Doctor 1.2.19: 35 OK, 0 WARN, 0 FAIL**; `Overall status: OK` |

**Ограничение приёмки:** успешная установка и контроль сервисов ≠ проверка всех пользовательских сайтов/туннелей/маршрутов. Функциональный DNS-тест MagiTrickle по нестандартному порту был **SKIPPED**, поскольку отсутствовал `dig`; `HTTP 404` на опрашиваемой Web API точке MagiTrickle показан как информация, не как FAIL. Дополнительную мутацию рабочего роутера по этим пунктам не инициировать.

## 2. Как на «чистом» KN-3811 оказался большой Mihomo

Наблюдаемая последовательность установки `install.sh`:

1. В GitHub `saymer-alt/entware-go:latest` успешно **найден** архитектурный `mihomo_1.19.33-2_aarch64-3.10.ipk`.
2. Загрузка выбранного Release Asset **не завершилась** через штатные повторные `curl` и `wget`; затем напечатан fallback WARN. Из данного факта нельзя без отдельных сетевых логов заключать, что причиной был конкретный DPI, TLS, CDN или DNS.
3. Последний резерв `opkg install mihomo` установил **сжатый IPK Entware `mihomo_1.19.33-1_aarch64-3.10.ipk`** из `bin.entware.net`.
4. После распаковки на `/opt` оказался обычный ELF ~55 MiB. **Это размер установленного файла, не размер скачанного по сети IPK.** Формат IPK сжат и для официального Entware.
5. На внутренней UBIFS запись дополнительно сжимается самой ФС. Поэтому пакетная установка действительно смогла завершиться даже при ограниченном физическом разделе. Заявлять, что «55 MB скачаны по сети», **неправильно**.

**Это не «старый файл, переживший форматирование»:** непосредственно до установки `/opt/bin/mihomo`, YAML и пакетные записи отсутствовали. При этом native KeeneticOS `opkg disk storage:/`, `Proxy0`, `bypass_wa` сохраняются независимо от форматирования Entware — их нельзя путать с файлами `/opt`.

### Сообщение «Existing Mihomo config left untouched» на пустой Entware

В ходе свежей установки это сообщение возникало **после** установки фидового IPK. Оно не доказывает сохранение прежнего пользовательского YAML после форматирования. По коду `ensure_bootstrap_config` различает отсутствующий файл, нетронутый пакетный conffile (по md5 из `opkg status`) и пользовательский конфиг. Сработавшее сообщение совместимо с **только что созданным** package conffile, который не прошёл md5-сопоставление. Это **вероятная гипотеза, не установленная причина**; нужны безопасные offline fixtures/тесты именно для feed 1.19.33-1. Реальный YAML был импортирован через KAS, и порт 7890 после импорта слушал.

### Netfilter и Proxy0

До установки read-only `Proxy0` был DOWN, а после installer-managed интерфейсного восстановления стал UP/CONNECTED. При проверках правила `bypass_wa` появились после переподключения `Proxy0` и повторного чтения Netfilter (в журнале — на второй проверке). Это демонстрирует чувствительность к жизненному циклу native интерфейса/перестроению firewall, а не необходимость ручного сброса iptables. **Не добавлять** слепые рестарты или изменения firewall в действующем рабочем роутере.

## 3. Место, IPK, UPX и механизм обновления — три разных эффекта

| Механизм | Что реально сжимает/измеряет | Практическое следствие |
| --- | --- | --- |
| Архив IPK | Передаваемые и хранимые байты пакета | И официальный Entware, и project `entware-go` скачивают сжатые IPK |
| UPX для проектных релизов | Сам **установленный** ELF, после извлечения из IPK | Подходящий UPX-кандидат может быть гораздо меньше обычного ELF, что сильно снижает staging-потребность |
| UBIFS | Физические страницы NAND при записи в файловую систему | `df` и логический размер ELF не дают точной оценки физически занятых блоков; не гарантирует дополнительного фиксированного процента сжатия |

`mihomo-doctor.sh` 1.2.19 выводил на KN-3811 информационный ориентир **«текущий ~55 MB + 4 MiB = ~57 MiB»** при 48 MB free. **Это не блокировка установки сжатого IPK и не вердикт о невозможности обновления через KAS.** Транзакционный `update-mihomo.sh` скачивает проектный IPK из `entware-go` во временный RAM-каталог, извлекает фактический **candidate ELF**, проверяет доступное место для соседней копии candidate + safety margin 4 MiB, затем делает контролируемый commit с rollback. Проверку безопасности отключать нельзя.

**Подтверждённый предыдущий FIELD 25.09.2026, KN-1012 GSM с internal UBIFS:** после удаления старого неиспользуемого backup свободное место выросло ~37.8 → ~56.1 MB; через `update-mihomo.sh` и project IPK `1.19.31-2` успешно обновлено `1.19.30 → 1.19.31`. Фактический staging estimate был **17 096 KiB**, Doctor после обслуживания **33 OK / 0 WARN / 0 FAIL**. Источник: [архив аппаратных испытаний 2026-09](../archaeology/kas-testing-field-evidence-2026-09.md). Отдельный NC-1012 с внешним EXT4 — **не** этот кейс; не смешивать результаты.

**Вывод:** KAS уже реально обновлял Mihomo на внутренней UBIFS при небольшом свободном объёме, повторять эксперимент «для доказательства возможности» не требуется. При этом конкретное **обновление KN-3811 09.11.2026 не выполнялось**; успешная initial install из фида не равна FIELD PASS для `update-mihomo.sh`. `opkg upgrade` из фида и штатный Mihomo self-upgrade/Controller — тоже иные пути (есть риск возврата к фидовому бинарнику или большому upstream ELF). См. [docs/12-updates.md](../12-updates.md) и #320.

## 4. SSH: почему пользователь видел «Downloading...» и тишину

На текущем production `install.sh` путь больших assets имел до 3 обычных `curl`, один `curl -4 --curves X25519`, затем до 3 `wget`, с `ASSET_DOWNLOAD_MAX_TIME=180` на попытку. Внутренний `retry_silent` подавлял stderr; пользователь не видел, с какой попыткой/источником сейчас работает скрипт. При задержке DNS, TLS или передачи байтов это выглядит как зависание.

**Решение для интерактивного SSH:** показывать `curl 1/3`, `2/3`, `3/3`; отдельную попытку IPv4/X25519, попытки `wget 1/3..3/3`, затем Asset API `1/2`; реальный `curl --progress-bar` и штатный индикатор `wget` по возможностям BusyBox. До первого полученного байта **не выдумывать проценты**: показывать метод, номер и ограничение времени. В неинтерактивном логе сохранять лаконичную схему один WARN на исчерпавшийся transport; частично скачанный файл удалять **после каждой** неудачной попытки.

В [Draft PR #479](https://github.com/saymer-alt/keenetic-auto-setup/pull/479) в теме #478 подготовлены такая обратная связь и fallback через GitHub Release Asset API **того же** project IPK (asset ID из проверенных metadata, size + sha256 при наличии), до последнего `opkg install mihomo`. Это **код в topic branch**, не опубликованное stable-поведение.

## 5. GitLab: зеркало скриптов уже есть, зеркала IPK нет

[GitLab mirror KAS](https://gitlab.com/saymer-alt/keenetic-auto-setup) синхронизирует только Git ref-ы `main`, `stable` и теги через существующий workflow. **Не синхронизирует GitHub Release assets, IPK, Issues/PR и workflow artifacts.** Поэтому невозможно просто подставить GitLab raw URL для project Mihomo IPK: его там ещё нет. Подробный существующий контракт: [GitLab mirror](../gitlab-mirror.md).

Независимая задача [#481](https://github.com/saymer-alt/keenetic-auto-setup/issues/481): выбрать публичную доставку *тех же артефактов* `entware-go` из GitLab (например, Package Registry) с ABI, version, size, SHA256, immutable versioned URLs, защитой от рассогласования latest/manifest, ограниченными правами на публикацию и тестами анонимного HTTPS. **До этого никаких выдуманных зеркальных URL в рабочем installer.** Публикация, секреты и настройка workflow требуют отдельного GO.

После фактической публикации проверенного зеркала: GitHub Release → GitHub Asset API → GitLab verified project IPK → Entware `opkg install mihomo` (последний резерв). GitHub Asset API может перенаправить на тот же CDN; это дополнительный шанс, **не** гарантированное решение сетевой недоступности.

## 6. WEB beta.8: storage-метрики и реальное состояние

На вкладке «Диагностика → Системные показатели» beta.8 выводились CPU/SoC **63.3 °C**, load average ~0.27/0.40/0.43, uptime, RAM и swap, **но не свободное место /opt**. Температура — факт чтения сенсора, **не доказательство перегрева**. В той же панели Doctor корректно показывал `Накопитель Entware: внутренняя память / ubifs / /dev/ubi0_0`, `48 из 98 MB` и `/tmp 239 из 243 MB`.

Source-level причина: контракт `router-metrics/v1` в `kas-sys-metrics.sh`, Go validation и JS rendering не содержат storage-поле. Требуется read-only on-demand карточка **«Накопитель Entware (/opt)»** с class/fs/free/total, корректным UNKNOWN и поддержкой UBIFS/EXT4, без запуска полного Doctor по нажатию кнопки метрик и без новой нагрузки на flash. Issue [#476](https://github.com/saymer-alt/keenetic-auto-setup/issues/476). Это P2 UX, **не runtime failure**.

## 7. GitHub evidence и состояние разработки на 09.11.2026

- Main baseline на момент сверки: `b41ff34d835c82a5136e06bf10c235d9edac4032`; stable: `c80e47c7050a31f70f65312dcd8999bfb13c9bef`. Новые изменения находятся в topic branches, **не в stable**.
- [#476](https://github.com/saymer-alt/keenetic-auto-setup/issues/476): системные показатели WEB, добавить /opt (OPEN). [Draft PR #477](https://github.com/saymer-alt/keenetic-auto-setup/pull/477): документация IPK/UPX/UBIFS.
- [#478](https://github.com/saymer-alt/keenetic-auto-setup/issues/478): отказ скачивания project IPK/обратная связь (OPEN). [Draft PR #479](https://github.com/saymer-alt/keenetic-auto-setup/pull/479): GitHub Asset API fallback, TTY progress, очистка partial и offline regression. Кодовая голова проверенного PR #479: `46e7b148e831da37e00557ec0934f3a2d7027f4f`.
- [#481](https://github.com/saymer-alt/keenetic-auto-setup/issues/481): separate R&D GitLab mirror project IPK (OPEN, ещё нет работающих URL).

**CI snapshot для `46e7b148`:**
- [Core Sync Guard](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42618905856): workflow SUCCESS (это не HW acceptance и не утверждение, что runtime drift отсутствует).
- [CI workflow](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42618906019): **FAIL** на `Candidate-build dry-run` (opkg ladder: mismatch pinned SHA256 скачиваемого внешнего `opkg`). До этого `sh -n`, BusyBox syntax, **installer mocked progress/Asset API test**, lifecycle и `sh tests/contracts.sh` были **PASS**; следующее после failure не выполнялось.
- [KAS core package qualification](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42618905875): **FAIL** на `Verify official Entware opkg` — SHA256 скачанного `opkg` не совпал с закреплённым digest.
- [Keenetic ported native E2E](https://github.com/saymer-alt/keenetic-auto-setup/actions/runs/42618906642): **FAIL** на `RUN_ENTWARE EXCEPTION: ValueError: download digest mismatch`.

Здесь **нет полного CI PASS**. Эти ошибки похожи на общую проблему provenance/digest внешнего `opkg`, но нельзя без отдельного анализа объявить их безусловно независимыми от текущего PR или просто обновить pin на новый hash. Нужны сверка официального источника, идентичности байтов/версий, происхождения ожидаемого SHA256, доверенной цепочки, сравнение с base SHA и отдельная разрешённая правка (смежная задача, не смешивать с #478).

## 8. Дальнейшие работы и stop conditions

1. **P1:** ревью Draft PR #479 и exact-SHA CI, проверить обработку ошибок/redirect, partial/size/digest и одинаковую семантику TTY/non-TTY. Не создавать бесконечные retries; не объявлять GitHub Asset API гарантированным обходом CDN.
2. **P1 (отдельный сбой CI):** расследовать внешний Entware `opkg` SHA mismatch — не менять доверенный pin вслепую и не считать падение теста новой функции доказанным.
3. **P2:** #476 добавить /opt в Web System Metrics (internal UBIFS/external EXT4, UNKNOWN). Не трогать текущую WEB beta.8 на рабочем объекте.
4. **R&D:** #481 опубликовать доверенные project IPK/manifest в GitLab, проверить анонимную доступность и только затем подключать зеркало к installer.
5. **Optional regression:** на offline fixture воспроизвести `Existing Mihomo config left untouched` для свежего фидового conffile, не перезаписывая пользовательский YAML. Не фиксировать догадку как root cause.

**Граница полномочий:** отчёт и связанные PR/Issue — записи в GitHub. Отдельное owner GO нужно на merge в `main`, перенос в `stable`, release, изменение внешних артефактов/секретов и любые испытания на рабочем роутере. Установленная на «Охрана 126» система по последнему Doctor исправна; **повторно устанавливать/перезагружать/проверять обновление там не нужно**. Никакие реальные IP, приватные ключи, подписки или пользовательский YAML не публиковать.

