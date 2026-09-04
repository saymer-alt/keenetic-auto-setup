

# Получаем текущий IP (откуда подключились)
CURRENT_SSH_IP=$(echo $SSH_CONNECTION | awk '{print $1}')
if [ -n "$CURRENT_SSH_IP" ] && [ "$CURRENT_SSH_IP" != "127.0.0.1" ]; then
    echo -e "${YELLOW}Твой текущий IP: $CURRENT_SSH_IP${NC}"
    read -p "Ограничить SSH только этим IP? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        # Находим порт SSH
        SSH_PORT=$(sudo ss -tulnp | grep sshd | head -1 | grep -oP ':\K\d+' | head -1)
        if [ -z "$SSH_PORT" ]; then
            SSH_PORT=22
        fi
        
        # Удаляем старые правила
        sudo ufw delete allow $SSH_PORT/tcp 2>/dev/null || true
        sudo ufw delete allow from any to any port $SSH_PORT 2>/dev/null || true
        
        # Добавляем правило только для текущего IP
        sudo ufw allow from $CURRENT_SSH_IP to any port $SSH_PORT proto tcp comment 'SSH'
        sudo ufw reload
        echo -e "${GREEN}✓ SSH ограничен IP: $CURRENT_SSH_IP${NC}"
    else
        echo -e "${YELLOW}⚠️ SSH остаётся открытым для всех${NC}"
    fi
else
    echo -e "${YELLOW}⚠️ Не удалось определить IP для ограничения SSH${NC}"
fi

# 7. Информация о mieru/mita
echo -e "\n${YELLOW}[Дополнительно] Проверка mita...${NC}"
if systemctl is-active --quiet mita; then
    echo -e "${GREEN}✓ Mita активен${NC}"
    echo "   Порты: $(sudo ss -tulnp | grep mita | grep LISTEN | awk '{print $5}' | cut -d: -f2 | sort -u | tr '\n' ' ')"
else
    echo -e "${RED}✗ Mita не запущен${NC}"
fi

echo -e "\n========================================="
echo -e "${GREEN}✅ Оптимизация завершена!${NC}"
echo "========================================="

# Показать итоговые правила UFW
echo -e "\n${YELLOW}Текущие правила UFW:${NC}"
sudo ufw status verbose | head -20

### Шаг 3: Сделай скрипт исполняемым

sudo chmod +x /root/optimize_mihomo.sh

### Шаг 4: Запусти на каждом сервере

sudo /root/optimize_mihomo.sh

---

## 📋 Что делает скрипт (проверь перед запуском)

| Действие | Проверка | Изменение |
|----------|----------|-----------|
| UFW outgoing | Если deny → меняет на allow | ✅ Безопасно |
| Телеметрия | Отключает Canonical-сбор данных | ✅ Безопасно |
| IPv6 | Если включён → отключает | ✅ Безопасно |
| Ping | Если разрешён → запрещает | ✅ Для скрытности |
| Сеть | Добавляет BBR, буферы | ✅ Ускоряет mieru |
| SSH | Спрашивает, ограничить ли твоим IP | ⚠️ Запросит подтверждение |

---

## 🎯 Ручной режим (если хочешь контролировать каждый шаг)

Если не хочешь запускать автоматический скрипт, вот минимальный набор команд для каждого сервера:

# 1. Исправить UFW (САМОЕ ВАЖНОЕ!)
sudo ufw default allow outgoing
sudo ufw reload

# 2. Отключить телеметрию
sudo systemctl disable --now ubuntu-advantage.service
sudo apt purge -y ubuntu-report popularity-contest whoopsie

# 3. Запретить ping
sudo sysctl -w net.ipv4.icmp_echo_ignore_all=1

# 4. Отключить IPv6
sudo sysctl -w net.ipv6.conf.all.disable_ipv6=1

# 5. Добавить оптимизации BBR
echo "net.core.default_qdisc = fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p

---

## 📝 Важно перед запуском на других серверах

1. Убедись, что у тебя есть доступ через VNC/консоль на случай, если что-то пойдёт не так
2. Скрипт не меняет порты mieru — они останутся как настроены
3. Если на сервере используется только IPv6 — не отключай его (скрипт проверит)

---

## 🔍 Проверка после оптимизации

На каждом сервере выполни:

# Быстрая проверка
sudo ufw status verbose | grep "Default:"
sysctl net.ipv4.icmp_echo_ignore_all
systemctl is-active mita

Ожидаемый результат:
Default: deny (incoming), allow (outgoing)  ← главное
net.ipv4.icmp_echo_ignore_all = 1          ← ping запрещён
active                                       ← mita работает

---

Хочешь, я сделаю ещё более простой вариант — однострочник, который можно просто скопировать и вставить на каждом сервере без создания файла?
