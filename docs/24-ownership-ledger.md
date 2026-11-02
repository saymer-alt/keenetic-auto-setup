# Журнал установки KAS (ownership.v1)

Для новых запусков `install.sh` KAS ведёт журнал ресурсов, которые **были созданы во время данного запуска**, в `/opt/etc/keenetic-auto-setup/ownership.v1`.

Журнал хранится на постоянном `/opt` (внутренний Entware или EXT4), создаётся с правами `0600` и обновляется атомарно под общим lifecycle lock. Он не содержит конфигурацию Mihomo, пароли или содержимое пользовательского YAML.

## Что записывается

Формат: первая строка `KAS_OWNERSHIP_V1`, затем одна запись на доказанную операцию:

```text
KAS_OWNERSHIP_V1
owned|proxy|Proxy1
owned|policy|bypass_wa
enabled|dns|intercept
owned|package|mihomo
owned|package|magitrickle
owned|repository|magitrickle.conf
owned|hook|020-bypass_wa.sh
owned|watchdog|binary
owned|watchdog|wrapper
owned|service|S00ubifs
```

Это **пример формата**, не ожидаемый набор на каждом устройстве. `disk` не создаёт `S00ubifs`; ранее установленный MagiTrickle не получает отметку `owned|package`. Установщик не забирает существовавшие интерфейсы ProxyN, DNS-перехват, политики или файлы себе при повторной установке. При ошибке проверки/сохранения журнала установка останавливается, не пытаясь продолжить вслепую.

## Проверка на тестовом KN-1010

До переноса в `stable` используйте **обе** переменные ветки (иначе `bootstrap.sh` сам возьмёт `stable`):

```sh
export KAS_BOOTSTRAP_REF=main KEENETIC_AUTO_SETUP_REF=main
opkg update && opkg install curl && curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/main/bootstrap.sh | sh
```

Команда рассчитана **только на отдельный тестовый KN-1010**, после слияния проверенного PR в `main`. Это полноценный установщик, он может изменять сервисы и настройки, не является сухой проверкой. Обычный публичный установщик в README продолжает использовать `stable`; для возврата к стандартной ветке перед другими запусками сделайте `unset KAS_BOOTSTRAP_REF KEENETIC_AUTO_SETUP_REF`.



После установки (и после повторного запуска установщика) можно безопасно посмотреть записи:

```sh
cat /opt/etc/keenetic-auto-setup/ownership.v1
ls -l /opt/etc/keenetic-auto-setup/ownership.v1
```

Сравните содержимое до и после повторной установки: записи не должны дублироваться. Если KAS был установлен **до** введения журнала, файл может содержать только заголовок: это верно, потому что чужую историю операций новый код достоверно не знает.

**Не редактируйте журнал вручную.** Запись подтверждает лишь факт создания/включения во время установки, а не текущую эксклюзивность владения. Даже при наличии журнала удаление должно отдельно проверять актуальные зависимости, общее использование пакетов и сохранение пользовательских данных.

**Задача [#179](https://github.com/saymer-alt/keenetic-auto-setup/issues/179) завершена для минимального удаления пакетов.** Штатный [`uninstall-packages.sh`](../uninstall-packages.sh) удаляет Mihomo и MagiTrickle через OPKG с остановкой сервисов и сохранением YAML; опубликован в `stable` (PR #244). **Это не полный откат KeeneticOS:** `ProxyN`, `bypass_wa`, DNS intercept и действующие Netfilter-правила не очищаются автоматически, а журнал владения не даёт оснований удалять чужие или общие ресурсы.

## Владение между script-KAS, kas-core (лабораторный пакет) и панелью

Матрица владения для будущей миграции `kas-core.ipk` (issue #295, фаза A). Пакет kas-core существует только как lab-квалификация (`packaging/core/`), live-root установка заблокирована; таблица фиксирует целевое владение, чтобы коллизии обнаруживались до установки.

| Ресурс | Владелец сегодня | kas-core после миграции | Коллизия/правило |
|---|---|---|---|
| `/opt/bin/mihomo_watchdog.sh` | `update-watchdog.sh` (canonical, legacy-хэши + каталог предков) | `kas-core-watchdog.sh apply` через `update-watchdog.sh --package-candidate` | modified/foreign файл блокирует активацию; receipt `/opt/etc/kas-core/watchdog.json` |
| `/opt/etc/cron.5mins/mihomo_watchdog` | `update-watchdog.sh` (wrapper) | остаётся у installer/updater | пакет никогда не пишет в cron.5mins (sentinel в `tests/test_core_ipk.py`) |
| `/opt/libexec/kas/` | отсутствует (нет установки) | opkg (bundle) | foreign файлы в каталоге блокируют install/upgrade/remove |
| `/opt/share/kas-core/` | отсутствует | opkg (manifest, BUILD_INFO, каталог) | tamper → status `bundle_changed` |
| `/opt/etc/keenetic-auto-setup/ownership.v1` | install.sh | не переопределяется | журнал создания остаётся за script-KAS |
| `/opt/etc/mihomo/config.yaml`, MT config, политики, ProxyN | пользователь/installer | не принадлежат пакету | opkg remove kas-core их не трогает (bundle-level тест) |
| Панель `kas-control-center` | WEB-пакет (#289/#293) | отдельный цикл версий | kas-core ≠ WEB; панель читает activation receipt read-only |

