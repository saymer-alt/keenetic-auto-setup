# Полевое наблюдение: первый Doctor после установки и готовность Netfilter (Hopper, 14.10.2026)

**Состояние:** расследование / NEEDS REPRO. Это документация для [KAS #144](https://github.com/saymer-alt/keenetic-auto-setup/issues/144), **не исправление Doctor и не новая гарантия готовности**. В ходе подготовки документа исполняемые скрипты, маршруты и правила Netfilter не изменялись.

## Наблюдение пользователя

Пользователь сменил накопитель Entware на Keenetic Hopper, заново установил KAS и успешно воспользовался импортом конфига прямо через терминал. Вскоре после установки первый Mihomo Doctor сообщил:

```text
===== 7. Keenetic proxy bridge (ProxyN) =====
[FAIL] bypass_wa Netfilter chain missing: _CUST_BYPASS_WA_
```

Позднейший ручной просмотр Netfilter показал, что `_CUST_BYPASS_WA_` существует, связана с `mangle/PREROUTING`, и её счётчик достиг **5 пакетов**. Через **5–10 минут** повторный Doctor показал `[OK]`, без ручного изменения параметров пользователем.

**Ограничения свидетельства:** нет точного времени первого FAIL и последующего создания цепочки, кода возврата/stderr исходной команды `iptables`, состояния `MARK/CONNMARK/RETURN` в минуту FAIL, версии KeeneticOS/Entware и журнала вызовов hook. Позднее наличие цепочки **не доказывает** её наличие при первом запуске Doctor. Нельзя утверждать, что был false positive, пока нет одновременных наблюдений.

## Что следует из текущего исходного кода

1. **Installer** (`install.sh`, блок BYPASS RULES) загружает `020-bypass-wa.sh` в `/opt/etc/ndm/netfilter.d/` и делает файл исполняемым. Его итоговая локальная проверка устанавливает **наличие и executable-флаг файла**, а не полный runtime Netfilter ruleset. Эти факты нельзя подменять друг другом.
2. **Hook** (`020-bypass-wa.sh`) запускается Keenetic при rebuild firewall; он вызывает `iptables -w`, создаёт/очищает `_CUST_BYPASS_WA_`, присоединяет её к PREROUTING и добавляет правила `1400,3478,3482/udp`. Возможны промежуточные состояния во время перестройки; время и причина первоначального сбоя на Hopper не установлены.
3. **Doctor** (`mihomo-doctor.sh`, секция 7) отдельно выполняет `iptables -t mangle -S PREROUTING` и `iptables -t mangle -S _CUST_BYPASS_WA_`, перенаправляя stderr в `/dev/null`. При ненулевом return code второй команды пишет **`bypass_wa Netfilter chain missing`**. Такой текст может отражать подлинное отсутствие цепочки **либо** ошибку наблюдения; stderr в отчёте не остаётся.
4. Если цепочка читается, Doctor проверяет **PREROUTING link** и фактические UDP multiport **MARK**, **CONNMARK --save-mark**, **RETURN**. Этот контракт обоснован реальными A/B/C тестами KN-1010: существующая, но пустая цепочка не выполняет требуемый bypass. Нельзя заменять эту проверку проверкой имени, увеличенными счётчиками или одним `grep`.

**Гипотезы, не root cause:** первый Doctor мог опередить создание hook, совпасть с автоматической перестройкой firewall/xtables lock, попасть в промежуточное состояние цепочки; позже могло произойти самостоятельное событие KeeneticOS. Для доказательства нужно собрать синхронные данные.

## Когда ошибка повторится: безопасные read-only снимки

Запустить на тестовом роутере сразу при первом FAIL и повторить при переходе в OK; **не выполнять** команды изменения iptables, `modprobe`, `reboot` или принудительный rebuild ради сбора:

```sh
date
iptables -t mangle -S PREROUTING; echo "PREROUTING_RC=$?"
iptables -t mangle -S _CUST_BYPASS_WA_; echo "CHAIN_RC=$?"
iptables -t mangle -L _CUST_BYPASS_WA_ -nvx; echo "COUNTERS_RC=$?"
ls -l /opt/etc/ndm/netfilter.d/020-bypass_wa.sh
lsmod | grep '^xt_multiport'
```

Для одного подозрительного чтения дополнительно собрать `stderr` **не подавляя его** (сообщение об xtables lock или другом сбое может быть существенным). Фиксировать дату/время, model/hw_id, прошивку, `iptables --version`, тип и версию Entware, интервал от конца installer/config import до Doctor, если известен. Публиковать только обезличенный вывод; `PREROUTING` может раскрывать чужие IP/интерфейсы. Не передавать полные пользовательские конфиги, ключи или секреты.

## Матрица исследования/регрессий для агента

| Сценарий | Ожидаемое свойство проверки |
|---|---|
| Файл hook присутствует, цепочка ещё не создана | Не считать `executable` доказательством работающего bypass; отчёт различает install и runtime |
| `iptables -S` вернул ошибку доступа/lock/unknown | Сохранить причину, не выдавать наугад `missing`, не объявлять OK |
| Цепочка существует, но нет перехода из PREROUTING | FAIL/UNHEALTHY |
| Цепочка существует, но пуста / нет multiport MARK/CONNMARK/RETURN | FAIL/UNHEALTHY даже если chain name присутствует |
| Цепочка и все правила готовы | OK только при положительном runtime evidence |
| Появление chain после недолгой задержки | Зафиксировать точный момент и причину; возможен bounded startup-only readiness check после owner review |
| Цепочка не появилась после ограниченного окна | Сохранить FAIL, не маскировать WARN/INFO, не устраивать бесконечный retry |
| Firewall пересобирается параллельно с read-only проверкой | Проверить временный error и частичные snapshots, не менять правила сами |

**Если потребуется исправление:** начать с RED→GREEN теста в shell/BusyBox ash на синтетических `iptables` fixtures, `sh -n` и всех существующих regression suites. Предлагать отдельный topic PR: отдельные статусы `MISSING` / `UNVERIFIED` с фактическим stderr/rc, короткая ограниченная повторная проверка **только если она доказанно безопасна и применима к post-install**, а не общее ожидание по 5–10 минут. Doctor остаётся read-only; не менять `020-bypass-wa.sh`, bypass policy, Netfilter, `stable` и production без отдельного Owner GO.

## Связанные материалы

- [Issue #144 — исходный отчёт, гипотезы и дальнейшие исследования](https://github.com/saymer-alt/keenetic-auto-setup/issues/144)
- [docs/05 — устройство bypass_wa](05-bypass-wa.md)
- [docs/08 — практическая диагностика](08-troubleshooting.md)
- [docs/TESTING_STRATEGY — стандарты регрессий](TESTING_STRATEGY.md)
