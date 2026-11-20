# 🛡️ Keenetic Auto-Setup Suite — Mihomo + MagiTrickle

Автоматизированная установка и интеграция **[Mihomo](https://github.com/MetaCubeX/mihomo) + [MagiTrickle](https://magitrickle.dev/)** на Keenetic с Entware. **Mihomo** обеспечивает прокси-подключения и маршруты к вашим серверам, а **MagiTrickle** управляет группами и правилами выбора трафика по DNS/доменам. Оба компонента важны для работы системы.

[English](docs/EN/README.md)

> Зеркало (только чтение): [gitlab.com/saymer-alt/keenetic-auto-setup](https://gitlab.com/saymer-alt/keenetic-auto-setup) — синхронизируется автоматически из GitHub; Releases, Issues и PR ведутся только на GitHub. Подробности: [docs/gitlab-mirror.md](docs/gitlab-mirror.md).

**Быстрый переход:** [Частые команды](#частые-команды) · [Установка](#1-установка) · [Конфигурация](#2-конфигурация-mihomo) · [Проверка](#3-проверка-и-запуск) · [Обновление](#4-обновление) · [Другие команды](#5-дополнительные-команды)

---

## Частые команды

Все команды для SSH в одном месте: **каждый блок копируется отдельно**. Подробные пояснения остались в разделах ниже.

**1. Установить KAS (Mihomo + MagiTrickle)**

```bash
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh
```

**2. Открыть конфигурацию Mihomo для ручного редактирования (без очистки)**

```bash
nano -I /opt/etc/mihomo/config.yaml
```

Ключ `-I` отключает чтение проблемных `nanorc` (например, ошибку `Error expanding /usr/share/nano/*.nanorc`). Для замены всего YAML **предпочтителен безопасный импорт, команда №5**: не очищайте рабочий файл перед открытием редактора.

**3. Сделать резервную копию и открыть nano (без очистки файла)**

⚠️ Существующая `config.yaml.bak` будет перезаписана. Эта команда не обнуляет действующий YAML.

```bash
cp -p /opt/etc/mihomo/config.yaml /opt/etc/mihomo/config.yaml.bak && nano -I /opt/etc/mihomo/config.yaml
```

**4. Проверить имя установленного init-скрипта Mihomo**

В зависимости от сборки Entware устанавливается `S28mihomo` **или** `S99mihomo`. Если обнаружены оба, остановитесь и запустите Doctor — состояние неоднозначно.

```sh
ls -l /opt/etc/init.d/S28mihomo /opt/etc/init.d/S99mihomo 2>/dev/null
```

**5. Заменить конфиг Mihomo новым YAML без `nano` (рекомендуется)**

Команда запускает мастер импорта: сгенерируйте YAML в [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/), скопируйте его текст, выполните команду, вставьте YAML в приглашение и завершите ввод **Ctrl+D** (перед вставкой можно прервать: `s` + Enter):

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh | sh -s -- --script config-import.sh
```

Мастер проверяет YAML, сохраняет прежний конфиг в `config.yaml.bak`, заменяет его и перезапускает Mihomo; при сбое восстанавливает прежний. Доставка и детали мастера — [docs/13-config-import.md](docs/13-config-import.md) (приватный файл с фолбэками, issue #255).

**6. Проверить систему — Doctor**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

**7. Перезапустить Mihomo**

Не используйте фиксированное имя `S99mihomo`: новая сборка может устанавливать `S28mihomo`. Команда выбирает единственный исполняемый скрипт и останавливается при неоднозначности.

```sh
if [ -e /opt/etc/init.d/S28mihomo ] && [ -e /opt/etc/init.d/S99mihomo ]; then
  echo "ERROR: both S28mihomo and S99mihomo exist; run Doctor" >&2
elif [ -x /opt/etc/init.d/S28mihomo ] && [ ! -L /opt/etc/init.d/S28mihomo ]; then
  /opt/etc/init.d/S28mihomo restart
elif [ -x /opt/etc/init.d/S99mihomo ] && [ ! -L /opt/etc/init.d/S99mihomo ]; then
  /opt/etc/init.d/S99mihomo restart
else
  echo "ERROR: Mihomo init script not found or not executable" >&2
fi
```

**8. Проверить статус Mihomo**

```sh
if [ -e /opt/etc/init.d/S28mihomo ] && [ -e /opt/etc/init.d/S99mihomo ]; then
  echo "ERROR: both S28mihomo and S99mihomo exist; run Doctor" >&2
elif [ -x /opt/etc/init.d/S28mihomo ] && [ ! -L /opt/etc/init.d/S28mihomo ]; then
  /opt/etc/init.d/S28mihomo status
elif [ -x /opt/etc/init.d/S99mihomo ] && [ ! -L /opt/etc/init.d/S99mihomo ]; then
  /opt/etc/init.d/S99mihomo status
else
  echo "ERROR: Mihomo init script not found or not executable" >&2
fi
```

**9. Обновить Mihomo**

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/update-mihomo.sh | sh
```

**10. Установить/обновить Web beta**

```sh
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/kas-web-install.sh | sh
```

[Режимы и подробности Web-панели](docs/26-kas-web-beta-install.md).


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
curl -fSsL -o /tmp/kas-remove-packages.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/uninstall-packages.sh && sh /tmp/kas-remove-packages.sh
```

YAML сохраняются. Настройки ProxyN, DNS, политик и Netfilter KeeneticOS не удаляются. Проверено в QEMU и на KN-1010.

## 8. Справочник

- [Полное HOWTO](docs/HOWTO_RU.md)
- [Энциклопедия / карта системы](docs/encyclopedia/00-karta-sistemy.md)
- [Roadmap](docs/10-roadmap.md)
- [CHANGELOG](CHANGELOG.md)
- [Лицензия](LICENSE)