Привет! Отлично, что вы подготовили такой подробный контекст — это значительно ускорит настройку. 🎯

Я изучил текущее состояние S3 и вашу историю конфигураций. Давайте синхронизируемся.

---

## 📊 Текущее состояние сервера S3 (IP)

| Компонент | Статус | Примечания |
|-----------|--------|------------|
| ОС | ✅ Ubuntu 24.04.4 LTS | Kernel 6.8.0-110-generic |
| Доступ | ✅ SSH по ключу eddsa-key-20250925 | Порт 22, порт 2222 пока не настроен |
| Сеть | ✅ IPv4 + IPv6 | IP + IP |
| Firewall | ✅ UFW active | Только порт 22 открыт |
| Сервисы | ⚠️ Mihomo запущен | Слушает 127.0.0.1:7890 (только localhost) |
| Docker | ❌ Не установлен | Требуется для Amnezia AWG / MTProto |
| Мониторинг | ⚠️ fail2ban активен | 1635 неудачных попыток входа, 209 банов |
| Очистка | ✅ snapd отключён | Журналы очищены |

---

## 🗂 План воспроизведения вашей стандартной конфигурации

На основе вашего опыта предлагаю следующий порядок действий:

### 🔹 Этап 1: Базовая подготовка
# 1. Обновление системы
apt update && apt upgrade -y

# 2. Установка утилит
apt install -y curl wget git htop glances iftop nethogs fail2ban ufw

# 3. Создание SWAP (1.5 ГБ для 1 ГБ RAM)
fallocate -l 1.5G /swapfile && chmod 600 /swapfile
mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab

### 🔹 Этап 2: Безопасность
# 1. Смена порта SSH на 2222
sed -i 's/#Port 22/Port 2222/' /etc/ssh/sshd_config
systemctl restart ssh

# 2. Настройка UFW
ufw allow 2222/tcp && ufw allow 443/tcp && ufw allow 35443/udp
ufw --force enable

# 3. Fail2ban: защита SSH (порт 2222)
# В /etc/fail2ban/jail.local: [sshd] port = 2222
systemctl restart fail2ban

### 🔹 Этап 3: Сетевая оптимизация (sysctl)
# BBR + тюнинг под высокую нагрузку
cat >> /etc/sysctl.conf << 'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_tw_reuse = 1
net.core.somaxconn = 4096
vm.swappiness = 10
EOF
sysctl -p

### 🔹 Этап 4: Docker + сервисы
# Установка Docker
curl -fsSL https://get.docker.com | sh

# Запуск контейнеров (по необходимости):
# - amnezia-awg (WireGuard)
# - mtproto-proxy (Telegram)
# - mihomo (если нужен внешний доступ — настроить allow-lan: true)

### 🔹 Этап 5: Дополнительные настройки (по запросу)
- [ ] Скрыть SSH-баннер (DebianBanner no)
- [ ] Отключить ответ на ping (icmp_echo_ignore_all = 1)
- [ ] Настроить IPv6-маршрутизацию (WARP / WireGuard broker)
- [ ] Установить 3X-UI / MetaCubeXD для управления прокси

---

## ❓ Вопросы для уточнения

1. Какой основной сценарий для этого сервера?
   - Личный трафик (вы + семья)?
   - Раздача клиентам?
   - Тесты новых протоколов (Hysteria 2, TUIC)?

2. Какие сервисы приоритетны?
   - 🟢 Amnezia AWG (WireGuard)
   - 🟢 Mihomo (SOCKS5 + VLESS)
   - 🟢 MTProto для Telegram
   - 🟢 3X-UI веб-панель

3. Нужна ли поддержка IPv6 для клиентов? (если да — настроим WARP или broker)

4. Планируете ли веб-интерфейс (MetaCubeXD, Yacd) для управления?

---

## 🚀 С чего начнём?

Выберите вариант:
- A — Выполнить весь план по порядку (рекомендую)
- B — Только безопасность + Docker, остальное позже
- C — Сразу настроить конкретный сервис (укажите какой)
- D — Свой вариант

Жду ваших указаний, и погнали настраивать! 🛠
