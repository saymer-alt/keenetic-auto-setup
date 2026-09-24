# 13 — безопасный импорт config.yaml

\`config-import.sh\` закрывает пользовательский шаг между генератором и работающим Mihomo без ручного редактирования в \`nano\`.

## Обычный сценарий

1. Создайте конфиг в [Mihomo Unified Generator](https://saymer-alt.github.io/link-generators/).
2. Скопируйте весь YAML.
3. На Keenetic выполните:

\`\`\`bash
curl -fSsL https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/config-import.sh | sh
\`\`\`

4. Вставьте YAML и нажмите **Ctrl+D**.

Скрипт читает интерактивный ввод из \`/dev/tty\`, поэтому сценарий работает даже когда сам importer доставляется через \`curl | sh\`.

## Что происходит

- candidate сначала пишется в отдельный файл рядом с \`config.yaml\`;
- до остановки сервиса проверяется проектный контракт \`mixed-port: 7890\`;
- importer не запускает второй Mihomo рядом с daemon: работающий сервис останавливается и остановка подтверждается;
- watchdog получает \`/tmp/mihomo.maintenance\` и не вмешивается в плановую паузу;
- candidate проверяется настоящим \`mihomo -t\`;
- текущий \`config.yaml\` сохраняется как \`/opt/etc/mihomo/config.yaml.bak\`;
- candidate становится canonical config одним same-filesystem \`mv\`;
- если сервис ранее работал, он запускается снова; проверяются процесс и порт 7890;
- при ошибке validation/start/port старый конфиг атомарно восстанавливается из \`.bak\`, а прежнее состояние сервиса возвращается.

Importer также отказывается начинать транзакцию, если видит lock/process \`update-mihomo.sh\`.

## Импорт из файла

Для advanced-сценария:

\`\`\`bash
sh config-import.sh /tmp/config.yaml
\`\`\`

Файл проходит ту же транзакцию. Прямой overwrite canonical \`config.yaml\` importer не делает.

## Backup

После успешного импорта предыдущий конфиг остаётся здесь:

\`\`\`text
/opt/etc/mihomo/config.yaml.bak
\`\`\`

При следующем успешном импорте backup обновляется и содержит непосредственно предыдущую версию.

## Что importer не делает

- не генерирует YAML;
- не редактирует proxy links;
- не меняет Keenetic policies/DNS;
- не форматирует storage;
- не обновляет Mihomo binary;
- не делает URL-import.

Генератор отвечает за создание YAML, \`config-import.sh\` — только за безопасную установку готового конфига.
