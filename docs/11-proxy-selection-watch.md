# Mihomo Proxy Selection Watch — какой proxy выбран сейчас

`mihomo-proxy-selection-watch.sh` — **необязательный read-only helper** для Mihomo на Keenetic.

Его задача очень узкая: показать, **какой конечный proxy-сервер сейчас реально выбран цепочкой proxy-групп Mihomo**, и при необходимости наблюдать моменты failover/failback.

> Скрипт наблюдает именно за выбором proxy внутри Mihomo. Он **не смотрит таблицы маршрутизации Keenetic/Linux** и ничего в них не меняет.

## Что он показывает

Допустим, конфигурация Mihomo устроена так:

```text
GLOBAL
  ↓
Primary
  ↓
Sweden-1
```

Скрипт выведет:

```text
GLOBAL -> Primary -> Sweden-1
CURRENT SERVER: Sweden-1
```

Он понимает вложенные группы `Selector`, `URLTest`, `Fallback`, `Relay`. Для `LoadBalance` одного выбранного сервера нет, поэтому он честно пишет `load-balanced`.

Это удобно, когда нужно проверить:

- на каком сервере Mihomo находится прямо сейчас;
- действительно ли `Fallback` переключился на резерв;
- через сколько секунд произошёл failover;
- когда Mihomo вернулся на более приоритетный сервер;
- куда в итоге разрешилась длинная цепочка вложенных групп.

## Что он НЕ делает

Скрипт строго read-only. Единственный HTTP-запрос — `GET /proxies` Controller API.

Он **не**:

- выбирает proxy;
- запускает delay-test;
- меняет `config.yaml`;
- перезапускает Mihomo;
- меняет маршрутизацию Keenetic;
- влияет на failover/failback.

Поэтому сам факт наблюдения не меняет поведение Mihomo.

## Что нужно

На устройстве должны быть:

- работающий Mihomo;
- включённый и доступный Controller (`external-controller`);
- `curl`;
- `jq`.

По умолчанию helper обращается к:

```text
http://127.0.0.1:9090
```

Это **дефолт helper'а**, а не встроенный дефолт Mihomo. Если Controller слушает другой адрес, передайте его через `-u`.

## Самый понятный способ запуска

Подключитесь по SSH к Keenetic/Entware и скачайте скрипт во временный каталог:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh \
  -o /tmp/mihomo-proxy-selection-watch.sh
```

Посмотреть справку:

```bash
sh /tmp/mihomo-proxy-selection-watch.sh --help
```

### Один раз показать выбранный сервер

```bash
sh /tmp/mihomo-proxy-selection-watch.sh
```

По умолчанию стартовая группа — `GLOBAL`.

### Наблюдать переключения

```bash
sh /tmp/mihomo-proxy-selection-watch.sh --watch 1
```

Скрипт опрашивает Controller раз в секунду, но **печатает строку только когда состояние изменилось**. Остановить — `Ctrl+C`.

Пример:

```text
14:22:01 GLOBAL -> Primary -> Sweden-1 | CURRENT SERVER: Sweden-1
14:23:17 GLOBAL -> Primary -> Estonia-1 | CURRENT SERVER: Estonia-1
14:25:42 GLOBAL -> Primary -> Sweden-1 | CURRENT SERVER: Sweden-1
```

По этим отметкам времени видно failover и последующий failback.

### Смотреть не GLOBAL, а конкретную группу

```bash
sh /tmp/mihomo-proxy-selection-watch.sh -g "Primary"
```

или:

```bash
sh /tmp/mihomo-proxy-selection-watch.sh -g "Primary" --watch 1
```

Кавычки нужны, если в имени группы есть пробелы.

### Controller на другом адресе

Например:

```bash
sh /tmp/mihomo-proxy-selection-watch.sh -u http://192.168.1.1:9090
```

### Если у Controller есть secret

Безопаснее передать secret через переменную окружения, чтобы не писать его прямо в командной строке:

```bash
MIHOMO_API_SECRET='ваш_secret' sh /tmp/mihomo-proxy-selection-watch.sh --watch 1
```

Параметр `-s SECRET` тоже поддерживается, но для постоянного использования переменная окружения предпочтительнее.

## Быстрый запуск без сохранения файла

Разовый просмотр:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh
```

Watch-режим:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh | sh -s -- --watch 1
```

С secret:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/mihomo-proxy-selection-watch.sh \
  | MIHOMO_API_SECRET='ваш_secret' sh -s -- --watch 1
```

Для человека, которому инструмент даётся впервые, вариант **«скачать в /tmp → --help → запустить»** обычно понятнее, чем `curl | sh`.


### Конечная серия наблюдений (v1.3, после принятия PR)

Чтобы выполнить шесть опросов Controller раз в секунду и завершить работу без фонового демона:

```sh
sh /tmp/mihomo-proxy-selection-watch.sh --watch 1 --samples 6
```

Флаг `--samples` действует только вместе с `--watch`; от 1 до 30 опросов, суммарное ожидание не более 300 секунд. Обычный `--watch 1` сохраняет прежнее поведение до Ctrl+C. Каждый опрос по-прежнему использует **только GET /proxies**. В конце скрипт печатает сводку: `polls`, `observed`, `incomplete`, `leaf-changes`, `direct-observed`, `load-balanced`. Если один или несколько снимков недоступны/некорректны, результат **INCONCLUSIVE**, код 6. Ошибки авторизации/группы/цикла сохраняют предыдущие коды.

### Повреждённый снимок Controller — это не «группа не найдена»

Начиная с v1.3.1 тело ответа с HTTP 200 проверяется строже: `.proxies` должно быть JSON-объектом. Если ответ — не корректный JSON вообще, либо `.proxies` отсутствует или не является объектом (`null`, `[]`, строка), снимок считается **повреждённым**:

- в режиме `--samples` такой опрос засчитывается как `incomplete`, и серия честно завершается **INCONCLUSIVE, код 6** — даже если остальные опросы прошли успешно;
- в one-shot режиме скрипт сообщает о некорректном/непригодном ответе Controller (код 5), а не «start group not found» (код 4): пустой или повреждённый объект не является доказательством отсутствия группы.

Пустой, но валидный объект `.proxies` (например `{}`) остаётся легитимным снимком: отсутствие в нём стартовой группы — по-прежнему код 4.

**Граница доказательности:** `leaf-changes=0` означает только отсутствие замеченных смен выбранного узла в опрошенные моменты времени. Переключение между опросами могло остаться незамеченным. `direct-observed=0` не исключает обходной маршрут Keenetic, MagiTrickle, DNS/IPv6 или браузера; `load-balanced>0` означает, что выбор может зависеть от отдельного соединения. Успешный код 0 **не** доказывает стабильный внешний IP. Для фактического egress используйте отдельный Network Doctor и проверку на клиенте. Имена узлов в обычном выводе могут быть приватными; перед публикацией логов их необходимо очистить.

## Типовые ошибки

### Controller unreachable

```text
[proxy-selection-watch] controller unreachable ...
```

Проверьте, включён ли `external-controller` и правильно ли указан адрес через `-u`.

### HTTP 401 / 403

Controller требует secret или secret указан неверно. Передайте правильный `MIHOMO_API_SECRET`.

### start group not found

Группы с таким именем нет в `/proxies`. Проверьте имя и регистр или запустите без `-g`, чтобы начать с `GLOBAL`.

### load-balanced

Это не ошибка. У `LoadBalance` по определению нет одного постоянного leaf-сервера: выбор может происходить для отдельных соединений.

## Чем отличается от Doctor

`mihomo-doctor.sh` отвечает примерно на вопрос:

> **«Здоров ли установленный стек и что в нём сломано?»**

`mihomo-proxy-selection-watch.sh` отвечает на другой вопрос:

> **«Какой proxy Mihomo выбрал прямо сейчас и когда этот выбор изменился?»**

Оба инструмента read-only, но задачи у них разные.
