# Скрипты Keenetic Auto-Setup

Полный список служебных скриптов и ссылок на инструкции. Главный [README](../README.md) оставлен как краткая инструкция для установки и повседневной работы.

**Обычная установка:** `bootstrap.sh` → `setup.sh` → `install.sh` → `config-import.sh` (импорт предлагается после успешной установки).

## Перечень скриптов

| Скрипт | Назначение / документация |
| --- | --- |
| [`uninstall.sh`](../uninstall.sh) | [Только безопасная проверка `--check`; удаление `--remove`/`--purge` пока заблокировано](23-uninstall.md) |
| [`bootstrap.sh`](../bootstrap.sh) | [Стартовый загрузчик KAS: получает и проверяет `setup.sh`, использует резервные источники GitHub и запускает мастер](14-setup.md#зачем-нужен-bootstrapsh) |
| [`setup.sh`](../setup.sh) | [Мастер: определяет `ram`/`disk`, вызывает `install.sh` и предлагает импорт конфигурации](14-setup.md) |
| [`install.sh`](../install.sh) | [Основной установщик с ручным выбором профиля](03-install.md) |
| [`config-import.sh`](../config-import.sh) | [Импорт и безопасная замена `config.yaml`](13-config-import.md) |
| [`migrate-mihomo-tun.sh`](../migrate-mihomo-tun.sh) | [Добавить TUN/`mitun0` в legacy-конфиг без секции `tun:`](12-updates.md#legacy-config-добавление-tun--mitun0) |
| [`migrate-mihomo-mips.sh`](../migrate-mihomo-mips.sh) | [Перевод TUN-конфига с gVisor на MIPS](12-updates.md#mips-tun-migration) |
| [`mihomo-doctor.sh`](../mihomo-doctor.sh) | [Доктор: полная диагностика проекта](08-troubleshooting.md) |
| [`mihomo-interface-check.sh`](../mihomo-interface-check.sh) | [Показать Linux-имена WAN/VPN-интерфейсов для `interface-name`](../ARCHITECTURE.md) |
| [`mihomo-proxy-selection-watch.sh`](../mihomo-proxy-selection-watch.sh) | [Показать, какой сервер Mihomo выбран сейчас](11-proxy-selection-watch.md) |
| [`mihomo-route-check.sh`](../mihomo-route-check.sh) | [Проверить доступность конкретного сайта через Mihomo](15-route-check.md) |
| [`update-mihomo.sh`](../update-mihomo.sh) | [Обновить ядро Mihomo с проверкой и откатом](12-updates.md#обновление-mihomo) |
| [`update-watchdog.sh`](../update-watchdog.sh) | [Обновить механизм watchdog](12-updates.md#обновление-watchdog) |
| [`mihomo-watchdog.sh`](../mihomo-watchdog.sh) | [Проверять Mihomo и перезапускать его при подтверждённом сбое](04-watchdog.md) |
| [`020-bypass-wa.sh`](../020-bypass-wa.sh) | [Перехватывать VoIP-трафик и передавать его в отдельную политику `bypass_wa`](05-bypass-wa.md) |
| [`S00ubifs`](../S00ubifs) | [Перенести временные каталоги Entware в RAM и снизить запись во флешку](06-s00ubifs.md) |


Подробности загрузки и проверки первого скрипта: [мастер установки](14-setup.md) и [расширенная установка](03-install.md).
