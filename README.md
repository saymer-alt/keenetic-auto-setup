# 🛡️ Keenetic Auto-Setup Suite

**Mihomo + MagiTrickle на Keenetic с Entware:** установка, безопасный импорт конфига, watchdog и диагностика. Проект не предоставляет VPN-серверы — нужен свой сервер или подписка.

[English](docs/EN/README.md)

## 🚀 Установка

Нужны **Entware/OPKG, SSH и интернет**. В KeeneticOS должны быть установлены компоненты `proxy`, `dns-filter`, `opkg-kmod-netfilter` и `dns-tls` **или** `dns-https`. [Где их включить](docs/COMPONENTS_RU.md) · [Как подготовить Entware и внешний EXT4](docs/16-entware-external-storage.md).

Скопируйте команду целиком:

```sh
opkg update && opkg install curl && \
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

`setup.sh` сам определяет внутреннее/внешнее хранилище, проверяет ограничения и после установки открывает импорт конфигурации. **Выбирать `ram`/`disk` вручную не нужно.**

Если скачивание зависло **ещё до первого сообщения установщика**, повторите с совместимым TLS:

```sh
curl -4 -fSsL --connect-timeout 5 --max-time 20 --curves X25519 https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/setup.sh | sh
```

Другие проблемы установки → [подробная инструкция](docs/03-install.md) · [устранение неполадок](docs/08-troubleshooting.md).

## 📋 После установки: конфигурация

1. Создайте YAML в [Mihomo Config Builder](https://saymer-alt.github.io/link-generators/) — в нём должен быть `mixed-port: 7890`.
2. Вставьте **весь YAML** в открывшийся **Mihomo Config Import** и нажмите **Ctrl+D один раз**.
3. Если конфига пока нет, введите **`s` и Enter** — это пропустит импорт, не меняя текущий конфиг.

Импортёр проверяет YAML и сохраняет предыдущую конфигурацию для отката. [Подробности и импорт из файла](docs/13-config-import.md).

После импорта полного YAML откройте MetaCubeXD: `http://<IP-роутера>:9090/ui/`. MagiTrickle: `http://<IP-роутера>:8080/`. **Если ввели `s`, MetaCubeXD ещё не настроен**; пользовательский файл `.mtrickle` тоже импортируется отдельно.

## 🛠 Частые команды

**Проверить систему — Doctor (без изменений настроек):**

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**Импортировать или заменить YAML позже:**

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
```

**Обновить Mihomo** (с проверкой и откатом):

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

Остальные команды:

| Действие | Команда или инструкция |
| --- | --- |
| Открыть текущий конфиг | `nano /opt/etc/mihomo/config.yaml` |
| Статус Mihomo | `/opt/etc/init.d/S99mihomo status` |
| Перезапуск после ручной правки | `/opt/etc/init.d/S99mihomo restart` |
| Обновить watchdog | [`update-watchdog.sh`](docs/12-updates.md) |
| Проверить конкретный сайт | [Route Check](docs/15-route-check.md) |
| Посмотреть выбранный прокси | [`mihomo-proxy-selection-watch.sh`](docs/11-proxy-selection-watch.md) |

**Не очищайте `config.yaml` до создания резервной копии.** Для полной замены предпочтителен безопасный Config Import. Остальные способы и диагностика → [HOWTO](docs/HOWTO_RU.md).

## ⚠️ Важно перед запуском

- **zRAM + внешний SWAP одновременно запрещены** во всех классах RAM: **Installer — ERROR, Doctor — FAIL, Updater — ERROR**. Автоматического обхода нет.
- Для **512 МБ RAM** нужен активный штатный zRAM **или** проверенный внешний SWAP, но не оба. Для внешнего `/opt` нужен **EXT4** и компоненты `ext`/`ext-utils`.
- Установщик не заменяет настройки вашего VPN-сервера и не импортирует личный `.mtrickle`-экспорт. Перед изменениями на рабочем роутере сохраните резервную копию.

[Все требования и ограничения](docs/09-limitations.md) · [Конституция безопасности](docs/CONSTITUTION.md) · [Защита внутренней флешки / S00ubifs](docs/06-s00ubifs.md).

## 📚 Подробная документация

[Установка](docs/03-install.md) · [Обновления и откат](docs/12-updates.md) · [Диагностика](docs/08-troubleshooting.md) · [Архитектура](ARCHITECTURE.md) · [Полный HOWTO](docs/HOWTO_RU.md) · [Краткий старт](docs/02-quick-start.md) · [CHANGELOG](CHANGELOG.md) · [Лицензия](LICENSE)
