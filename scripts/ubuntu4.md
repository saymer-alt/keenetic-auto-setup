Понял, давай разбираться с доступом по SSH на порту 2222. Скорее всего, проблема в одном из нескольких мест. Поскольку ты сейчас на новом сервере, НЕ ЗАКРЫВАЙ ТЕКУЩУЮ SSH-СЕССИЮ, пока не решишь проблему!

Вот пошаговая диагностика:

---

## 🔍 Диагностика: почему порт 2222 не отвечает

### Шаг 1: Проверяем, слушает ли SSH порт 2222

# Проверяем, на каких портах висит SSH
sudo ss -tlnp | grep ssh

Что должно быть:
LISTEN 0  128  0.0.0.0:2222  0.0.0.0:*  users:(("sshd",pid=xxx,fd=xxx))
LISTEN 0  128     [::]:2222     [::]:*  users:(("sshd",pid=xxx,fd=xxx))

Если порт 2222 НЕ отображается:
- SSH не перезапустился корректно после изменения конфига.
- Переходи к Шагу 2.

Если порт 2222 ЕСТЬ, но не подключается:
- Проблема в фаерволе (UFW) или сетевых настройках.
- Переходи к Шагу 3.

---

### Шаг 2: Исправляем SSH (если не слушает 2222)

На Ubuntu 24.04 используется socket-based активация SSH, поэтому простого systemctl restart ssh недостаточно.

# Проверяем статус сокета
sudo systemctl status ssh.socket

# Проверяем, какой порт указан в конфиге сокета
sudo cat /lib/systemd/system/ssh.socket | grep ListenStream

Если порт в сокете — 22, а не 2222:

# Создаём override-конфиг для сокета
sudo mkdir -p /etc/systemd/system/ssh.socket.d
sudo nano /etc/systemd/system/ssh.socket.d/port.conf

Вставь содержимое:
[Socket]
ListenStream=
ListenStream=2222

Сохрани и выйди.

# Перезагружаем демон systemd и перезапускаем сокет
sudo systemctl daemon-reload
sudo systemctl restart ssh.socket

# Проверяем результат
sudo ss -tlnp | grep 2222

Если порт всё ещё не появился — проверь сам конфиг SSH:

# Убедись, что в /etc/ssh/sshd_config есть строка Port 2222
sudo grep "^Port" /etc/ssh/sshd_config

# Если нет — добавь
echo "Port 2222" | sudo tee -a /etc/ssh/sshd_config

# И перезапусти
sudo systemctl restart ssh.socket

---

### Шаг 3: Проверяем фаервол (UFW)

# Смотрим правила UFW
sudo ufw status verbose

Ожидаемый вывод:
2222/tcp              ALLOW IN    Anywhere
2222/tcp (v6)         ALLOW IN    Anywhere (v6)

Если правила нет — добавляем:

sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw reload

Если правило есть, но соединение всё равно не проходит — проверяем iptables напрямую:

# Смотрим правила iptables для INPUT цепочки
sudo iptables -L INPUT -n -v --line-numbers | grep -E "(2222|policy)"

Ожидаемый результат: Где-то должна быть строка с ACCEPT и dpt:2222.

Если UFW включен, но правила нет в iptables — сбрасываем и перезагружаем UFW:

sudo ufw disable
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 2222/tcp comment 'SSH'
sudo ufw allow 443/tcp comment 'HTTPS'
sudo ufw --force enable
sudo ufw status verbose

---

### Шаг 4: Проверяем, слушает ли сервер на ВНЕШНЕМ интерфейсе

Иногда SSH может слушать только 127.0.0.1 (localhost).

# Смотрим, на каком адресе висит порт
sudo ss -tlnp | grep 2222

Должно быть:
- 0.0.0.0:2222 — слушает на всех интерфейсах ✅
- 127.0.0.1:2222 — слушает только локально ❌

Если `127.0.0.1` — исправляем в `/etc/ssh/sshd_config`:

sudo nano /etc/ssh/sshd_config

Найди строку `ListenAddress` и либо закомментируй её, либо измени на:
#ListenAddress 0.0.0.0

Сохрани, выйди и перезапусти:
sudo systemctl restart ssh.socket

---

### Шаг 5: Временный быстрый фикс (если ничего не помогло)

Если срочно нужен доступ, а порт 2222 не заводится — временно верни порт 22:

# Открываем 22 порт в UFW
sudo ufw allow 22/tcp

# Временно разрешаем парольную аутентификацию (только для теста!)
sudo nano /etc/ssh/sshd_config
# Найди PasswordAuthentication и поставь yes
# Затем: sudo systemctl restart ssh.socket

# После подключения по 22 порту — реши проблему с 2222 и снова закрой 22:
# sudo ufw delete allow 22/tcp
# sudo nano /etc/ssh/sshd_config (верни PasswordAuthentication no)
# sudo systemctl restart ssh.socket

---

### Шаг 6: Финальная проверка подключения

С САМОГО СЕРВЕРА проверь, что порт доступен локально:

# Проверяем SSH локально
ssh -p 2222 localhost
# Должен появиться запрос пароля или сообщение "Permission denied" — это нормально, значит порт работает.
