# WARPSCOUT / Cloudflare WARP — межрепозиторный реестр наблюдений

**Дата инвентаризации:** 2026-11-18. **Статус:** исследовательский реестр (не конфигурация для развёртывания).  
**Единый публичный каталог наблюдений:** `saymer-alt/keenetic-auto-setup/docs/research/`.  
**Каноническая матрица новых сканов:** [WARPSCOUT-PROVIDER-MATRIX.md](WARPSCOUT-PROVIDER-MATRIX.md).  
**Определения NODE/SEEN AS и методика:** [35-warpscout.md](../encyclopedia/35-warpscout.md).

Этот документ составлен по уже опубликованным материалам и публичным PR. Он **не переносит секреты или информацию из приватных репозиториев**. PR, не влитые в целевую ветку, помечены как *OPEN / источник ещё в PR*. При импорте сверять оригинал; приведённые здесь итоги не являются независимой повторной проверкой сырого TXT.

## 1. Публичные источники и распределение ответственности

| Исходный репозиторий | Материал | Тип / решение |
|---|---|---|
| keenetic-auto-setup | [Матрица 17–18.11.2026](WARPSCOUT-PROVIDER-MATRIX.md), [теория и ранние операторы](../encyclopedia/35-warpscout.md) | **Единственный публичный реестр измерений**; матрица сейчас в [PR #526](https://github.com/saymer-alt/keenetic-auto-setup/pull/526), не в main |
| link-generators | [Keenetic: полевые заметки 09–10.2026](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-KEENETIC-FIELD-NOTES-2026-09.md) | Первичные исследовательские заметки и практические команды остаются в проекте |
| link-generators | [VPS: полевые заметки 09–10.2026](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-VPS-FIELD-NOTES-2026-09-10.md) | Исторические сравнения SE2/EE, смена Cloudflare colo |
| link-generators | [3 VPS, 06–07.11.2026](https://github.com/saymer-alt/link-generators/pull/341) | **OPEN PR #341**, детальные результаты ещё не в main |
| link-generators | [WARPSCOUT на Keenetic](https://github.com/saymer-alt/link-generators/blob/main/docs/WARPSCOUT-KEENETIC.md), [VPS](https://github.com/saymer-alt/link-generators/blob/main/docs/WARPSCOUT-VPS.md), [Windows](https://github.com/saymer-alt/link-generators/blob/main/docs/WARPSCOUT-WINDOWS.md) | Инструкции; не копировать их сюда как вторую версию руководства |
| link-generators | [revalidation contract](https://github.com/saymer-alt/link-generators/blob/main/docs/research/future/WARPSCOUT-REVALIDATION.md), [PoC engine](https://github.com/saymer-alt/link-generators/blob/main/research/poc/warpscout-engine/engine.mjs), [dialer fieldtest](https://github.com/saymer-alt/link-generators/blob/main/tools/warp-dialer-fieldtest/README.md) | Дизайн/автоматизация/отдельные runtime-тесты; не считать сканами операторов |
| entware-go | [warpscout/README.md](https://github.com/saymer-alt/entware-go/blob/gh-action-build/warpscout/README.md) | Сборка/установка и ранние полевые доказательства KN-1812, а не канонический журнал |
| vps-gateway-bootstrap | [ZAI-82: живой WARP egress](https://github.com/saymer-alt/vps-gateway-bootstrap/blob/main/docs/live-cloudflare-warp-egress-zai-82.md), [MSK V3 snapshot](https://github.com/saymer-alt/vps-gateway-bootstrap/pull/70) | Сетевая интеграция и проверка реального выхода; **PR #70 OPEN** |
| amnezia-mihomo-gateway | [WARP routing](https://github.com/saymer-alt/amnezia-mihomo-gateway/blob/main/scripts/check-warp-routing.sh), [live audit](https://github.com/saymer-alt/amnezia-mihomo-gateway/blob/main/docs/LIVE_AUDIT_2026-09-23.md) | Эксплуатационные проверки маршрутизации, не новый набор сканов |
| keenetic-knowledge-base | [База знаний](https://github.com/saymer-alt/keenetic-knowledge-base) | На `main` не обнаружен отдельный набор Warpscout; достаточно навигационной ссылки |

В приватных KAS-dev и saymer-infrastructure также есть исследовательские/эксплуатационные сведения, однако **публичный перенос приватного содержимого не санкционирован этим реестром**: необходим отдельный обзор на секреты, инфраструктурную чувствительность и согласованную обезличенную публикацию.

## 2. Исторические наблюдения, которые нельзя потерять

| Когда / сеть | Наблюдение из публичного источника | Проверенность и ссылка |
|---|---|---|
| ~25.06.2026, 2КОМ/Алмател, рабочая сеть, Tele2, МегаФон | Упоминались разные маршруты/colo: Рига, Домодедово, Финляндия, Германия; неоднородные параметры и терминология | **HISTORICAL / не сопоставлять напрямую**; [энциклопедия KAS](../encyclopedia/35-warpscout.md) |
| 23.09.2026, SE2 VPS | WG 70/70, ARN; H3 2/14 и H2 70/70 при указанном SNI | FIELD-NOTES, [сентябрьский VPS архив](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-VPS-FIELD-NOTES-2026-09-10.md) |
| 23.09.2026, EE VPS | WG 68/70; H3 8/14; H2 56/70, наблюдались ARN и SEEN AS EE | FIELD-NOTES, [тот же источник](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-VPS-FIELD-NOTES-2026-09-10.md) |
| 25.09.2026, KN-1012 GSM/LTE | AWG до 70/70, DME/ARN/FRA/AMS; H2 с указанным SNI 70/70; H3 не прошёл полный data-path scan | FIELD-NOTES, [Keenetic архив](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-KEENETIC-FIELD-NOTES-2026-09.md) |
| 25.09.2026, NC/KN-1012 проводной WAN | AWG 65/70, DME/ARN/AMS; H2 70/70; H3 13/14 при отдельном SNI, в этих MASQUE-сканах наблюдался DME | FIELD-NOTES, [Keenetic архив](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-KEENETIC-FIELD-NOTES-2026-09.md) |
| 30.09.2026, VPS | Ранее достижимый FRA перестал находиться, маршрут к Cloudflare наблюдался через ARN; `-exclude-node` не заставляет Anycast сменить colo | FIELD-NOTES, [VPS архив](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-VPS-FIELD-NOTES-2026-09-10.md) |
| 21.10.2026, домашний Titan 4210, 2КОМ | Три WARP-интерфейса и каскад .4 → .3; HTTP Cloudflare trace `colo` RIX → HEL, GeoIP оставался RU | **Реальный runtime-эксперимент, не однородный скан WARPSCOUT**; [Keenetic архив](https://github.com/saymer-alt/link-generators/blob/main/docs/research/WARPSCOUT-KEENETIC-FIELD-NOTES-2026-09.md) |
| 06.11.2026, Saymer2 VPS | WG 70/70, до 396,0 Мбит/с; H2 66/70, до 74,1; H3 14/14, до 166,2; наблюдался ARN/SE | **OPEN PR #341**; [детали](https://github.com/saymer-alt/link-generators/pull/341) |
| 06.11.2026, hungry-boyd VPS | WG 70/70 до 206,2 Мбит/с; H2 67/70 до 154,6; H3 14/14 до 134,8; ARN/EE | **OPEN PR #341**; [детали](https://github.com/saymer-alt/link-generators/pull/341) |
| 06–07.11.2026, Saymer3 / Москва VPS | AWG 70/70 DME/FRA до 213,5 Мбит/с (DME); исключение DME оставляло FRA (30/30); повтор 07.11 выбирал FRA до 170,3 Мбит/с. Исходные WG/H2/H3 не прошли; отдельно H2/H3 с другим SNI затем работали через DME | **OPEN PR #341**; [детали](https://github.com/saymer-alt/link-generators/pull/341) |
| 17–18.11.2026, Акадо/МТС/Tele2/МегаФон | Ноябрьские AWG-сканы и группировка по NODE, времени, портам и потере пакетов | **PR #526**, [матрица](WARPSCOUT-PROVIDER-MATRIX.md), не считать дублирующие строки дважды |

Дополнительное полевое подтверждение в [entware-go WARPSCOUT README](https://github.com/saymer-alt/entware-go/blob/gh-action-build/warpscout/README.md): на одном из испытаний KN-1812 plain WG 0/70, AWG 70/70, а иностранный Cloudflare NODE (RIX) не обеспечивал иностранный SEEN AS. Нельзя переносить этот результат на все операторы и даты.

## 3. Критерии единой записи

Для будущего нормализованного `scans.csv`: `scan_id`, `source_file`, `source_repo/ref`, `time_utc`, `observed_network`, `network_kind`, `test_location`, `device`, `warpscout_version`, `protocol`, `scan_flags`, `endpoint_ip`, `endpoint_port`, `working`, `torn_down`, `node`, `node_location`, `seen_as`, `tunnel_rtt_ms`, `loss_pct`, `speed_mbps`, `egress_validation`, `evidence_status`, `notes`.

- **Единица измерения** — один фактический прогон и одна проверка `IP:port`. Совпадающие в нескольких прогонах endpoint'ы — повторные измерения, не «разные независимые маршруты». Не подсчитывать дважды строки из обзорной и подробной таблиц одной матрицы.
- **`NODE` ≠ `SEEN AS` ≠ HTTP `colo` ≠ место VPS**. `REGION=RU` в TXT нельзя подставлять вместо `SEEN AS`.
- **Отсутствие speedtest** и `SPEED=0.0 Mbps` без `-speed` — *скорость не измерялась*, а не нулевая. RTT endpoint ≠ RTT внутри туннеля.
- Разделять `AWG/WG/MASQUE-H2/MASQUE-H3`, разные SNI/I1, выход напрямую или через промежуточный туннель; не приписывать разницу одному провайдеру без контролируемого сравнения.
- **Статусы источника:** `RAW_VERIFIED` — проверен первичный TXT; `FIELD_NOTES` — документированный полевой пересказ; `REPORTED` — сообщение владельца без TXT; `HISTORICAL` — архив без сопоставимой методики; `SYNTHETIC` — тестовый пример, не полевой факт.
- **Безопасность:** никогда не публиковать `warpscout-account.json`, приватные WG/AWG-ключи, токены, учётные данные, персональные IP/топологию, конфиги VPS или секреты в URL. Очищенные сырьевые отчёты публиковать только после проверки; отсутствие исходника помечать.
- Из публичных репозиториев оставлять инструкции/код на месте, а сюда переносить агрегированные измерения и ссылки на исходные доказательства. При дальнейшей миграции поддерживать ссылки и не удалять исходные материалы без отдельной проверки.

## 4. Следующие задачи для консолидации

1. Привести таблицу в `WARPSCOUT-PROVIDER-MATRIX.md` к одной строке на скан: сейчас МТС 18.11 продублирован в короткой и подробной формах; числа не суммировать дважды.
2. Превратить исторические строки раздела 2 в отдельные `FIELD_NOTES/HISTORICAL` записи с исходными ссылками и временем; при наличии оригинальных TXT перепроверить по ним.
3. Включить проверенные исследования MGTS/другие приватные источники **только после решения о границе публикации**; исходные приватные файлы/секреты не переносить.
4. Добавить `warpscout/scans.csv`, `warpscout/findings.md` и `warpscout/raw/` *после* проверки формата, дедупликации и очистки TXT. Каталог в этом PR пока не создаётся, чтобы не считать обещанный формат существующими данными.
5. Из других проектов добавлять короткую ссылку на этот канонический журнал, не создавать параллельные матрицы.
