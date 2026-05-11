# Ручное обновление Mihomo на ARM роутерах Keenetic + Entware

Актуально для:
- ARM / ARM64 роутеров
- Keenetic с Entware
- Mihomo уже установлен и работает

Проверено на:
- Keenetic ARM64 (aarch64)
- Entware
- Mihomo 1.19.x

---

# Что важно понимать

На ARM64 роутерах Keenetic официальный бинарник Mihomo из GitHub Releases обычно работает напрямую.

Поэтому:
- НЕ обязательно ждать сборку ipk-пакета
- НЕ обязательно собирать Mihomo из исходников
- НЕ обязательно делать свой пакет Entware

Достаточно:
1. скачать официальный ARM64 бинарник
2. заменить старый файл
3. перезапустить сервис

---

# Подключение к роутеру

Подключаемся по SSH:

```bash
ssh root@192.168.1.1
opkg update
opkg install wget-ssl
```


---

# Переходим во временную папку

```bash
cd /tmp
```

---

# Скачивание новой версии Mihomo

Пример для версии 1.19.24:

```bash
wget https://github.com/MetaCubeX/mihomo/releases/download/v1.19.24/mihomo-linux-arm64-v1.19.24.gz
```

Если выйдет новая версия:
- меняем номер версии в URL

Официальные релизы:
https://github.com/MetaCubeX/mihomo/releases

---

# Распаковка

```bash
gzip -d mihomo-linux-arm64-v1.19.24.gz
```

---

# Проверка запуска бинарника

Делаем исполняемым:

```bash
chmod +x mihomo-linux-arm64-v1.19.24
```

Проверяем запуск:

```bash
./mihomo-linux-arm64-v1.19.24 -v
```

Нормальный результат:

```text
Mihomo Meta v1.19.24 linux arm64 with go1.xx.x
```

Если версия вывелась:
- бинарник совместим
- архитектура подходит
- можно обновляться

---

# ВАЖНО: команда file может отсутствовать

На Keenetic/BusyBox часто нет команды:

```bash
file
```

Ошибка:

```text
-sh: file: not found
```

Это нормально.

Команда file НЕ обязательна.

---

# Поиск установленного Mihomo

На разных роутерах Mihomo может лежать:
- /opt/sbin/mihomo
- /opt/bin/mihomo
- /opt/usr/bin/mihomo

Поэтому сначала ищем:

```bash
which mihomo
```

Пример результата:

```bash
/opt/sbin/mihomo
```

---

# Создание backup

Если Mihomo лежит в:

```bash
/opt/sbin/mihomo
```

То делаем backup:

```bash
cp /opt/sbin/mihomo /opt/sbin/mihomo.backup
```

---

# Замена бинарника

```bash
mv /tmp/mihomo-linux-arm64-v1.19.24 /opt/sbin/mihomo
```

Выдаём права:

```bash
chmod +x /opt/sbin/mihomo
```

---

# Перезапуск сервиса

Обычно:

```bash
/opt/etc/init.d/S99mihomo restart
```

Если сервис называется иначе:

```bash
ls /opt/etc/init.d/
```

Ищем:
- S99mihomo
- S24mihomo
- или похожий скрипт

---

# Проверка после обновления

Проверка версии:

```bash
mihomo -v
```

Проверка процесса:

```bash
ps | grep mihomo
```

Нормально если видно:

```text
mihomo -d /opt/etc/mihomo
```

---

# Откат назад

Если новая версия не работает:

```bash
mv /opt/sbin/mihomo.backup /opt/sbin/mihomo
chmod +x /opt/sbin/mihomo
/opt/etc/init.d/S99mihomo restart
```

---

# Что НЕ нужно делать

Для ARM64 Keenetic обычно НЕ нужно:
- собирать из исходников
- ставить Go
- собирать ipk
- ждать пакет Entware
- пересобирать ядро
- использовать Docker

Официальный ARM64 бинарник обычно работает напрямую.

---

# Возможные проблемы

## 1. Permission denied

Решение:

```bash
chmod +x /opt/sbin/mihomo
```

---

## 2. No such file or directory

Обычно:
- неверный путь
- или Mihomo лежит не там

Проверяем:

```bash
which mihomo
```

---

## 3. Команда file отсутствует

Это нормально.

BusyBox часто не содержит file.

---

## 4. Сервис не стартует

Смотрим запуск вручную:

```bash
mihomo -d /opt/etc/mihomo
```

Чаще всего проблема:
- в config.yaml
- или изменился синтаксис новой версии

---

# Полезные команды

Текущая версия:

```bash
mihomo -v
```

Проверка процесса:

```bash
ps | grep mihomo
```

Проверка пути:

```bash
which mihomo
```

Просмотр init scripts:

```bash
ls /opt/etc/init.d/
```

---

# Итог

На ARM64 Keenetic обновление Mihomo обычно занимает:
- 2-5 минут
- без сборки
- без компиляции
- без ожидания Entware package

Достаточно заменить бинарник и перезапустить сервис.

