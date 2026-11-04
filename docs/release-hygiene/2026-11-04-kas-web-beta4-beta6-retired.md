# KAS WEB beta.4 / beta.5 / beta.6 / beta.7 GitHub Releases — retired 2026-11-04

По GO CLEANUP владельца (PR #406, комментарии 6639312439, 6639463424 и
fail-closed remediation 6639684240) **GitHub Release objects**
`v0.1.0-beta.4` (ID 431763924), `v0.1.0-beta.5` (ID 432667717),
`v0.1.0-beta.6` (ID 433176589) и `v0.1.0-beta.7` (ID 433686539) удалены со
страницы Releases **04.11.2026**.

Не удалено и не изменено:

- git-теги `v0.1.0-beta.4`, `v0.1.0-beta.5`, `v0.1.0-beta.6`, `v0.1.0-beta.7`
  и их source-коммиты (`7b0323b6…`, `b1b3ceaadc…`, `070faa90…`, `a321775a…`);
- beta.8 (действующая experimental, ID 434190732), KAS Core releases и
  `releases/latest` (`v1.8.7`);
- GitHub Pages: experimental → `v0.1.0-beta.8`, `stable` → `published=false`;
- GitLab-зеркало и его refs (расхождение beta.6-тега — отдельный вопрос #388).

Все **20 оригинальных assets** (4 IPK + SHA256SUMS × 4) скачаны, сверены
байт-в-байт с GitHub API digests (beta.4–6 дополнительно с preflight-снимком
этого PR) и упакованы в долговечный архив. Архив размещён **вне удаляемых
релизов** — в отдельном never-delete архивном релизе с сохранённым тегом
`archive/kas-web-beta4-beta7-20261104`:

`kas-web-beta4-beta7-retirement-archive-2026-11-04.tar.gz`
SHA256 `bb909275f4566b750f7e812337d7d0d6f2694eae16166a17ccac67ce18f97222`
URL: <https://github.com/saymer-alt/keenetic-auto-setup/releases/download/archive/kas-web-beta4-beta7-20261104/kas-web-beta4-beta7-retirement-archive-2026-11-04.tar.gz>

Промежуточный архив beta.4–6 (`78e9321a…bbdd24`, ранее на asset релиза beta.7)
полностью включён в комбинированный архив и прекращает существование вместе с
релизом beta.7 — замещён архивом выше. Любой откат на beta.4–beta.7 теперь —
ручное восстановление из архива, а не живой Release URL; Pages на эти версии
не указывает.

Исторические ссылки в документации (roadmap, proposals, handoff) помечены
retired; полная ведомость — evidence ledger в PR #406 / issue #282.
Исторические метки `v0.1.0-beta.4/5/6/7` на страницах GitHub ведут к
существующим тегам без release-объекта — это ожидаемое состояние после
удаления release.
