# GEO-данные Mihomo: GEOIP, GEOSITE и границы точности

Mihomo умеет принимать решения по наборам данных: `GEOIP`, `GEOSITE`, `IP-ASN` и `SRC-IP-ASN`. Это механизм маршрутизации по локальным базам, а не внешний сервис геолокации.

Официальные правила: <https://wiki.metacubex.one/en/config/rules/>.

## Пример

~~~yaml
rules:
  - "GEOSITE,youtube,GLOBAL"
  - "GEOIP,CN,DIRECT"
  - "IP-ASN,13335,GLOBAL"
  - "MATCH,GLOBAL"
~~~

Как и остальные rules, они идут сверху вниз: первое совпадение побеждает. См. [30-rules.md](30-rules.md).

## `geodata-mode` и loader

~~~yaml
geodata-mode: false
geodata-loader: memconservative
~~~

`geodata-mode: false` использует MMDB-вариант GeoIP, `true` — DAT-режим. `memconservative` ориентирован на ограниченные по памяти устройства и подходит роутерному профилю.

Документация: <https://wiki.metacubex.one/en/config/general/>.

## Автообновление GEO

`geo-auto-update` и `geo-update-interval` позволяют ядру обновлять базы. Проект не включает это автоматически: это дополнительная сеть/запись/память без необходимости для базовой схемы. MetaCubeXD может запросить обновление вручную через API.

## GEOIP — не точная геолокация

`GEOIP,CN,DIRECT` сопоставляет адрес с локальной базой. Точность зависит от базы; CDN, anycast и облачные сети могут давать неожиданные результаты. Обновление базы способно изменить маршрутизацию даже без изменения rules.

## GEOSITE

`GEOSITE` удобен вместо длинных списков доменов, но менее прозрачен: состав категории поддерживается внешними наборами и меняется со временем.

Для нескольких критичных доменов явные `DOMAIN-SUFFIX` часто проще проверять.

## GEO и DNS

Доменные категории требуют, чтобы Mihomo знал домен соединения. DNS/fake-ip/sniffer разобраны в [26-dns-i-fake-ip.md](26-dns-i-fake-ip.md). IP-правила работают с адресами; `no-resolve` может не позволять запускать DNS только ради проверки IP-правила.

## Что учитывать на Keenetic

Начинайте с простых DOMAIN/IP rules, GEO используйте там, где он реально сокращает конфиг, оставляйте memory-conservative loader и не делайте GEO update слишком частым. GEO не обязательна для базового проекта.

## Куда идти дальше

- [30-rules.md](30-rules.md) — порядок rules.
- [26-dns-i-fake-ip.md](26-dns-i-fake-ip.md) — источник домена.
- [44-logs.md](44-logs.md) — диагностика правил.
