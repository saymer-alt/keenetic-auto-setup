# Entware feeds при нестабильном доступе к bin.entware.net — исследование для KAS 1.8.3

> **Status: documented/manual opt-in, NOT an automatic feed replacement.** Ни KAS, ни Doctor не должны молча менять OPKG URLs, отключать проверки подписей или переподключать носитель Entware. Данные обновить и перепроверить перед релизом.

## Полевые наблюдения (октябрь 2026)

- В России пользователь и внешние тестировщики сообщают о нестабильном доступе к `bin.entware.net` (DNS/transport errors, зависание `opkg update`). Причину на уровне DPI/хостинга нельзя установить из одного лога; скрипт должен диагностировать факт отказа, а не предполагать виновника.
- Предложен зеркальный адрес `https://mirrors.nju.edu.cn/entware/` вместо `http://bin.entware.net/`. По данным публичного каталога NJU 18.10.2026 доступны `/entware/aarch64-k3.10/Packages.gz` и `/entware/aarch64-k3.10/keenetic/`; зеркало отмечено `Synced` в каталоге провайдера. **Это проверка наличия, не гарантия доступности из пользовательской сети, свежести всех архитектур или идентичности каждого IPK.**
- Руководство из сообщества советовало глобальное `sed -i` по `/opt/etc/opkg.conf`. Для проекта такой шаг без snapshot, scope/audit и rollback неприемлем. Feed-файлы в `/opt/etc/opkg/*.conf` тоже возможны; сторонние (например MagiTrickle) не переписывать.

## Безопасная ручная диагностика — только чтение

```sh
echo "=== active Entware feed configuration ==="
[ -f /opt/etc/opkg.conf ] && grep -n '^src/gz ' /opt/etc/opkg.conf
for f in /opt/etc/opkg/*.conf; do
    [ -f "$f" ] && grep -n '^src/gz ' "$f"
done

echo "=== repository network probes (no opkg changes) ==="
curl -4 -I -fSsL --connect-timeout 5 --max-time 15 \
    https://mirrors.nju.edu.cn/entware/aarch64-k3.10/Packages.gz
curl -4 -I -fSsL --connect-timeout 5 --max-time 15 \
    http://bin.entware.net/aarch64-k3.10/Packages.gz
```

> Пример URL выше **только для архитектуры aarch64-k3.10**. На 128/256 MB/MIPS другом железе путь обязан выводиться из уже существующего feed URL; не подставлять aarch64 всем. `HEAD` не доказывает, что весь feed скачивается через OPKG.

## Восстановление feed вручную (только отдельным решением администратора)

1. Сохранить исходный `/opt/etc/opkg.conf` и список всех `/opt/etc/opkg/*.conf` в датированный архив/backup с правами доступа.
2. Убедиться, что исходные `src/gz` URL, архитектура, подкаталоги и возможные подписи/ключи совпадают; не менять сторонние репозитории.
3. Сначала проверить **HTTPS** зеркало с роутера, затем доставку конкретного `Packages.gz`, затем актуальность/целостность metadata и pkg-источника. При отсутствии достоверной HTTPS/проверки подписи fail closed.
4. Только затем вручную заменить **ровно соответствующие** prefix URLs `bin.entware.net` в нужном feed-файле, не трогая оригинальные user comments и MagiTrickle; запустить `opkg update`, проверить результат, вернуться к оригиналу при ошибке.
5. Предоставить оператору точный путь rollback из сохранённой копии. Простое обратное `sed` ненадёжно: может затронуть другие URL/настройки и не восстановит предыдущую структуру.

**Не рекомендовать автоматически:** переключение накопителя Entware в Keenetic UI с «Не выбран» и обратно только для решения сетевой проблемы. Это демонтирует /opt и может остановить службы; нужен отдельный план простоя/восстановления.

## Требования к KAS 1.8.3

- Ненавязчивая read-only preflight проверка Entware feeds: текущие источники, арх. профиля, DNS/TCP/TLS/HTTP / download outcome, тайм-ауты и репорт `opkg update`.
- Если основной feed недоступен, выводить **чёткий WARN или ERROR в зависимости от того, можно ли продолжать безопасно**, ссылку на эту инструкцию и предложение альтернативного проверенного зеркала. Отказ `opkg update` нельзя тихо скрывать.
- Рассмотреть **явно opt-in**, обратимое переключение `bin.entware.net` ↔ `mirrors.nju.edu.cn` с backup+atomic edit+validation+rollback, лишь после подтверждения подписей и безопасности; без массового `sed -i` / глобального переназначения «all arch».
- Тесты: unreachable origin / reachable mirror; both unreachable; wrong architecture; missing/stale Packages index; failed signature; third-party feed unaffected; rollback; no opkg storage disruption; BusyBox ash.
- Публикуемые пользователю команды не должны зависеть от нового инструмента, который невозможно установить из-за того же недоступного feed.

## Ссылки

- [Entware original feed](https://bin.entware.net/aarch64-k3.10/)
- [NJU mirror feed](https://mirrors.nju.edu.cn/entware/aarch64-k3.10/)
- [NJU mirror status](https://mirrors.nju.edu.cn/)
- [KAS issue #146](https://github.com/saymer-alt/keenetic-auto-setup/issues/146)

Документ не изменяет файловой системы роутеров и не заявляет, что конкретный провайдер DPI или атака на конкретный хостинг уже доказаны.
