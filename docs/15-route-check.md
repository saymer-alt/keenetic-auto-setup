# mihomo-route-check.sh — точечная диагностика домена/IP

`mihomo-route-check.sh` — read-only helper для проверки одного домена, IP-адреса или URL через рабочую цепочку проекта.

Он нужен не вместо Doctor, а когда общий Doctor говорит, что стек в целом жив, но нужно понять: **может ли текущий Mihomo-путь достучаться до конкретной цели**.

## Запуск

До публикации в stable при разработке:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-route-check.sh -o /tmp/mihomo-route-check.sh && \
sh /tmp/mihomo-route-check.sh github.com
```

После промоута в production используйте `stable`:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-route-check.sh -o /tmp/mihomo-route-check.sh && \
sh /tmp/mihomo-route-check.sh github.com
```

Можно передать URL:

```bash
sh /tmp/mihomo-route-check.sh https://www.cloudflare.com/
```

или IP:

```bash
sh /tmp/mihomo-route-check.sh 1.1.1.1
```

## Что именно проверяется

Helper последовательно показывает:

1. **Target** — нормализованный host и URL пробного запроса.
2. **DNS** — резолв цели через доступный `nslookup`.
3. **Keenetic ProxyN** — read-only evidence из `show running-config`, включая поиск upstream `127.0.0.1:7890`.
4. **Local Mihomo endpoint** — слушается ли TCP-порт 7890.
5. **Current Mihomo selection** — текущая группа/выбранный узел через Controller `GET /proxies`.
6. **SOCKS5h target probe** — HTTP(S)-запрос к цели через `127.0.0.1:7890`.

## Что означает успешная SOCKS5h-проба

Успех подтверждает:

> Mihomo на этом роутере в текущем состоянии может обратиться к указанной цели через текущий proxy path.

Это полезно для различения ситуаций:

- локальный порт 7890 не работает;
- ProxyN не указывает на нужный endpoint;
- Controller жив, но выбранный upstream не даёт доступ;
- DNS не разрешает цель;
- сама цель отвечает через текущий Mihomo path.

## Что helper НЕ доказывает

Очень важно: успешная SOCKS5h-проба **не доказывает**, что конкретный LAN-клиент попал в ожидаемую политику Keenetic/MagiTrickle.

Helper запускается локально на роутере и проверяет Mihomo path напрямую.

Для проблем вида «на одном телефоне сайт идёт не туда» дополнительно нужны данные о:

- политике конкретного клиента;
- правилах MagiTrickle;
- DNS-классификации;
- состоянии соединения/conntrack;
- выбранном интерфейсе/политике Keenetic.

## Read-only контракт

Скрипт не:

- меняет proxy selection;
- делает PUT/DELETE в Controller;
- запускает delay tests;
- меняет `iptables`;
- меняет политики Keenetic;
- перезапускает Mihomo;
- правит DNS;
- пишет `config.yaml`.

Controller используется только для чтения `GET /proxies`.

## Controller secret

Если в Mihomo настроен `secret`, предпочтительно передать его через переменную окружения:

```bash
MIHOMO_API_SECRET='secret' sh /tmp/mihomo-route-check.sh github.com
```

Так secret не нужно встраивать в скрипт.

Также поддерживаются:

- `MIHOMO_CONTROLLER_URL` — по умолчанию `http://127.0.0.1:9090`;
- `MIHOMO_SOCKS_HOST` — по умолчанию `127.0.0.1`;
- `MIHOMO_SOCKS_PORT` — по умолчанию `7890`;
- `MIHOMO_PROXY_GROUP` — по умолчанию `GLOBAL`.

## Типичные результаты

### Всё работает

Ожидаются признаки:

```text
[OK] running-config contains a ProxyN path to 127.0.0.1:7890
[OK] TCP port 7890 is listening
Group: GLOBAL (...)
Selected: ...
[OK] SOCKS5h request reached the target path (HTTP ...)
```

### Порт 7890 закрыт

```text
[WARN] TCP port 7890 is not listening
```

Сначала запускайте общий [Doctor](08-troubleshooting.md), затем проверяйте состояние Mihomo.

### Controller требует secret

```text
[WARN] Controller requires a secret or the supplied secret was rejected
```

Это не означает автоматически, что proxy path сломан. Повторите запуск с `MIHOMO_API_SECRET`.

### SOCKS5h не получил HTTP-ответ

Это означает только, что проба не завершилась HTTP-ответом. Причиной может быть upstream, сама цель, TLS/DNS/маршрут или другой сетевой фактор.

Не используйте один WARN как автоматический диагноз причины.

## Почему это отдельный helper, а не ещё один раздел Doctor

Doctor отвечает на вопрос:

> здоров ли стек в целом?

`mihomo-route-check.sh` отвечает на более узкий вопрос:

> проходит ли сейчас конкретная цель через локальный Mihomo path?

Так Doctor остаётся общей быстрой read-only диагностикой и не превращается в тяжёлый трассировщик.
