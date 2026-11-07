# Owner decisions and licensing scope

> Detailed **on-demand** guidance extracted from the previous root `AGENTS.md` at commit `9837c8141d60cbe6e9d408ee69515bb0bd16dbe6`. WORKING-FIRST / deferred blanket licence audit, with explicit limits on third-party redistribution. Relative plain-text paths like `docs/06` are repository-root-relative. The binding entrypoint remains [AGENTS.md](../../AGENTS.md) and [KAS Constitution](../CONSTITUTION.md). These notes do not authorize relaxing safety or owner permission gates.


> **Общее правило для всех проектов saymer-alt:** [Proof Before Build](https://github.com/saymer-alt/saymer-alt/blob/main/PROOF-BEFORE-BUILD.md) ([PR #9](https://github.com/saymer-alt/saymer-alt/pull/9)). Специализированное ТЭО и пример KAS: [docs/PROOF-BEFORE-BUILD.md](../PROOF-BEFORE-BUILD.md). Новые функции — только после доказательства проблемы, сравнения альтернатив, оценки пользы, стоимости и рисков. Обязательные safety-контракты KAS сохраняются.


## ⚑ Решение владельца от 2026-10-11: WORKING-FIRST / LICENSE AUDIT DEFERRED

**ПРОЕКТЫ ВЕДУТСЯ В ПЕРВУЮ ОЧЕРЕДЬ ДЛЯ ЛИЧНОГО НЕКОММЕРЧЕСКОГО ИСПОЛЬЗОВАНИЯ. РЕПОЗИТОРИИ ПУБЛИЧНЫЕ.**

**ПРИОРИТЕТ: РАБОТАЮЩИЕ СБОРКИ, IPK, ТЕСТЫ И БЕЗОПАСНОСТЬ. ПЛАНОВЫЙ ЛИЦЕНЗИОННЫЙ АУДИТ ОТЛОЖЕН. НЕ ЛОМАТЬ И НЕ ОСТАНАВЛИВАТЬ СУЩЕСТВУЮЩИЕ РЕЛИЗЫ ИЗ-ЗА НЕЗАВЕРШЁННОЙ ИНВЕНТАРИЗАЦИИ НОВОГО ЭКСПЕРИМЕНТАЛЬНОГО КОМПОНЕНТА.**

Для всех Codex / ZCode / других агентов:
- Не задавать владельцу повторно общий вопрос «что делать с лицензией?» и не превращать каждый статус-отчёт в новый аудит. Устаревшие или неполные notices фиксировать однократно в [отложенной задаче KAS #126](https://github.com/saymer-alt/keenetic-auto-setup/issues/126), не останавливая независимую инженерную работу.
- Продолжать безопасные сборки, тесты, IPK-рецепты, CI, аппаратные проверки, watchdog/rollback и работу действующих релизных конвейеров. Никогда не отключать Mihomo, WARPSCOUT, Beszel Agent, KAS, Builder Studio, `latest` или их CI только ради косметического license-review нового WDTT.
- **При этом предупреждение, публичный GitHub и некоммерческий характер сами по себе НЕ предоставляют разрешение на распространение чужого кода.** Сохранять существующие LICENSE, copyright/NOTICE, происхождение исходников и условия. При доказанном ограничении прав на конкретный компонент не выпускать **этот** компонент вопреки условиям; сообщить владельцу только о конкретном неизбежном решении. Не распространять юридическую неопределённость одного компонента на исправные независимые проекты.
- Экспериментальные WDTT/IPK могут иметь отдельный, явно обозначенный канал и ручной режим без вмешательства в production. Отсутствие завершённой инвентаризации не должно маскировать технические риски: AUTH, секреты, портовые конфликты, restart storms, rollback, архитектура/ABI и аппаратный допуск остаются обязательными проверками.
- Это правило не является разрешением менять `stable`, сливать PR, автоматически публиковать `latest`, менять работающую инфраструктуру или отменять CI. Любые такие действия — только по обычному процессу и owner GO.

**К лицензированию вернуться по отдельному запросу владельца или при конкретном установленном препятствии распространению. Не инициировать бесконечные повторные обсуждения.**


Working instructions for AI agents (primarily ZCode): "before X, verify Y",
"do not do Z without confirmation". Items without a label are confirmed by code, docs/,
or Git history; "(proposal)" means an agent recommendation, not a repository rule.

