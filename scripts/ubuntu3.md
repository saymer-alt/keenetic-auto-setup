Отлично! Я подготовил пошаговую инструкцию для настройки нового VPS с нуля. Выполняй команды по порядку — я объясню каждый шаг.

---

## 🔧 Пошаговая настройка нового VPS (Ubuntu 24.04 LTS)

> Перед началом: Убедись, что ты подключен к серверу по SSH под root или пользователем с sudo.

---

### Шаг 1: Первичное обновление системы

# Обновляем список пакетов и устанавливаем обновления
sudo apt update && sudo apt upgrade -y

# Устанавливаем базовые утилиты
sudo apt install -y curl wget git htop vim ufw fail2ban net-tools

---

### Шаг 2: Создание SWAP (файл подкачки)

# Проверяем текущую память
free -h

# Создаём swap-файл размером 1.5 ГБ (оптимально для 1 ГБ RAM)
sudo fallocate -l 1.5G /swapfile

# Если fallocate не работает, используй альтернативу:
# sudo dd if=/dev/zero of=/swapfile bs=1M count=1536 status=progress

# Устанавливаем правильные разрешения
sudo chmod 600 /swapfile

# Форматируем как swap
sudo mkswap /swapfile

# Активируем
sudo swapon /swapfile

# Добавляем в автозагрузку
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# Настраиваем swappiness (меньше использовать swap)
echo 'vm.swappiness = 10' | sudo tee -a /etc/sysctl.conf

# Проверяем результат
free -h

Ожидаемый результат: В строке Swap: должно быть 1.5Gi.

---

### Шаг 3: Настройка SSH (безопасность)

# Создаём резервную копию конфига
sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup

# Редактируем конфиг SSH
sudo nano /etc/ssh/sshd_config

Найди и измени следующие строки:
# Стандартный порт меняем на 2222
Port 2222

# Запрещаем вход root по паролю (только по ключу)
PermitRootLogin prohibit-password

# Запрещаем вход по паролю (ТОЛЬКО если у тебя уже добавлен SSH-ключ!)
PasswordAuthentication no

# Разрешаем вход по ключу
PubkeyAuthentication yes

# Скрываем баннер ОС
DebianBanner no

Сохрани и выйди (Ctrl+X, затем Y, затем Enter).

# На Ubuntu 24.04 перезапускаем SSH через socket
sudo systemctl restart ssh.socket

# ПРОВЕРКА: НЕ ЗАКРЫВАЙ ТЕКУЩУЮ СЕССИЮ!
# Открой второй терминал и проверь подключение по новому порту:
# ssh -p 2222 твой_юзер@IP_сервера

# Если подключение успешно — можно продолжать.

---

### Шаг 4: Настройка UFW (фаервол)

# Сбрасываем правила (на всякий случай)
sudo ufw --force reset

# Устанавливаем политики по умолчанию
sudo ufw default deny incoming
sudo ufw default allow outgoing

# Разрешаем НОВЫЙ порт SSH (2222)
sudo ufw allow 2222/tcp comment 'SSH'

# Разрешаем порты для сервисов (добавим позже, но базовые уже откроем)
sudo ufw allow 443/tcp comment 'TeleMT / HTTPS'
sudo ufw allow 80/tcp comment 'HTTP'

# Включаем фаервол
sudo ufw --force enable

# Проверяем статус
sudo ufw status verbose

Ожидаемый результат:
Status: active
...
2222/tcp              ALLOW IN    Anywhere   # SSH
443/tcp               ALLOW IN    Anywhere   # TeleMT / HTTPS
80/tcp                ALLOW IN    Anywhere   # HTTP

---

### Шаг 5: Настройка Fail2ban (защита от брутфорса)

# Копируем дефолтный конфиг в локальный
sudo cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local

# Редактируем настройки
sudo nano /etc/fail2ban/jail.local

Найди секцию `[sshd]` и приведи к виду:
[sshd]
enabled = true
port = 2222
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600

Сохрани и выйди.

# Запускаем fail2ban и добавляем в автозагрузку
sudo systemctl enable --now fail2ban

# Проверяем статус
sudo systemctl status fail2ban
sudo fail2ban-client status sshd

---

### Шаг 6: Оптимизация сетевого стека (sysctl)

# Создаём резервную копию
sudo cp /etc/sysctl.conf /etc/sysctl.conf.backup

# Открываем редактор
sudo nano /etc/sysctl.conf
