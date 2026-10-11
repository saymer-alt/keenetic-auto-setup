# Протокол натурной приёмки WDTT

[Подготовка](README.md). Все строки пока NOT RUN на Keenetic. Отчёт: точная модель/ABI/kernel/Entware, SHA исходников/patch/Go/binary, режим account/anonymous, время, sanitized metrics; секреты и полный конфиг не прикладывать.

| Проверка | Команды/действие владельца после отдельного разрешения | Ожидаемое свидетельство |
|---|---|---|
| CPU/RAM idle/load 1/5/15 min | `top -b -n 1`; `/proc/PID/status` только VmRSS/VmHWM/Threads; `/proc/meminfo` | Нет OOM, bounded RSS/threads; сравнить с baseline, лимит ресурсов согласовать по preflight |
| MTU | Серии TCP downloads и UDP echo payload 64/512/1000/1200; отдельно 1280/1400; при наличии ping проверить поддерживаемые -M/-s, не предполагать их | Обе стороны считают bytes/hash; oversized failure объяснён, MTU не подбирать только mihomo -t |
| DNS | Явный SOCKS5h запрос к согласованному домену, `curl --socks5-hostname 127.0.0.1:17890 https://example.com/` | DNS обслуживается выбранным путём; системный resolver неизменён |
| TCP | Тот же curl плюс download фиксированного файла test server | Ответ и digest совпали, сервер видит ожидаемый egress |
| UDP | SOCKS5 UDP ASSOCIATE тестовым клиентом к управляемому UDP echo/DNS серверу | Двусторонний byte-for-byte echo, не TCP fallback |
| WireGuard handshake | На одноразовом сервере `wg show` только latest-handshakes/transfer, ключи не публиковать | Свежий handshake и рост counters коррелируют с тестом |
| Отсутствие утечки | На отдельном monitor/test server packet capture по целевому адресу во время транспорта UP и DOWN | Test destination не появляется напрямую на WAN; при DOWN приложение ошибается; обычный WAN baseline работает |
| Рекурсия | Внешние VK/auth/TURN/DNS/VPS соединения wt-client наблюдать с capture на изолированном WAN; сравнить route lookup для фактических relay IP | Внешний транспорт идёт WAN; локальный WG endpoint loopback; нет растущей самопетли. Один VPS bypass недостаточен |
| IPv6 | Отдельный `curl -6` через явно IPv6-capable PoC и capture | До отдельного допуска IPv6 выключен в PoC, отсутствие успешного запроса не доказывает отсутствие утечки на всей LAN |
| Restart/fatal | Неверный тестовый пароль, недоступный test relay, занятый UDP endpoint, SIGTERM | Fatal прекращает повторы; временные retries bounded/backoff; чужой процесс не остановлен |
| Логи | Synthetic canary в private config; stdout/stderr/status/diagnostic bundle проверяет локальный тест | Canary отсутствует; status содержит только фиксированные коды; никаких сырых response/cookies |
| Reboot | Только свободный стенд; reboot отдельно разрешить | Нет экспериментального autostart, KAS/Mihomo/DNS/WAN baseline восстановился; ручной повтор требует новых creds |
| Rollback/uninstall | Проверить предыдущий digest, собственный PID/exe и manifest, foreign sentinel рядом | Прошлый файл восстановлен атомарно; чужие файлы/процессы/интерфейсы сохранены |

Не выводить raw `wg show all dump`, `ps w`, process cmdline/environ, конфиги или Controller Authorization. Captures могут содержать чувствительные данные: хранить локально 0600, в отчёт переносить только согласованные счётчики/выводы. Leak test ограничен тестовым приложением, а не обещанием kill-switch для всей сети.
