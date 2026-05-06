# bypass_wa и 020-bypass_wa.sh

Как и зачем VoIP-трафик уходит мимо Mihomo.

---

## Задача

Обеспечить стабильную работу голосовых сервисов (Telegram, WhatsApp, WebRTC),
которые плохо работают через прокси (Mihomo / SOCKS5).

---

## Проблема

Mihomo — это TCP/HTTP прокси.

VoIP — это:
- UDP
- STUN/TURN
- быстрые соединения
- чувствительность к задержкам

Через прокси:
- звонки не устанавливаются
- либо есть сильный лаг
- либо отваливаются через 10–30 секунд

---

## Решение

Обойти Mihomo для VoIP-трафика:

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
VPN интерфейс (WireGuard / AWG / OpenVPN)

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
insmod xt_multiport.ko 2>/dev/null

👉 Для работы с несколькими портами

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

политика пустая
нет VPN интерфейса
скрипт не применился

Решение:

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


---
