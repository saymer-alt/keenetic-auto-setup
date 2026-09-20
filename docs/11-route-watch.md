# Mihomo Route Watch — какой proxy выбран сейчас

`mihomo-route-watch.sh` — **необязательный read-only helper** для Mihomo на Keenetic.

Его задача очень узкая: показать, **какой конечный proxy-сервер сейчас реально выбран цепочкой proxy-групп Mihomo**, и при необходимости наблюдать моменты failover/failback.

> В названии `route-watch` слово *route* означает цепочку выбора внутри Mihomo. Скрипт **не смотрит таблицы маршрутизации Keenetic/Linux** и ничего в них не меняет.

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
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-route-watch.sh \
  -o /tmp/mihomo-route-watch.sh
```

Посмотреть справку:

```bash
sh /tmp/mihomo-route-watch.sh --help
```

### Один раз показать выбранный сервер

```bash
sh /tmp/mihomo-route-watch.sh
```

По умолчанию стартовая группа — `GLOBAL`.

### Наблюдать переключения

```bash
sh /tmp/mihomo-route-watch.sh --watch 1
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
sh /tmp/mihomo-route-watch.sh -g "Primary"
```

или:

```bash
sh /tmp/mihomo-route-watch.sh -g "Primary" --watch 1
```

Кавычки нужны, если в имени группы есть пробелы.

### Controller на другом адресе

Например:

```bash
sh /tmp/mihomo-route-watch.sh -u http://192.168.1.1:9090
```

### Если у Controller есть secret

Безопаснее передать secret через переменную окружения, чтобы не писать его прямо в командной строке:

```bash
MIHOMO_API_SECRET='ваш_secret' sh /tmp/mihomo-route-watch.sh --watch 1
```

Параметр `-s SECRET` тоже поддерживается, но для постоянного использования переменная окружения предпочтительнее.

## Быстрый запуск без сохранения файла

Разовый просмотр:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-route-watch.sh | sh
```

Watch-режим:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-route-watch.sh | sh -s -- --watch 1
```

С secret:

```bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/mihomo-route-watch.sh \
  | MIHOMO_API_SECRET='ваш_secret' sh -s -- --watch 1
```

Для человека, которому инструмент даётся впервые, вариант **«скачать в /tmp → --help → запустить»** обычно понятнее, чем `curl | sh`.

## Типовые ошибки

### Controller unreachable

```text
[route-watch] controller unreachable ...
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

`mihomo-route-watch.sh` отвечает на другой вопрос:

> **«Какой proxy Mihomo выбрал прямо сейчас и когда этот выбор изменился?»**

Оба инструмента read-only, но задачи у них разные.
