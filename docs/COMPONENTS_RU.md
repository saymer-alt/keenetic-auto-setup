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
| Entware / OPKG, смонтированный в `/opt` | обязательная платформа | пакеты, init-скрипты, cron, Mihomo и MagiTrickle работают из `/opt` | `install.sh` сразу останавливается, если команды `opkg` нет |
| KeeneticOS **Клиент прокси / Proxy client** (`proxy`) | обязательный компонент KeeneticOS | создаёт интерфейс `ProxyN` — мост Keenetic → Mihomo | ранний read-only preflight через `show version`; после создания ProxyN остаётся проверка running-config |
| KeeneticOS **Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | обязательный компонент для поддерживаемого DNS-interception профиля | предоставляет семейство возможностей DNS filter/interception, на котором основан обязательный `dns-proxy intercept enable` | ранний read-only preflight через `show version`; затем команда включается и проверяется по running-config |
| KeeneticOS **Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | обязательный компонент для штатного VoIP bypass | `020-bypass-wa.sh` использует iptables mangle/MARK/CONNMARK/multiport и netfilter hook Keenetic | ранний read-only preflight через `show version`; фактическая установка правил остаётся runtime-проверкой |
| Интернет во время установки | обязательная install-time возможность | нужны загрузка пакетов, скриптов и актуального Mihomo ipk | ошибки download/opkg сообщает installer |
| Shell-доступ к Entware | обязательная возможность оператора, **не отдельный обязательный компонент KeeneticOS** | из shell запускаются installer/updater-команды | подойдёт любой административный способ получить нужный shell; компонент SSH server сам по себе не является runtime-зависимостью проекта |

## Аудит компонентов KeeneticOS

| Компонент KeeneticOS | Статус для проекта | Причина |
|---|---|---|
| **Клиент прокси / Proxy client** (`proxy`) | **ОБЯЗАТЕЛЕН** | создаёт ProxyN → SOCKS5/Mixed endpoint Mihomo на `127.0.0.1:7890` |
| **Поддержка открытых пакетов / OPKG** | **ОБЯЗАТЕЛЬНА** | весь runtime-стек проекта находится в Entware/`/opt` |
| **Модули ядра подсистемы Netfilter** (`opkg-kmod-netfilter`) | **ОБЯЗАТЕЛЬНЫ для штатного VoIP bypass** | нужны правилам `020-bypass-wa.sh` |
| **Фильтрация контента и блокировка рекламы при помощи облачных сервисов** (`dns-filter`) | **ОБЯЗАТЕЛЬНА для поддерживаемого DNS-interception профиля** | проект требует работающий `dns-proxy intercept enable`; выбирать сторонний сервис фильтрации для клиентов при этом не требуется |
| **Модули ядра Traffic Control** | **НЕ ТРЕБУЮТСЯ текущим кодом** | проект не использует `tc`, qdisc/class/filter |
| **Xtables-addons for Netfilter** | **НЕ ДОКАЗАНО / сейчас не требуется** | используются обычные mangle/MARK/CONNMARK/multiport без addon-specific target/match |
| **Модули поддержки файловых систем** | **УСЛОВНО** | нужны только если их требует выбранный носитель/ФС для Entware |
| **Поддержка накопителей** | **УСЛОВНО** | нужна для USB/NVMe-варианта; внутренняя Entware-установка не делает USB универсальным prerequisite |
| **ext filesystem + ext utilities** | **УСЛОВНО** | нужны, если выбранный диск использует ext |
| **SSH server** | **ОПЦИОНАЛЬНЫЙ способ администрирования** | удобен для shell, но runtime проекта от него не зависит |
| **DNS-over-TLS proxy** | **НАСТОЯТЕЛЬНО РЕКОМЕНДУЕТСЯ** | защищает upstream DNS роутера от простого наблюдения/подмены со стороны провайдера |
| **DNS-over-HTTPS proxy** | **НАСТОЯТЕЛЬНО РЕКОМЕНДУЕТСЯ** | та же эксплуатационная цель; DoH и DoT не обязаны быть включены одновременно |
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

Две важные границы:

1. **Установлено на известном рабочем роутере ≠ обязательно для проекта.**
2. **Обязательно для самого KeeneticOS ≠ обязательно для этого репозитория.**

## Обязательные возможности KeeneticOS

Помимо именованных компонентов проект использует возможности, для которых не нужно
выдумывать отдельный component ID без реального доказательства.

- **DNS proxy + transit interception** — `dns-proxy intercept enable`. Классические
  port-53 запросы клиентов должны проходить через DNS proxy Keenetic, чтобы MagiTrickle
  видел их и мог классифицировать маршруты. DoH/DoT — отдельный механизм.
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

- **DoH / DoT компоненты и серверы** — рекомендуемая эксплуатационная база, но не
  жёсткая зависимость installer. На whitelist-сетях фактическая доступность resolver'а
  важнее теории.
- **WireGuard / AmneziaWG / SSTP / OpenConnect / другие VPN-клиенты** — пользовательские
  выходы; ни один не обязателен для базовой установки.
- **Mihomo external Controller / Web UI** — опциональны.
- **Controller secret** — опционален в документированной доверенной LAN/VPN-модели;
  прямое открытие Controller в WAN/untrusted сеть выходит за эту модель.
- **TUN / `mitun0`** — создаётся только пользовательским Mihomo-конфигом, который
  включает TUN. Bootstrap-конфиг этого не требует.
- **Encrypted DNS на роутере** — эксплуатационный выбор, а не install prerequisite.

## Правило аудита компонентов

Если чистая реальная установка ломается из-за отсутствующей возможности KeeneticOS:

1. сохранить точное свидетельство ошибки;
2. определить минимальный недостающий component/capability;
3. заставить installer рано и понятно сообщать эту зависимость;
4. добавить маленькую постоянную regression/contract-проверку;
5. обновить этот документ и пользовательские prerequisites.

Сентябрьский live-тест 2026 года, который выявил отсутствие **Proxy client**, а затем
проверку полного набора `proxy` + `dns-filter` + `opkg-kmod-netfilter`, является
эталонным примером такого процесса.
