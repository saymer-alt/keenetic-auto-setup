# 🛡️ Keenetic Auto-Setup Suite — Mihomo + MagiTrickle

Автоматизированная установка и интеграция **[Mihomo](https://github.com/MetaCubeX/mihomo) + [MagiTrickle](https://magitrickle.dev/)** на Keenetic с Entware. **Mihomo** обеспечивает прокси-подключения и маршруты к вашим серверам, а **MagiTrickle** управляет группами и правилами выбора трафика по DNS/доменам. Оба компонента важны для работы системы.

[English](docs/EN/README.md)

**Быстрый переход:** [Частые команды](#частые-команды) · [Установка](#1-установка) · [Конфигурация](#2-конфигурация-mihomo) · [Проверка](#3-проверка-и-запуск) · [Обновление](#4-обновление) · [Другие команды](#5-дополнительные-команды)

---

## Частые команды

Все команды для SSH в одном месте: **каждый блок копируется отдельно**. Подробные пояснения остались в разделах ниже.

**1. Установить KAS (Mihomo + MagiTrickle)**

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

**2. Открыть конфигурацию Mihomo**

```bash
nano /opt/etc/mihomo/config.yaml
```

**3. Сохранить копию, очистить конфиг и открыть nano**

⚠️ Текущий файл очищается **до открытия редактора**; старая версия сохраняется в `config.yaml.bak` (существующая `.bak` будет перезаписана).

```bash
cp /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak && : > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

**4. Очистить конфиг без резервной копии и открыть nano**

⚠️ **Опасно:** содержимое `config.yaml` будет потеряно. Не перезапускайте Mihomo, пока не сохраните исправный YAML.

```bash
: > /opt/etc/mihomo/config.yaml && nano /opt/etc/mihomo/config.yaml
```

**5. Безопасно импортировать новый YAML (предпочтительно вместо очистки)**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
```

**6. Проверить систему — Doctor**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**7. Перезапустить Mihomo**

```bash
/opt/etc/init.d/S99mihomo restart
```

**8. Проверить статус Mihomo**

```bash
/opt/etc/init.d/S99mihomo status
```

**9. Обновить Mihomo**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

---

## 0. Что нужно

- Keenetic с Entware, SSH и доступом в Интернет.
- Компоненты KeeneticOS: `proxy`, `dns-filter`, `opkg-kmod-netfilter`; дополнительно `dns-tls` **или** `dns-https`.
- Для внешнего `/opt`: только EXT4, компоненты `ext` и `ext-utils`.

[Установка Entware на USB/SSD](docs/16-entware-external-storage.md) · [Полные требования и ограничения RAM/swap](docs/COMPONENTS_RU.md) · [Проблемы с `opkg update`](docs/22-entware-feed-fallback.md)

## 1. Установка

**Выполните целиком в SSH роутера:**

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

`bootstrap.sh` запускает мастер `setup.sh`, который определяет профиль `ram`/`disk`, выполняет установку через `install.sh` и предлагает импорт конфигурации. [Как это работает](docs/14-setup.md).

> **Важно:** одновременные KeeneticOS zRAM и внешний SWAP запрещены: **Installer — ERROR, Doctor — FAIL, Updater — ERROR**. Для 512 МБ RAM необходим активный zRAM **или** внешний SWAP. [Все ограничения](docs/09-limitations.md) · [Контракт безопасности](docs/CONSTITUTION.md).

[Расширенная установка, резервные способы загрузки, offline/SCP](docs/03-install.md)

## 2. Конфигурация Mihomo

После установки откроется **Mihomo Config Import**:

1. Создайте YAML в [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).
2. Вставьте полный конфиг в SSH и нажмите **Ctrl+D один раз**.
3. Если импорт пока не нужен, введите **`s` и Enter**. Запустить позже: команда №5 в [«Частых командах»](#частые-команды).

Импорт проверяет конфиг, сохраняет резервную копию и поддерживает откат. **Настройки MagiTrickle (`.mtrickle`) импортируются отдельно вручную** через его веб-интерфейс.

После импорта полного YAML (подставьте IP своего роутера):

```text
MetaCubeXD:  http://192.168.1.1:9090/ui/
MagiTrickle: http://192.168.1.1:8080/
```

Если импорт пропущен, MetaCubeXD на 9090 ещё не настроен. [Подробности импорта](docs/13-config-import.md) · [MagiTrickle](https://magitrickle.dev/) · [Генератор](https://github.com/saymer-alt/link-generators)

## 3. Проверка и запуск

Команды редактирования, Doctor, перезапуска и статуса Mihomo собраны выше в [«Частых командах»](#частые-команды).

Для проверки конкретного домена через ProxyN → Mihomo: [mihomo-route-check.sh](docs/15-route-check.md).

[Диагностика и ошибки](docs/08-troubleshooting.md) · [Цвета и статусы CLI](docs/18-output-colors.md)

## 4. Обновление

- **Mihomo:** команда №9 из [«Частых команд»](#частые-команды). Пользовательский `config.yaml` не перезаписывается.
- **Watchdog:** [update-watchdog.sh](docs/12-updates.md).
- **MagiTrickle:** `opkg update && opkg install magitrickle`.

[Все способы обновления и отката](docs/12-updates.md)

## 5. Дополнительные команды

Нестандартные операции вынесены из README, чтобы случайно не применить их при обычной установке:

- [Миграция TUN и MIPS](docs/12-updates.md)
- [Проверка интерфейсов и маршрутизации](ARCHITECTURE.md)
- [Текущий выбранный прокси / failover-failback](docs/11-proxy-selection-watch.md) — `mihomo-proxy-selection-watch.sh`
- [Ручные изменения ProxyN, DNS, policy routing и диагностика](docs/HOWTO_RU.md)

## 6. Скрипты проекта

`bootstrap.sh` → `setup.sh` → `install.sh` → `config-import.sh` — цепочка стандартной установки.

**[Полный список скриптов и их назначение](docs/SCRIPTS.md)**

## 7. Удаление

Удалить Mihomo и MagiTrickle **без форматирования /opt**:

```sh
curl -fSsL -o /tmp/kas-remove-packages.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/uninstall-packages.sh && sh /tmp/kas-remove-packages.sh
```

YAML сохраняются. Настройки ProxyN, DNS, политик и Netfilter KeeneticOS не удаляются. Проверено в QEMU и на KN-1010.

## 8. Справочник

- [Полное HOWTO](docs/HOWTO_RU.md)
- [Энциклопедия / карта системы](docs/encyclopedia/00-karta-sistemy.md)
- [Roadmap](docs/10-roadmap.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)