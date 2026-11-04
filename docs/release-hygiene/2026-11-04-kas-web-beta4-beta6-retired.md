# KAS WEB beta.4 / beta.5 / beta.6 GitHub Releases — retired 2026-11-04

По GO CLEANUP владельца (PR #406, комментарий 6639312439) **GitHub Release objects**
`v0.1.0-beta.4` (ID 431763924), `v0.1.0-beta.5` (ID 432667717) и `v0.1.0-beta.6`
(ID 433176589) удалены со страницы Releases **04.11.2026**.

Не удалено и не изменено:

- git-теги `v0.1.0-beta.4`, `v0.1.0-beta.5`, `v0.1.0-beta.6` и их source-коммиты
  (`7b0323b6…`, `b1b3ceaadc…`, `070faa90…`);
- beta.7 (rescue) и beta.8 (действующая experimental), KAS Core releases и `releases/latest` (`v1.8.7`);
- GitHub Pages: experimental → `v0.1.0-beta.8`, `stable` → `published=false`;
- GitLab-зеркало и его refs (расхождение beta.6-тега — отдельный вопрос #388).

Все 15 оригинальных assets (4 IPK + SHA256SUMS × 3) скачаны, сверены
байт-в-байт с GitHub API digests и preflight-снимком PR #406 и упакованы в
долговечный архив, размещённый как asset recovery-релиза beta.7:

`kas-web-beta4-beta6-retirement-archive-2026-11-04.tar.gz`
SHA256 `78e9321acc8d86ea88b3dd0aa4ef6e48588b2db51ab6ecbcc4274665efbbdd24`
URL: <https://github.com/saymer-alt/keenetic-auto-setup/releases/download/v0.1.0-beta.7/kas-web-beta4-beta6-retirement-archive-2026-11-04.tar.gz>

Исторические ссылки в документации (roadmap, proposals, handoff) помечены
retired; полная ведомость — evidence ledger в PR #406 / issue #282.
Исторические метки `v0.1.0-beta.4/5/6` на страницах GitHub ведут к существующим
тегам без release-объекта — это ожидаемое состояние после удаления release.
