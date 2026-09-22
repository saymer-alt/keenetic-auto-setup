# Proxy Providers: подписки, health-check и обновление узлов

`proxy-providers` — механизм Mihomo для загрузки набора proxy-узлов из отдельного источника. Это удобно, когда список серверов меняется чаще основного `config.yaml`.

Официальная документация: <https://wiki.metacubex.one/en/config/proxy-providers/>.

## Чем provider отличается от `proxies`

Provider описывает источник набора:

~~~yaml
proxy-providers:
  my-sub:
    type: http
    url: "https://example.invalid/subscription"
    interval: 3600
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      lazy: true
~~~

Группа подключает его через `use`. Provider сам по себе трафик не маршрутизирует — он поставляет узлы группам.

## Типы provider

Актуальный Mihomo поддерживает `http`, `file` и `inline`. Для `http` нужен URL; локальный cache-path можно задавать отдельно.

## Три разных интервала

Не путайте:
1. `proxy-providers.<name>.interval` — когда скачать свежий список;
2. `health-check.interval` provider — когда проверить его узлы;
3. `proxy-groups.<name>.interval` — проверки/алгоритм самой группы.

## Health-check provider

Health-check — latency/availability test, а не Speedtest в Мбит/с. `lazy: true` особенно полезен на роутере: неиспользуемый provider не создаёт лишние постоянные проверки.

На слабом Keenetic бессмысленно ставить интервалы в несколько секунд: это дополнительные DNS/TLS/HTTP операции и CPU без практической выгоды.

## Нюанс `use`

Официальная документация отдельно отмечает: group health-check относится к списку `proxies` самой группы; provider-узлы из `use` имеют собственный provider health-check.

## `override`

Provider может переопределять свойства загруженных узлов: префикс/суффикс имени, UDP, TFO/MPTCP, `interface-name`, `dialer-proxy`, `ip-version` и другие поля.

Это мощно, но усложняет трассировку «откуда взялось фактическое значение», поэтому не стоит использовать override ради красоты.

## MetaCubeXD

Вкладка «Провайдеры прокси» умеет вручную обновить provider и запустить его health-check. Это меняет runtime-набор узлов, но не обновляет бинарник Mihomo и не заменяет основной `config.yaml`.

Разбор кнопок: [40-interfejs-metacubexd.md](40-interfejs-metacubexd.md).

## Subscription URL — секрет

URL подписки и custom headers могут содержать credential/token. Не коммитьте их в публичный репозиторий и не публикуйте provider-файл целиком без очистки.

## Статус в проекте

Bootstrap `keenetic-auto-setup` не создаёт proxy-providers. Это опциональная возможность пользовательского Mihomo-конфига; отдельный project-updater для provider не нужен — обновлением занимается само ядро.

## Куда идти дальше

- [28-proxies.md](28-proxies.md) — отдельные outbound-узлы.
- [29-proxy-groups.md](29-proxy-groups.md) — группы и `use`.
- [40-interfejs-metacubexd.md](40-interfejs-metacubexd.md) — provider UI.
- [44-logs.md](44-logs.md) — ошибки загрузки/health-check.
