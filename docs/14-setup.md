# setup.sh — простой мастер установки

`setup.sh` — рекомендуемая точка входа для обычной установки проекта на Keenetic с Entware.

Он не заменяет `install.sh` и не дублирует его safety-проверки. Его задача — определить тип хранения `/opt`, выбрать штатный профиль и передать управление каноническому installer, а после успешной установки открыть безопасный импорт конфигурации Mihomo.

## Обычный запуск

```bash
opkg update && opkg install curl && sh -c '
umask 077
f=$(mktemp /tmp/kas-bootstrap.XXXXXXXX) || exit 1
trap "rm -f $f" 0
valid() { [ -s "$f" ] && [ "$(head -n 1 "$f")" = "#!/bin/sh" ] &&
    grep -Fq "KAS_FIRSTFETCH_V1" "$f" && sh -n "$f"; }
fetch() { : > "$f" || return 1
    curl -fSsL --connect-timeout 7 --max-time 25 "$@" -o "$f" && valid; }
RAW=https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/bootstrap.sh
API="https://api.github.com/repos/saymer-alt/keenetic-auto-setup/contents/bootstrap.sh?ref=stable"
echo "[bootstrap] Downloading verified KAS launcher..."
if fetch "$RAW"; then
    echo "[bootstrap] GitHub raw OK"
elif fetch -4 --curves X25519 "$RAW"; then
    echo "[bootstrap] GitHub raw IPv4/X25519 OK"
elif fetch -4 -H "Accept: application/vnd.github.raw+json" -H "X-GitHub-Api-Version: 2022-11-28" "$API"; then
    echo "[bootstrap] GitHub Contents API OK"
else
    echo "[ERROR] No valid KAS launcher fetched; nothing executed" >&2
    exit 1
fi
sh "$f"
'
```

## Что делает мастер

Последовательность:

1. Проверяет наличие Entware/OPKG и `curl`.
2. Определяет, где расположен `/opt`.
3. Выбирает профиль:
   - внутреннее хранилище Keenetic → `ram`;
   - внешний persistent-накопитель → `disk`.
4. Скачивает `install.sh` из той же ветки проекта. Для дочерних project-скриптов используется цепочка доставки: raw GitHub через bounded normal `curl` → один compatibility retry `curl --curves X25519` → raw GitHub через `wget` → GitHub Contents API.
5. Каждый скачанный script-кандидат должен быть непустым, начинаться с `#!/bin/sh` и пройти `sh -n`.
6. Запускает `install.sh` с выбранным профилем.
7. После успешной установки тем же устойчивым способом скачивает и запускает `config-import.sh`.
8. В конце показывает команду запуска Doctor.

Начальная команда запуска теперь скачивает `bootstrap.sh` в закрытый временный файл и проверяет ненулевое содержимое, маркер и `sh -n` **до исполнения**, с bounded timeout и резервными вариантами IPv4/X25519 и GitHub Contents API. Сам `bootstrap.sh` безопасно скачивает `setup.sh` (raw → IPv4/X25519 → GitHub Contents API), проверяет project markers + shebang + `sh -n`, и только затем запускает `setup.sh`. Для дочерних project-managed файлов `setup.sh` сохраняет существующий bounded curl/wget/API fallback. Сетевые ошибки до этапа `opkg install curl` диагностируются отдельно, см. [подробную установку](03-install.md).

## Почему setup.sh не выбирает режим «на глаз»

Мастер читает фактический mount `/opt`.

Если `/opt` нельзя безопасно классифицировать, установка останавливается вместо предположения. Для необычных схем хранения используйте [расширенную установку](03-install.md).

`setup.sh` не обходит требования основного installer:

- RAM/swap policy;
- обязательные компоненты KeeneticOS;
- EXT4-only для нового внешнего `/opt`;
- требования `ext` и `ext-utils`;
- Proxy Client / ProxyN;
- DNS interception;
- one-Mihomo и остальные проверки проекта.

## Что происходит с существующей установкой

Повторный запуск рассчитан на безопасную повторяемость.

Если Mihomo уже установлен и рабочий бинарник/конфиг не требуют изменения, `install.sh` не должен бессмысленно переустанавливать Mihomo или перезапускать работающий сервис.

Существующие пользовательские `config.yaml` не должны перезаписываться установщиком.

## Импорт config.yaml после установки

После успешного installer `setup.sh` автоматически переходит к `config-import.sh`.

В интерактивной SSH-сессии:

1. создайте YAML в генераторе;
2. вставьте его целиком;
3. нажмите `Ctrl+D` один раз.

Если импорт пока не нужен, в приглашении importer можно ввести `s`.

Подробности: [безопасный импорт config.yaml](13-config-import.md).

Если мастер запущен без доступного интерактивного `/dev/tty`, импорт не запускается автоматически и выводится команда для ручного запуска позже.

## Веб-интерфейсы

MagiTrickle доступен после установки. MetaCubeXD становится доступен после импорта полноценного `config.yaml` из генератора, где настроен `external-controller`.

При стандартном LAN-IP:

```text
MetaCubeXD:   http://192.168.1.1:9090/ui/
MagiTrickle:  http://192.168.1.1:8080/
```

Если Config Import был пропущен через `s`, минимальный bootstrap сохраняет только обязательный `mixed-port: 7890`; порт 9090 в этом состоянии не ожидается.

Если у роутера другой LAN-IP, замените `192.168.1.1`.

Для первого входа в MetaCubeXD после импорта полного конфига используйте базовый путь `/ui/`, без hash-маршрута `#/overview`.

## Когда setup.sh не подходит

Используйте прямой `install.sh`, если требуется:

- явно выбрать `ram` или `disk`;
- использовать documented storage override;
- offline/SCP-сценарий;
- разбирать нестандартную схему хранения.

Подробности: [03 — установка](03-install.md).

## Диагностика после установки

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-doctor.sh | sh
```

Для проверки конкретного домена/IP используйте [mihomo-route-check.sh](15-route-check.md).

## Безопасность

`setup.sh` сам не форматирует накопители, не создаёт swap и не отключает safety-gates.

Не используйте ручные изменения `iptables`, ProxyN, DNS или policy routing как «продолжение setup.sh». Это отдельные advanced/risk-zone операции.

---

`setup.sh` и запущенный им installer используют единый «светофор» статусов. Полный контракт, включая `NO_COLOR` и поведение при редиректе: [18 — цвета и статусы CLI](18-output-colors.md).
