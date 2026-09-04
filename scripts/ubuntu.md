✅ Готовый полный гайд для второго VPS (чистый, без ошибок)

Скопируй и выполняй по пунктам на новом сервере (Ubuntu 24.04).  
Всё учтено: самоподписанный сертификат, права доступа, правильный tls-блок.

### 1. Установка Hysteria 2
bash <(curl -fsSL https://get.hy2.sh/)

### 2. Создаём сертификат под новый IP
Замени ВАШ_НОВЫЙ_IP на реальный внешний IP второго сервера!

sudo mkdir -p /etc/hysteria/certs

sudo openssl req -x509 -nodes -newkey rsa:2048 \
  -keyout /etc/hysteria/certs/private.key \
  -out /etc/hysteria/certs/cert.crt \
  -subj "/CN=ВАШ_НОВЫЙ_IP" \
  -addext "subjectAltName=IP:ВАШ_НОВЫЙ_IP" \
  -days 3650

### 3. Исправляем права доступа (это решало все прошлые ошибки)
sudo chown hysteria:hysteria /etc/hysteria/certs/*
sudo chmod 600 /etc/hysteria/certs/private.key
sudo chmod 644 /etc/hysteria/certs/cert.crt

### 4. Создаём конфиг
sudo nano /etc/hysteria/config.yaml

Полностью удали всё и вставь этот готовый конфиг:

listen: :2053                          # ← поменяй на любой свободный UDP-порт (например :8443 или :10025)

tls:
  cert: /etc/hysteria/certs/cert.crt
  key: /etc/hysteria/certs/private.key

auth:
  type: password
  password: "ТвойОченьСильныйПарольЗдесь2026!!!"   # ← придумай длинный

masquerade:
  type: proxy
  proxy:
    url: "https://ads.x5.ru"           # можно поменять на https://www.bing.com
    rewriteHost: true

quic:
  initStreamReceiveWindow: 8388608
  maxStreamReceiveWindow: 8388608
  initConnReceiveWindow: 20971520
  maxConnReceiveWindow: 20971520
  maxIdleTimeout: 60s

Сохрани: Ctrl + O → Enter → Ctrl + X

### 5. Открываем порт в firewall
sudo ufw allow 2053/udp          # ← поменяй 2053 на тот порт, который указал в конфиге
sudo ufw reload

### 6. Запускаем и добавляем в автозагрузку
sudo systemctl enable --now hysteria-server
sudo systemctl status hysteria-server

Должно быть зелёное active (running).

### 7. Готовая ссылка для клиента
hysteria2://ТвойПароль@ВАШ_НОВЫЙ_IP:2053/?insecure=1&sni=ads.x5.ru#Hysteria2-2

(Замени ТвойПароль, ВАШ_НОВЫЙ_IP и порт)

Готово!  
Если хочешь Salamander — скажи, добавлю его в этот же конфиг за 10 секунд.

Просто копируй команды по порядку на новом VPS и всё взлетит без ошибок.  
Если где-то выдаст ошибку — кинь сюда sudo systemctl status hysteria-server, сразу поправим.  

Удачи на втором сервере! 🚀
