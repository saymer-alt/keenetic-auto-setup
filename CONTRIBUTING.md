# Как участвовать / Contributing

Спасибо за интерес к проекту **keenetic-auto-setup**. Исправления документации, отчёты с воспроизводимыми ошибками и небольшие целевые PR приветствуются.

## С чего начать

1. Прочитайте [README](README.md) и существующие инструкции.
2. Перед новой задачей проверьте открытые Issues и Pull Requests, чтобы не дублировать работу.
3. Для ошибки создайте Issue через форму «Ошибка»; для идеи — «Предложение».
4. Для изменения кода создайте отдельную ветку от актуальной `main` и PR с небольшим, обозримым diff.

## Правила для этого проекта

- Before proposing installation or update changes, read `AGENTS.md`, `ARCHITECTURE.md` and the relevant `docs/` pages.
- State the Keenetic model, KeeneticOS version, RAM, `/opt` storage type, and installed Entware/Mihomo version when relevant.
- Never publish real proxy subscriptions, credentials, WAN addresses, private IP inventories, or router configuration dumps without redaction.
- Changes to installation, routing, watchdog, DNS interception and rollback need evidence and a safe recovery plan; documentation-only improvements are welcome.

## Проверка PR

- Объясните **что** изменено, **почему** и как это проверено.
- Запустите подходящие проверки из README, `tests/` или GitHub Actions; если проверить на устройстве невозможно, прямо укажите это.
- Не утверждайте, что физическое устройство или VPS протестировано, если такой проверки не было.
- Не меняйте release-теги, `stable` или исполняемую инфраструктуру в документационном PR.
- Уважайте действующую лицензию и атрибуцию сторонних компонентов.

## Безопасность и приватные данные

**Не сообщайте о нераскрытых уязвимостях публично через Issues.** Для конфиденциальных отчётов необходим отдельный согласованный приватный канал; не прикладывайте секреты к публичным PR, логам или формам. Конфигурации и логи перед публикацией обезличивайте. Публичные Issues подходят для несекретных ошибок и предложений.

Работы, требующие доступа к чужим сетям или серверу, не являются обязательным условием участия.
