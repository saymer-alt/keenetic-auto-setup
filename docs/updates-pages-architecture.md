# KAS WEB: переход каналов обновлений на GitHub Pages (beta.4)

Статус: **архитектура развёрнута, legacy-канал выведен (2026-11-02)**. Beta.4
опубликована; единственный действующий источник индексов — GitHub Pages
experimental, обслуживающий `v0.1.0-beta.4`
(SHA256 `a9914512872eb08d1f9b3ae752a3fec679f2016c4c51601e276ce87ed64710ac`).
*(retired 04.11.2026: Release `v0.1.0-beta.4` удалён, тег сохранён, assets в
архиве — [docs/release-hygiene/2026-11-04-kas-web-beta4-beta6-retired.md](release-hygiene/2026-11-04-kas-web-beta4-beta6-retired.md);
live-канал — `v0.1.0-beta.8`.)*
Аппаратное обновление NC-4210 beta.3 → beta.4 через WEB-панель подтверждено
владельцем (`0.1.0~beta.4-1`, aarch64-3.10). Этапы A–G раздела 4 выполнены:
служебный Release `kas-web-channel-experimental` удалён 02.11.2026 отдельным
GO владельца (сознательное прекращение поддержки обновлений старых
test17/beta.1/beta.2/beta.3 через legacy-канал; git-тег сохранён).
Связанные: #289 (каналы и self-update), #311 (reload UX, отдельный PR),
[#282](https://github.com/saymer-alt/keenetic-auto-setup/issues/282) (hygiene).

## 1. Текущее положение

Проверка обновлений в beta.4 читает индекс из GitHub Pages:

`https://saymer-alt.github.io/keenetic-auto-setup/updates/experimental/panel-update.json`

До beta.4 панели читали индекс из служебного Release:

`https://github.com/saymer-alt/keenetic-auto-setup/releases/download/kas-web-channel-experimental/panel-update.json`

Привязка: `web/control-center/panel_update.go` (`readChannelIndex`,
`panelAssetURL`). Служебный Release `kas-web-channel-experimental`, из
которого панели читали индекс до beta.4, удалён 02.11.2026 по GO владельца:
панели beta.4+ полностью обслуживаются GitHub Pages, на странице Releases
остались только настоящие версии программ. Панели beta.3 и старее более не
имеют канала автообновления — документированный путь перехода: ручная
установка проверенного IPK beta.4 по SSH (`opkg install`).

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

1. IPK собраны на конкретном Source SHA (официальный candidate-run
   `kas-web-candidate-build.yml`, явный workflow_dispatch).
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

### Bootstrap: первое развёртывание (историческая запись)

Первый deployment был выполнен с `bootstrap=true` по выпущенной beta.3
(run 41335807269, 2026-11-01), что дало проверенный источник до появления
beta.4. В bootstrap-режиме допускается инициализация отсутствующего реестра;
во всех остальных режимах сломанный или отсутствующий реестр останавливает
публикацию (fail closed). Актуальный деплой канала выполняется тем же
one-shot workflow с явными пинами (channel, release tag, verified CI-run,
expected source SHA) — 2026-11-02 им опубликован индекс beta.4
(run 41496358204).

## 4. Переход beta.3 → beta.4 (обязательный порядок) — выполнен 2026-11-02

- **A. ✅** Источник Pages подготовлен и проверен; read-only тест доступности
  с реального роутера выполнен владельцем (NC-4210, HTTPS до Pages — ОК).
- **B. ✅** beta.4 с поддержкой Pages (backend) выпущена.
- **C. ✅** beta.4 опубликована как Release `v0.1.0-beta.4` (draft-first,
  run 41492190833; байтово сверена с verified run 41337020621).
- **D. ✅** Существующий `kas-web-channel-experimental` Release переключён на
  beta.4 (run 41498019338): панели beta.3 обновились через старый механизм;
  индекс побайтово совпадает с Pages.
- **E. ✅** beta.4 после установки читает Pages для следующих обновлений;
  аппаратное обновление NC-4210 beta.3 → beta.4 через WEB-панель
  подтверждено владельцем.
  **Важно про интерфейс:** установленная beta.3 исполняла старый JavaScript,
  поэтому после beta.3 → beta.4 могло потребоваться одно ручное обновление
  страницы (Ctrl+F5 или F5); корректное подтверждение установленной версии
  дают карточка «Версии», подвал панели (`KAS Web v…· SHA`) и
  `opkg status kas-control-center` — они читают фактическую работающую
  панель, а не кеш браузера. Начиная с beta.4 автоматическая перезагрузка
  интерфейса работает для всех следующих переходов (beta.4 → beta.5 и далее).
- **F. ✅** Старый Release работал весь переходный период (до 02.11.2026,
  финальное содержимое — индекс beta.4).
- **G. ✅** 02.11.2026 отдельным GO владельца служебный Release
  `kas-web-channel-experimental` удалён (git-тег сохранён). Владелец сознательно
  прекратил поддержку обновлений старых test17/beta.1/beta.2/beta.3 через
  legacy-канал; KN-1010 исключён из действующего парка тестирования KAS WEB
  (исторические результаты — архив). Панели beta.3 и старее: ручной путь
  `opkg install` проверенного IPK beta.4 по SSH; их проверка обновлений через
  панель больше не находит канал (ожидаемое следствие решения владельца).

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

- Служебный Release `kas-web-channel-experimental` удалён 02.11.2026 по GO
  владельца (шаг G выполнен). Панели beta.3 и старее без канала
  автообновления — ручной путь через SSH; KN-1010 — архивный стенд вне
  действующего парка.
- Каскадная задержка Pages/CDN обрабатывается bounded-повторами проверки, а
  не увеличением тайм-аутов проверки в панели.
- One-shot publisher/switch workflows (beta.2/beta.3/beta.4) выведены из
  эксплуатации 2026-11-02 вместе со своими dry-run наборами; общие тестовые
  фикстуры сохранены в `tests/_publication_testkit.py`. Действующие
  механизмы — `updates-pages-deploy.yml` (канальный деплой) и candidate-build
  (`kas-web-candidate-build.yml`) — не изменены.
