# Компоненты KeeneticOS и prerequisites

[English](COMPONENTS.md)

Этот документ фиксирует install-time контракт `keenetic-auto-setup`: что действительно
нужно проекту до установки, какие возможности KeeneticOS обязательны и какие компоненты
являются лишь опциональными или зависят от конкретной схемы.

Главное правило: **то, что установлено на одном рабочем роутере, не становится
автоматически обязательным компонентом проекта.**

## Обязательно до установки

| Что | Класс | Зачем нужно | Как проверяется |
|---|---|---|---|
| Entware / OPKG, смонтированный в `/opt` | обязательная платформа | пакеты, init-скрипты, cron, Mihomo и MagiTrickle работают из `/opt`; если `/opt` внешний, поддерживаемый проектом профиль — только EXT4 | `install.sh` проверяет наличие `opkg`, класс хранилища и реальную ФС `/opt` по `/proc/mounts`; внешний не-EXT4 останавливает новую установку |
| KeeneticOS **Клиент прокси / Proxy client** (`proxy`) | обязательный компонент KeeneticOS | создаёт интерфейс `ProxyN` — мост Keenetic → Mihomo | ранний read-only preflight через `show version`; после создания ProxyN остаётся проверка running-config |
| KeeneticOS **Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | обязательный компонент для поддерживаемого DNS-interception профиля | предоставляет семейство возможностей DNS filter/interception, на котором основан обязательный `dns-proxy intercept enable` | installer жёстко требует component ID после нормализации переносов `show version`; Doctor на legacy-системе дополнительно сопоставляет реальное отсутствие ID с фактическим `dns-proxy intercept enable`: live capability → profile-drift WARN, отсутствие capability → FAIL |
| KeeneticOS **Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | обязательный компонент для штатного VoIP bypass | предоставляет `xt_multiport`, без которого `020-bypass-wa.sh` не может установить свои UDP multiport MARK/CONNMARK/RETURN правила; A/B/C-тест KN-1010/5.1.6 это воспроизвёл после reboot | installer жёстко требует component ID после нормализации переносов `show version`; Doctor на legacy-системе дополнительно проверяет фактические `_CUST_BYPASS_WA_` rules: live rules → profile-drift WARN, сломанный runtime path → FAIL |
| KeeneticOS **DNS-over-TLS proxy** (`dns-tls`) **ИЛИ DNS-over-HTTPS proxy** (`dns-https`) | **обязателен хотя бы один из двух** | официальный гайд Keenetic для Proxy Client предупреждает, что доступ через proxy может работать некорректно без DoT/DoH, и рекомендует включить DoT или DoH для надёжной работы | installer проверяет OR-контракт через `show version`; Doctor зеркально FAIL'ит отсутствие обоих |
| KeeneticOS **Файловая система Ext** (`ext`) | **обязателен при внешнем `/opt`** | поддерживаемый внешний Entware-профиль проекта — EXT4 | при внешнем `/opt` ранний read-only preflight требует component id `ext` |
| KeeneticOS **Утилиты EXT4** (`ext-utils`) | **обязательны при внешнем `/opt`** | дают штатные средства проверки/исправления EXT4; в KeeneticOS 5.1 проверка накопителя доступна через Storage & Devices/CLI при наличии filesystem utilities | при внешнем `/opt` ранний read-only preflight требует component id `ext-utils` |
| Интернет во время установки | обязательная install-time возможность | нужны загрузка пакетов, скриптов и актуального Mihomo ipk | ошибки download/opkg сообщает installer |
| Shell-доступ к Entware | обязательная возможность оператора, **не отдельный обязательный компонент KeeneticOS** | из shell запускаются installer/updater-команды | подойдёт любой административный способ получить нужный shell; компонент SSH server сам по себе не является runtime-зависимостью проекта |

## Аудит компонентов KeeneticOS

> **Важно про парсинг `show version`.** Human-readable CLI не является стабильным построчным API. Ещё 19.09.2026 на домашнем Netcraze Ultra NC-1812 / KeeneticOS 5.1.5 был виден тот же класс форматирования: component ID мог разрываться внутри имени между физическими строками (например `ike-` + `client`). Тогда это посчитали безобидным переносом и не превратили в regression — это был пропущенный ранний сигнал. 25.09.2026 KN-3811 / 5.1.5 и 5.1.6 показал уже практический ущерб: `dns-` + `filter` и `opkg-kmod-` + `netfilter` давали ложный «missing» при построчном поиске. Installer и Doctor теперь нормализуют **только логическое поле `components:`**, останавливаются на следующем поле и затем проверяют точные comma-delimited ID. Permanent regression разрывает каждый обязательный component ID во всех возможных внутренних позициях. Нельзя переносить эту технику на весь `show running-config`, `/proc/mounts`, `/proc/swaps` или `opkg list-installed`: там физическая строка является семантической записью/командой. Неполный или неубедительный вывод должен становиться UNKNOWN/UNVERIFIED, а не доказательством отсутствия. Для действительно legacy-систем Doctor отдельно различает profile compliance и доказанную runtime-capability.

| Компонент KeeneticOS | Статус для проекта | Причина |
|---|---|---|
| **Клиент прокси / Proxy client** (`proxy`) | **ОБЯЗАТЕЛЕН** | создаёт ProxyN → SOCKS5/Mixed endpoint Mihomo на `127.0.0.1:7890` |
| **Поддержка открытых пакетов / OPKG** | **ОБЯЗАТЕЛЬНА** | весь runtime-стек проекта находится в Entware/`/opt` |
| **Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | **ОБЯЗАТЕЛЬНЫ для штатного VoIP bypass** | дают `xt_multiport`; без него после reboot цепочка `_CUST_BYPASS_WA_` может существовать, но остаётся пустой и не маркирует трафик |
| **Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | **ОБЯЗАТЕЛЬНА для поддерживаемого DNS-interception профиля** | проект требует работающий `dns-proxy intercept enable`; выбирать сторонний сервис фильтрации для клиентов при этом не требуется |
| **Модули ядра Traffic Control** | **НЕ ТРЕБУЮТСЯ текущим кодом** | проект не использует `tc`, qdisc/class/filter |
| **Пакет расширения Xtables-addons для Netfilter** | **НЕ ТРЕБУЕТСЯ текущему bypass** | C-тест KN-1010/5.1.6 восстановил `xt_multiport` и все правила `_CUST_BYPASS_WA_` при установленном только `opkg-kmod-netfilter`; Xtables-addons оставался выключен |
| **Модули поддержки файловых систем** | **УСЛОВНО** | нужны платформе в зависимости от выбранного носителя; это не заменяет отдельный проектный контракт EXT4 для внешнего `/opt` |
| **Поддержка накопителей** | **УСЛОВНО** | нужна для USB/NVMe-варианта; внутренняя Entware-установка не делает USB универсальным prerequisite |
| **Файловая система Ext** (`ext`) + **Утилиты EXT4** (`ext-utils`) | **ОБЯЗАТЕЛЬНЫ для внешнего Entware `/opt`** | проект сознательно поддерживает внешний `/opt` только на EXT4; `ext-utils` обеспечивает штатную проверку/исправление файловой системы |
| **SSH server** | **ОПЦИОНАЛЬНЫЙ способ администрирования** | удобен для shell, но runtime проекта от него не зависит |
| **DNS-over-TLS proxy** (`dns-tls`) | **ОДИН ИЗ `dns-tls` / `dns-https` ОБЯЗАТЕЛЕН** | Keenetic рекомендует DoT/DoH для надёжного Internet access через Proxy Client; второй secure-DNS компонент не обязателен |
| **DNS-over-HTTPS proxy** (`dns-https`) | **ОДИН ИЗ `dns-tls` / `dns-https` ОБЯЗАТЕЛЕН** | тот же Proxy Client contract; проект намеренно проверяет OR, а не требует оба компонента |
| **Internet connection status monitoring / Ping Check** | **РЕКОМЕНДУЕТСЯ** | полезен для штатной WAN/failover-диагностики Keenetic, хотя watchdog проекта использует собственные проверки |
| **Traffic classification engine** | **РЕКОМЕНДУЕТСЯ** | полезен для наблюдаемости, но код проекта его не вызывает |
| **Packet capture** | **РЕКОМЕНДУЕТСЯ для диагностики** | помогает доказать DNS/routing/VPN поведение пакетами |
| **iPerf3** | **РЕКОМЕНДУЕТСЯ для диагностики** | удобен для повторяемых throughput/path тестов |
| **DDNS / KeenDNS-related service** | **РЕКОМЕНДУЕТСЯ для управляемого удалённого доступа** | не нужен самому маршруту трафика, но полезен для администрирования |
| **mDNS service** | **НЕ ТРЕБУЕТСЯ проектом** | текущий код от него не зависит |
| **Wi‑Fi controller, cloud/mobile agents, shaper, DHCP, Wi‑Fi/USB interfaces** | **ФУНКЦИИ ПЛАТФОРМЫ, не prerequisites проекта** | могут быть обязательны самому KeeneticOS или конкретной конфигурации |
| **PPTP/L2TP/SSTP/OpenVPN/WireGuard/IPsec/OpenConnect/ZeroTier clients/servers** | **ОПЦИОНАЛЬНО / зависит от топологии** | любой из них может быть пользовательским exit, но ни одна технология не обязательна универсально |
| **PPPoE/802.1X, EoIP/GRE/IP-IP, VRRP, ALGs, NetFlow, UPnP, udpxy, SNMP, captive portal** | **НЕ ТРЕБУЮТСЯ** | текущий install/runtime путь от них не зависит |
| **USB modem/serial/CDC/NDIS/QMI modules** | **УСЛОВНО** | нужны только если конкретный WAN использует такой модем |
| **SMB/DLNA/Transmission/FTP/SFTP/WebDAV/folder ACL** | **НЕ ТРЕБУЮТСЯ** | это приложения хранения, не часть runtime проекта |

### Контракт внешнего хранилища

Для `/opt` на USB/NVMe проект поддерживает **только EXT4**. Современный KeeneticOS может технически монтировать и использовать другие файловые системы, а отдельные версии OPKG допускают дополнительные варианты, но это не означает, что они входят в поддерживаемый профиль `keenetic-auto-setup`. NTFS, exFAT, FAT и другие ФС для внешнего `/opt` проект намеренно отклоняет на новой установке.

Это соответствует актуальной инструкции Keenetic по OPKG, где для USB-накопителя требуется Ext и рекомендуется журналируемая EXT4: <https://support.keenetic.com/hero-dsl/kn-2410/en/18481-opkg.html>.

На внешнем `/opt` обязательны component id `ext` и `ext-utils`. Начиная с KeeneticOS 5.1 штатный раздел Storage & Devices умеет запускать проверку файловой системы при наличии соответствующих filesystem utilities: <https://support.keenetic.com/hero-4g-plus/kn-2311/en/44933-managing-usb-drives-in-the-web-interface.html>. Проект **не утверждает**, что Keenetic автоматически выполняет fsck при каждом включении: подтверждён именно штатный механизм запуска проверки/исправления. Installer и Doctor сами файловую систему не исправляют и тем более не форматируют.

Две важные границы:

1. **Установлено на известном рабочем роутере ≠ обязательно для проекта.**
2. **Обязательно для самого KeeneticOS ≠ обязательно для этого репозитория.**

Официальное основание secure-DNS prerequisite: Keenetic Proxy Client предупреждает, что доступ к интернет-ресурсам через proxy может работать некорректно без DoT/DoH, и для надёжной работы рекомендует включить DNS-over-TLS или DNS-over-HTTPS: <https://support.keenetic.com/peak/kn-2710/en/49443-proxy-client.html>.

## Обязательные возможности KeeneticOS

Помимо именованных компонентов проект использует возможности, для которых не нужно
выдумывать отдельный component ID без реального доказательства.

- **DNS proxy + transit interception** — `dns-proxy intercept enable`. Классические
  port-53 запросы клиентов должны проходить через DNS proxy Keenetic, чтобы MagiTrickle
  видел их и мог классифицировать маршруты. В web UI это соответствует состоянию,
  когда **транзитные DNS-запросы запрещены/блокируются**: галочка, разрешающая DNS-транзит,
  должна быть снята. CLI при этом показывает `intercept enable`. DoH/DoT — отдельный механизм.
- **IP policy routing** — используется политикой `bypass_wa` и её выходами.
- **Keenetic/Entware netfilter hook** —
  `/opt/etc/ndm/netfilter.d/020-bypass_wa.sh` устанавливает VoIP marking rules при
  перестроении firewall Keenetic.
- **Сохранение конфигурации** — project-owned изменения Keenetic фиксируются через
  `system configuration save`.

Если на конкретной прошивке/наборе компонентов такой capability отсутствует, это
совместимость, которую нужно подтвердить реальным выводом устройства, а не угадывать по
названию компонента.

## Что installer ставит через Entware

`install.sh` обеспечивает наличие `ca-bundle`, `curl`, `jq`, `nano`, `cron`;
устанавливает Mihomo из release sibling-репозитория `saymer-alt/entware-go` с Entware
feed как последним fallback; добавляет репозиторий MagiTrickle и устанавливает сам
MagiTrickle.

Это **не компоненты KeeneticOS**.

## Условное и опциональное

- **Выбор конкретного DoT/DoH upstream и второго secure-DNS компонента** остаётся
  эксплуатационным выбором. Но сам supported ProxyN profile теперь требует наличие
  **хотя бы одного** компонента `dns-tls` / `dns-https`. Installer не навязывает
  конкретный resolver: на whitelist-сетях его фактическая доступность важнее теории.
- **WireGuard / AmneziaWG / SSTP / OpenConnect / другие VPN-клиенты** — пользовательские
  выходы; ни один не обязателен для базовой установки.
- **Mihomo external Controller / Web UI** — опциональны.
- **Controller secret** — опционален в документированной доверенной LAN/VPN-модели;
  прямое открытие Controller в WAN/untrusted сеть выходит за эту модель.
- **TUN / `mitun0`** — создаётся только пользовательским Mihomo-конфигом, который
  включает TUN. Bootstrap-конфиг этого не требует.
- **Конкретный encrypted-DNS upstream/resolver** — эксплуатационный выбор. Это не отменяет install prerequisite проекта: для поддерживаемого ProxyN-профиля обязателен хотя бы один компонент `dns-tls` / `dns-https`; второй компонент и конкретный resolver остаются на выбор оператора.

## Правило аудита компонентов

Если чистая реальная установка ломается из-за отсутствующей возможности KeeneticOS:

1. сохранить точное свидетельство ошибки;
2. определить минимальный недостающий component/capability;
3. заставить installer рано и понятно сообщать эту зависимость;
4. добавить маленькую постоянную regression/contract-проверку;
5. обновить этот документ и пользовательские prerequisites.

Сентябрьский live-тест 2026 года, который выявил отсутствие **Proxy client**, а затем
последовательное уточнение текущего контракта (`proxy` + `dns-filter` +
`opkg-kmod-netfilter`, secure-DNS OR `dns-tls`/`dns-https`, а для внешнего `/opt` ещё
`ext` + `ext-utils`), является эталонным примером такого процесса.
