# KAS WEB: переход каналов обновлений на GitHub Pages (beta.4)

Статус: **подготовка**. Публичный Pages-endpoint не активирован; активация,
публикация beta.4 и переключение каналов — только по отдельному GO владельца.
Связанные: #289 (каналы и self-update), #311 (reload UX, отдельный PR),
[#282](https://github.com/saymer-alt/keenetic-auto-setup/issues/282) (hygiene).

## 1. Текущее положение

Проверка обновлений читает индекс из служебного Release:

`https://github.com/saymer-alt/keenetic-auto-setup/releases/download/kas-web-channel-experimental/panel-update.json`

Привязка: `web/control-center/panel_update.go` (`readChannelIndex`,
`panelAssetURL`). Поэтому служебный Release `kas-web-channel-experimental`
нельзя удалить — от него зависит каждый установленный KAS WEB. Цель beta.4 —
перенести индексы на GitHub Pages, чтобы на странице Releases остались только
настоящие версии программ, и в дальнейшем убрать служебный Release.

## 2. Целевая архитектура

Источник индексов — GitHub Pages (deployment через GitHub Actions):

```
https://saymer-alt.github.io/keenetic-auto-setup/updates/experimental/panel-update.json
https://saymer-alt.github.io/keenetic-auto-setup/updates/stable/panel-update.json
https://saymer-alt.github.io/keenetic-auto-setup/updates/channels.json
```

Формат `panel-update.json` не меняется (schema 1, тот же `update-manifest.py`).
IPK по-прежнему скачиваются **только** из обычных GitHub Releases — разделение
доверия: Pages = указатель, Releases = байты пакетов.

### Реестр каналов `channels.json`

```json
{"schema":1,"generated":"2026-11-01T00:00:00Z","channels":{"experimental":{"published":true,"tag":"v0.1.0-beta.3"},"stable":{"published":false}}}
```

Реестр разворачивается вместе с индексами и даёт явные состояния канала:

| Состояние | Признак | Код для панели |
|---|---|---|
| опубликован | реестр `published:true`, индекс валиден | обычный ответ проверки |
| ещё не опубликован | реестр `published:false` | `PANEL_CHANNEL_UNPUBLISHED` (честное «ещё не выпущена», не ошибка) |
| опубликован, но повреждён | реестр `published:true`, индекс 404/битый JSON/битый schema | `PANEL_CHANNEL_INDEX_MISSING` / `PANEL_METADATA_INVALID` |
| временно недоступен | сеть/TLS/DNS/5xx, Pages целиком недоступен | `PANEL_UPDATE_SOURCE_UNAVAILABLE` |
| источник сломан | реестр 404/битый/чужой schema | `PANEL_UPDATE_SOURCE_BROKEN` |

Ни одно из состояний «повреждён/недоступен» не превращается в «обновлений нет».

### Политика доверия

- URL источника — строго одна константа (`pagesUpdateBase`), путь строится из
  имени канала; произвольные URL из ответов не используются.
- Redirect: только `https` и тот же host (`saymer-alt.github.io`); всё прочее
  отклоняется; 3xx без валидной цели классифицируется как недоступность.
- Ограничения: реестр ≤ 64 КиБ, индекс ≤ 1 МиБ, тайм-аут 20 с (реестр) / 30 с
  (индекс), как у существующих проверок.
- Валидация индекса — без изменений: `parsePanelIndex` (schema, channel, arch,
  имена, размеры, SHA256), затем проверка GitHub Release и ассетов через
  `api.github.com` (как раньше) — Pages не является источником доверия к байтам
  пакетов.
- Downgrade-защита (`opkg compare-versions`, строго новее) и явное
  подтверждение пользователем — без изменений.

## 3. Безопасная публикация индексов

One-shot workflow `updates-pages-deploy.yml` (только `workflow_dispatch`,
входы: channel, release tag, verified CI-run — явные пины, никаких авто-запусков):

1. IPK собраны на конкретном Source SHA (`web-beta3-build`-аналог).
2. Ассеты выгружаются из verified run и проверяются по `SHA256SUMS`.
3. Релиз уже опубликован в GitHub Releases (workflow проверяет).
4. Индекс строится `update-manifest.py` и сверяется с манифестами CI.
5. Текущие индексы **обоих** каналов скачиваются с живого Pages: публикуемый
   канал заменяется, соседний — переносится без изменений (изоляция каналов).
6. `channels.json` перегенерируется.
7. Deployment через `actions/upload-pages-artifact` + `actions/deploy-pages`
   с `concurrency: pages-updates` (serialize, cancel-in-progress: false —
   защита от параллельных публикаций).
8. После deployment — проверка **публичного endpoint'а** с ограниченным
   bounded retry (задержка Pages/CDN не объявляется успехом по зелёному job'у):
   digest и содержимое индекса совпадают с собранным, соседний канал не изменился.
9. Rollback индекса: повторный dispatch с тегом предыдущей версии того же
   канала (индексы versioned по содержимому, ручной путь документирован).

## 4. Переход beta.3 → beta.4 (обязательный порядок)

- **A.** Подготовить и проверить источник Pages (этот PR: код + workflow; без
  активации). Read-only тест доступности с реального роутера выполняет владелец.
- **B.** beta.4 с поддержкой Pages (этот PR: backend).
- **C.** По GO — опубликовать beta.4 обычным Release (draft-first workflow).
- **D.** По GO — переключить **существующий** `kas-web-channel-experimental`
  Release на beta.4: панели beta.3 обновляются через старый механизм.
- **E.** beta.4 после установки читает Pages для следующих обновлений.
- **F.** Старый Release продолжает работать весь переходный период и не
  удаляется автоматически.
- **G.** Только по отдельному решению владельца — с учётом оставшихся старых
  установок — удалить служебный Release. Если старые установки остаются, их
  автообновление после удаления станет невозможным; документированный ручной
  путь: `opkg upgrade` проверенного IPK beta.N вручную по SSH.

Никакой автоматической деградации «beta.4 вышла — старый Release можно
удалять» не существует.

## 5. Восстановление и отказы

- Pages недоступен / TLS/DNS ошибка / 5xx → `PANEL_UPDATE_SOURCE_UNAVAILABLE`,
  панель предлагает повторить позже; проверка не откатывает состояние.
- 404/403/429 → классифицируются отдельно (403/429 — как недоступность с
  понятным текстом; 404 индекса при `published:true` — как повреждение).
- Битый JSON/schema → `PANEL_UPDATE_SOURCE_BROKEN` / `PANEL_METADATA_INVALID`.
- GitHub Release с IPK недоступен или SHA256 не совпал → существующие коды
  (`PANEL_DOWNLOAD_FAILED` / `PANEL_METADATA_INVALID`) — проверка пакета не
  ослаблена.
- **Fallback на старый Release-индекс внутри beta.4 не реализован.**
  Обоснование: молчаливое переключение источника маскирует повреждение
  метаданных; экосистемный fallback уже существует (старый Release для
  панелей beta.3, шаг F). Повторная проверка выполняется пользователем.

## 6. Тестирование

- Go: `panel_update_pages_test.go` — реестр/индекс через httptest (все пять
  состояний), строгая политика redirect, валидация schema/tag/arch, отказ
  чужому хосту.
- Frontend: тексты новых кодов в `errorDescriptions` (RU/EN), unit-тест маппинга.
- Browser E2E исправления reload — PR A (#313), взаимодействие не меняется.
- QEMU/ported-lab: существующие контракты self-update не изменены; новый
  источник тестируется хостовыми Go-тестами с httptest (эмулятор внешних
  сервисов уже применяется в selfupdate-lifecycle).

## 7. Read-only тест доступности (владелец, реальный роутер)

После активации Pages по GO:

```sh
curl -fsS "https://saymer-alt.github.io/keenetic-auto-setup/updates/channels.json" | head -c 400
curl -fsS "https://saymer-alt.github.io/keenetic-auto-setup/updates/experimental/panel-update.json" | head -c 400
```

Ожидается JSON без ошибок TLS. Выполнять из LAN роутера (Entware, `curl` из
opkg). Никаких изменений на роутере не производится.

## 8. Известные ограничения

- Pages не включён в репозитории на момент подготовки; активация — отдельный
  GO (шаг A).
- Первый deployment создаёт сайт; до активации все проверки — на сторонах
  workflow и локальных тестов.
- Каскадная задержка Pages/CDN обрабатывается bounded-повторами проверки, а
  не увеличением тайм-аутов проверки в панели.
