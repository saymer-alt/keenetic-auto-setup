# Удаление KAS: пакетная удалялка и диагностика

Актуальная задача [#179](https://github.com/saymer-alt/keenetic-auto-setup/issues/179) **завершена**. Проверенный минимальный деинсталлятор — [`uninstall-packages.sh`](../uninstall-packages.sh), опубликован в `main` и `stable`.

## Обычное удаление пакетов

На тестируемом роутере с Entware:

```sh
curl -fSsL -o /tmp/kas-remove-packages.sh https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/uninstall-packages.sh &&
sh -n /tmp/kas-remove-packages.sh &&
sh /tmp/kas-remove-packages.sh
```

Скрипт сохраняет пользовательские YAML (при необходимости восстанавливает после OPKG), отключает только распознанный KAS watchdog, штатно останавливает Mihomo и MagiTrickle через Entware init.d, проверяет отсутствие процессов и выполняет `opkg remove`. Повторный запуск пропускает отсутствующие пакеты. Не форматирует накопитель, не использует force/killall и не обещает транзакционный откат. Доступны отдельные **необязательные** `--cleanup` и `--purge-config`; для стандартного удаления их не применяют.

**Это частичное удаление.** Настройки KeeneticOS — ProxyN, политики (`bypass_wa`), DNS-перехват и действующие правила Netfilter — не удаляются и могут продолжать направлять трафик через отсутствующий Mihomo. Перед удалением проверьте зависимые маршруты. Чужие пакеты и данные Entware не должны затрагиваться.

## Независимая read-only диагностика

[`uninstall.sh`](../uninstall.sh) — отдельный инструмент инвентаризации, а **не** альтернативный деинсталлятор:

```sh
sh uninstall.sh --check
sh uninstall.sh --plan
```

- `--check` выводит доступные данные об установленных пакетах, журнале владения `/opt/etc/keenetic-auto-setup/ownership.v1` и настройках KeeneticOS.
- `--plan` помогает увидеть собственные и чужие/неподтверждённые зависимости перед **ручным** решением.
- `--remove` и `--purge` у `uninstall.sh` намеренно **BLOCKED**. Не путайте с рабочим `uninstall-packages.sh`.

Журнал `ownership.v1` создаётся новым установщиком только для действительно созданных/включённых им ресурсов. Журнал сам по себе не даёт права автоматически удалять ProxyN, политику или DNS: они могли стать общими.

## Приёмка и архив исследований

- [KAS PR #235](https://github.com/saymer-alt/keenetic-auto-setup/pull/235) — рабочее штатное удаление и тесты.
- [Router Emulator E2E](https://github.com/saymer-alt/router-emulator/actions/runs/40313388777) — успешные остановка/OPKG/YAML/повтор/перезагрузка в QEMU.
- [KAS PR #244](https://github.com/saymer-alt/keenetic-auto-setup/pull/244) — точечная публикация в `stable` после успешного CI.
- KN-1010 — аппаратный PASS, включая перезагрузку, контрольные суммы YAML и отсутствие обоих процессов (доказательства в PR #235).
- История отвергнутого snapshot/transaction/PREPARE/rollback-прототипа сохранена в GitHub issue [#179](https://github.com/saymer-alt/keenetic-auto-setup/issues/179), ретроспективе [#225](https://github.com/saymer-alt/keenetic-auto-setup/issues/225) и PR [#202](https://github.com/saymer-alt/keenetic-auto-setup/pull/202), [#209](https://github.com/saymer-alt/keenetic-auto-setup/pull/209), [#215](https://github.com/saymer-alt/keenetic-auto-setup/pull/215). Она **не является действующим способом удаления**.

Экспериментальные snapshot/transaction скрипты исключены из актуальной основной ветки; обращаться к ним через устаревшие инструкции не следует.
