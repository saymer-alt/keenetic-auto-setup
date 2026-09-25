# bypass_wa и 020-bypass_wa.sh

Как VoIP-трафик получает отдельный управляемый маршрут — в обход DNS-классификации MagiTrickle.

---

## Задача

Обеспечить стабильную работу голосовых сервисов (Telegram, WhatsApp, WebRTC),
которые плохо работают через прокси (Mihomo / SOCKS5).

---

## Проблема

VoIP — это:
- UDP
- STUN/TURN
- быстрые соединения
- чувствительность к задержкам

Если пустить звонки «по веб-пути» — через DNS-классификацию и прокси-цепочки,
не учитывающие UDP, — звонки:
- не устанавливаются
- либо есть сильный лаг
- либо отваливаются через 10–30 секунд

---

## Решение

Вывести VoIP-трафик из DNS-классификации MagiTrickle и дать ему отдельный
управляемый путь через политику Keenetic.

Основной сценарий — настраивается установщиком автоматически:

VoIP (UDP) → bypass_wa → проектный Proxy-интерфейс → 127.0.0.1:7890 (Mihomo) → правила Mihomo
Остальное → по правилам MagiTrickle

Альтернативный сценарий — ручная привязка:

VoIP (UDP) → bypass_wa → VPN напрямую
Остальное → Mihomo → Proxy

---

## Архитектура

LAN клиент
↓
PREROUTING (mangle)
↓
020-bypass_wa.sh
↓
MARK → bypass_wa policy
↓
проектный Proxy-интерфейс: ProxyN (description "mihomo t2sN", upstream 127.0.0.1:7890)
↓
Mihomo → правила Mihomo

Альтернатива (ручной permit): вместо ProxyN политика разрешает
VPN-интерфейс (WireGuard / AWG / OpenVPN) — трафик уходит в VPN напрямую.

---

## Автоматическая привязка политики (install.sh)

Установщик:

- создаёт политику `bypass_wa`, если её ещё нет, и находит её по description
  `bypass_wa` — имя политики роли не играет (например, `Policy0`);
- находит или создаёт проектный Proxy-интерфейс: `Proxy0`, а если он занят чужой
  конфигурацией — первый свободный `ProxyN`. Проектным считается интерфейс,
  у которого совпадают оба признака: description `mihomo t2sN` и upstream
  `127.0.0.1:7890`;
- добавляет в `bypass_wa` строку `permit global <ProxyN>`, если такого permit
  ещё нет.

Гарантии:

- существующие permits не удаляются и не переупорядочиваются — ручная привязка
  к VPN-интерфейсу остаётся рабочей альтернативой;
- политика не пересоздаётся;
- если политика отсутствует, привязка не создаёт её заново — установщик
  завершается с предупреждением (политику создаёт отдельный шаг установки).

---

## Почему именно netfilter.d

Файл размещается в:

/opt/etc/ndm/netfilter.d/020-bypass_wa.sh

Keenetic:
- сам вызывает его при каждом пересборе firewall
- после reboot
- после изменения интерфейсов
- после изменения конфигурации

👉 Это КЛЮЧЕВОЕ отличие от "разово прописать iptables"

---

## Обязательный Netfilter-компонент и `xt_multiport`

Штатный путь `020-bypass_wa.sh` требует KeeneticOS-компонент
**«Модули ядра подсистемы Netfilter»** (`opkg-kmod-netfilter`).
Для одного правила на набор UDP-портов скрипт использует match
`xt_multiport`, а затем цели `MARK`, `CONNMARK` и `RETURN`.

Отдельный компонент **Xtables-addons для Netfilter** проекту для этого пути
**не нужен**: `xt_multiport` был изолирован полевым A/B/C-тестом именно за
`opkg-kmod-netfilter`.

Важно: наличие самой policy `bypass_wa`, перехода из `PREROUTING` и даже
пустой цепочки `_CUST_BYPASS_WA_` ещё **не доказывает**, что bypass работает.
Рабочий runtime должен содержать внутри цепочки три правила для
`1400,3478,3482/udp`: `MARK`, `CONNMARK --save-mark` и `RETURN`.

### Полевой A/B/C-тест — KN-1010, KeeneticOS 5.1.6 stable, 25.09.2026

| Состояние | Наблюдение |
| --- | --- |
| A: `opkg-kmod-netfilter` установлен | `xt_multiport` загружен; `_CUST_BYPASS_WA_` содержит MARK/CONNMARK/RETURN; реальный трафик дал 30 пакетов / 4212 байт на всех трёх правилах |
| B: Netfilter modules и Xtables-addons удалены, затем reboot | Entware `iptables` и policy `bypass_wa` остались; `PREROUTING -> _CUST_BYPASS_WA_` остался; `xt_multiport` исчез; сама `_CUST_BYPASS_WA_` стала пустой |
| C: возвращён только `opkg-kmod-netfilter`, Xtables-addons оставлен выключенным, затем reboot | `xt_multiport` и все три правила MARK/CONNMARK/RETURN восстановились автоматически без повторного `install.sh` |

Вывод: `opkg-kmod-netfilter` — доказанный hard prerequisite текущего
VoIP-bypass пути, а Xtables-addons — нет. Doctor проверяет не только component
ID, но и фактическое содержимое runtime ruleset.

---

## Главный принцип: ИДЕМПОТЕНТНОСТЬ

Скрипт должен:
- выполняться много раз
- не ломать существующие правила
- не создавать дубликаты
- корректно переживать reload firewall

---

## Что делает скрипт

### 1. Проверяет контекст

```bash
[ "$type" = "ip6tables" ] && exit
[ "$table" != "mangle" ] && exit

👉 Не лезем в IPv6 и другие таблицы

2. Загружает модуль
```bash
modprobe xt_multiport 2>/dev/null || \
insmod /lib/modules/$(uname -r)/xt_multiport.ko 2>/dev/null
```

👉 `xt_multiport` предоставляет обязательный для этого пути компонент
`opkg-kmod-netfilter`; Xtables-addons не требуется.

3. Создаёт цепочку (без дубликатов)
iptables -w -t mangle -N _CUST_BYPASS_WA_ 2>/dev/null
iptables -w -t mangle -F _CUST_BYPASS_WA_

👉 Если уже есть — просто очищаем

4. Подключает цепочку
iptables -w -t mangle -C PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_ 2>/dev/null \
  || iptables -w -t mangle -A PREROUTING -m mark --mark 0x0 -j _CUST_BYPASS_WA_

👉 Не добавляем дубликаты

5. Маркирует VoIP трафик
ports="1400,3478,3482"

iptables -w -t mangle -A _CUST_BYPASS_WA_ \
  -p udp -m multiport --dports $ports \
  -j MARK --set-mark 0x$mark_id
6. Сохраняет метку
iptables -w -t mangle -A _CUST_BYPASS_WA_ -j CONNMARK --save-mark

👉 Ответный трафик идёт тем же маршрутом

Почему именно эти порты
Порт	Назначение
1400	Telegram (legacy voice)
3478	STUN (WebRTC, WhatsApp)
3482	WhatsApp voice
Важно

Это не "порты WhatsApp", а:
👉 инфраструктура WebRTC/VoIP

Проверка
Есть ли цепочка
iptables -t mangle -L | grep _CUST_BYPASS_WA_
Растут ли счётчики
iptables -t mangle -L _CUST_BYPASS_WA_ -v -n

👉 Во время звонка должны увеличиваться

Есть ли политика
ndmc -c "show ip policy bypass_wa"
Типичные проблемы
VoIP не работает

Причины:

у политики нет permits — нет выхода (в штатной установке permit добавляет
install.sh; пустая политика означает, что привязка не выполнилась или снята вручную)
проектный Proxy-интерфейс не найден (сработала защита чужого Proxy0 — привязка
пропущена, см. вывод установки)
Mihomo не запущен — цели 127.0.0.1:7890 нет
скрипт не применился

Проверка:

в самопроверке установки: [WARN] bypass_wa policy has no interface permit
маршрут через проектный Proxy: ndmc -c "show ip policy bypass_wa"

Решение:

повторный запуск install.sh (привязка идемпотентна)

или

/etc/init.d/netfilter restart

или

reboot
Цепочка есть, но трафик не идёт

Проверить:

iptables -t mangle -L _CUST_BYPASS_WA_ -v -n

👉 если счётчики 0 — трафик не попадает

Дубликаты правил

👉 Признак старого/кривого скрипта

Решение:

использовать текущую версию (с -C и -F)
Почему это "прошло через боль"
run-parts ненадёжен → используем netfilter.d
iptables может дублировать правила → проверки через -C
firewall пересобирается → скрипт должен быть повторяемым
разные прошивки Keenetic → минимальная зависимость от окружения
Можно ли расширить

Да:

ports="1400,3478,3482,10000:20000"

Но:
👉 увеличивается риск обхода прокси для лишнего трафика

Итог

020-bypass_wa.sh — это не просто "iptables-скрипт", а:

👉 устойчивый механизм интеграции с Keenetic firewall
👉 с учётом перезапусков, reload'ов и разных моделей
👉 который стабилизирует VoIP в реальных условиях
