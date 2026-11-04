# KAS WEB beta.4–beta.6 — preflight архивации перед возможным снятием GitHub Releases

> **Только read-only inventory / DRY RUN, 04.11.2026. Ничего не удалено и не архивировано этим документом.**
> Снимок составлен из GitHub Releases REST API. Это НЕ GO на удаление release objects, git tags, веток, IPK, каналов обновления, установки на устройства или публикацию beta.8. Перед исполнением перечитать живой GitHub API, Pages и реальные зависимости.
> Связанные контракты: [#282](https://github.com/saymer-alt/keenetic-auto-setup/issues/282), [beta.8 #395](https://github.com/saymer-alt/keenetic-auto-setup/issues/395), [совместный Draft #405](https://github.com/saymer-alt/keenetic-auto-setup/pull/405), [исторический batch-3](2026-10-31-release-retire-batch3-executed.md).

## Почему эта ведомость нужна

Владелец планирует **после** официальной публикации и проверки beta.8 убрать три устаревших prerelease с *видимой страницы Releases*: `v0.1.0-beta.4`, `v0.1.0-beta.5`, `v0.1.0-beta.6`. Важно: удаление Release без предварительного архивирования уничтожает удобные ссылки и сами бинарные ассеты. Git tags/коммиты должны остаться; `v0.1.0-beta.7` оставить опубликованной как доступный rescue-артефакт. GitHub Latest основной линейки KAS Core, `stable`, `mihomo`, архив прошлых тестов и GitHub Pages обновлений не трогать.

GitHub Pages содержит **индекс**, не пакеты; сам IPK загружается из Releases, на который указывает индекс. Поэтому нельзя удалять релиз, пока действующий experimental индекс указывает на него. После переключения на beta.8, прежде чем удалять эти три релиза, необходимо доказать корректные ссылки, SHA256 и доступность всех четырёх beta.8 IPK с реальных публичных endpoints. Если Pages недоступен или не подтверждён — **HOLD**.

## Идентификаторы неизменяемого снимка

| Release (ссылка) | Source/target commit SHA | Internal IPK version | Статус API на момент аудита |
| --- | --- | --- | --- |
| [beta.4](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/v0.1.0-beta.4) | `7b0323b644f0fc79f25fc26a55b5d4c3295aecd5` | `0.1.0.beta.4-1` | published prerelease, 5 assets |
| [beta.5](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/v0.1.0-beta.5) | `b1b3ceaadc1de95403d5d26fef3d7831ac59b4c9` | `0.1.0.beta.5-1` | published prerelease, 5 assets |
| [beta.6](https://github.com/saymer-alt/keenetic-auto-setup/releases/tag/v0.1.0-beta.6) | `070faa90e15855ae6076d8738c5dcec931059a36` | `0.1.0.beta.6-1` | published prerelease, 5 assets |

**Примечание:** release target + GitHub asset digest являются лишь опубликованными метаданными; они НЕ подтверждают скачивание и проверку всех байтов отдельного долговечного архива. Все четыре ABI `aarch64-3.10`, `armv7-3.2`, `mips-3.4`, `mipsel-3.4` и `SHA256SUMS` должны быть реально скачаны и verified до удаления.

## SHA256 существующих assets (по полю `digest` GitHub Releases API, 04.11.2026)

| Asset / ABI | beta.4 | beta.5 | beta.6 |
| --- | --- | --- | --- |
| `aarch64-3.10.ipk` | `b3efcf56d83ddd671c7f00ff19cde0ca73d9d686e6155cc5f8ecb8b38d948986` | `15dd5d724f44dd85fa569e936878f55caf88b27d1e2c19ec663c170b29c87fca` | `68e057761ac4c367553545ec39d45b75751f1099c3d8a6d8f057d9c755a2882c` |
| `armv7-3.2.ipk` | `f152a1df8edd682587c7b92e53cf0f5766f63ef0dc2a5a223dc58314fe636610` | `90edfc2654dae5b03dff94e174ef4a5ee0d794cbf167bef052289d3eecde4a37` | `d0e9da6f4a428cc2a63cf75409937faa192b7bf3f3fdac861c5ecdcb8a4f634f` |
| `mips-3.4.ipk` | `034fd7bec410e968f9c3c860a60bb6eda816705dd3fe6da9b54a5ed2f6386f79` | `935bf3cc253ac9c0a693fdea051f394636352b660aa61dd5cc4e81a4dc180c9f` | `e383f0df6aefe27c362cf79ac37cad28d0e2a208ce19f341829d2bf8122776b1` |
| `mipsel-3.4.ipk` | `1be328ea46dbb17ccf615729b5a5f278b8171b1a2335b15cdf44624c9e5f62d2` | `dcbf837c4e8f0436e8fb76245fe1681dcfe9c59c94203dbf1203ed6d71d20f2c` | `ed4b83781bbfbccfc6b9a32e539407e8d86f14bd2d305982fcd664b6050d7cc5` |
| `SHA256SUMS` | `6731945ce52a9fc016993174819d8bc9680915d0ffa5955f110ff9b4178450ef` | `a4f45ead052de10db12432d4a0c15ae3ffff049f6b46a35a14e93c99a79fa1e7` | `92330cbdf651dcd8e56a661b49323526e3767fc128972f8b309d8f964cde31a5` |

Размеры (байты) по API: beta.4 — `2800925/2818647/2718256/2694782/467`; beta.5 — `2806950/2824099/2722730/2701012/459`; beta.6 — `2835820/2854506/2752307/2730268/459`, в каждой строке порядок ABI тот же, что в таблице выше, затем `SHA256SUMS`.

## Обязательный порядок будущей архивной операции

1. **Повторная инвентаризация:** проверить актуальный `main`, open/merged PR, published releases, все 15 существующих assets, tag targets и содержимое release notes; записать фактическую дату и точные IDs. Сверить, что `v0.1.0-beta.8` действительно опубликована с 4 IPK+SHA256SUMS, а не только candidate-run.
2. **Канал:** с публичных `https://saymer-alt.github.io/keenetic-auto-setup/updates/channels.json` и `updates/experimental/panel-update.json` получить подтверждённое `tag=v0.1.0-beta.8`, `published=true`, 4 согласованных ABI, SHA256, size, source_sha. Проверить реальные ссылки GitHub Releases на все beta.8 assets, состояние `uploaded`, непрерывность соседнего stable канала. Нельзя полагаться только на зелёный workflow — сверить внешние endpoint'ы.
3. **Зависимости:** найти прямые ссылки на beta.4/5/6 binaries в исходниках, docs, workflows, Issues/PR, scripts, updater, GitLab/external docs и user-runbook; определить, есть ли действующие аппаратные установки, где для отката требуется именно одна из старых версий. Предусмотреть ручное обновление/восстановление и **не обещать** автоматический rollback; старые устройства, читающие Pages, могут обновляться на beta.8, но не смогут скачивать старый asset по удалённой ссылке.
4. **Реальное резервирование:** для каждого выпуска сохранить оригинальные 5 assets, notes, git target/tag, дату и CI provenance в долговечный архив (не GitHub Actions artifacts с TTL), вычислить SHA256 скачанных файлов, побайтово сверить с `digest` из API и с оригинальным `SHA256SUMS`; проверить распаковку архива и повторное считывание. Архив должен оставаться доступным после удаления Releases, иметь публичный или задокументированный rescue-доступ. Одних хэшей в этой ведомости **недостаточно**.
5. **Отдельный owner GO на exact list:** только после прохождения предыдущих шагов удалить **ровно три GitHub Release objects** по тэгам `v0.1.0-beta.4`, `v0.1.0-beta.5`, `v0.1.0-beta.6`; **не удалять** Git tags, source commits, archive release, beta.7, beta.8, Core Releases, `stable`, `mihomo`, GitLab tags и Pages. Повторная проверка live state перед каждым удалением, fail closed при изменении базы/канала.
6. **Послеоперационная проверка:** beta.8 release/index и все бинарные ссылки доступны, GitHub Latest Core не изменился, beta.7 rescue доступна, tags 4/5/6 существуют, архив считывается и может восстановить один выбранный IPK/Release; сохранить доказательства в ledger с точными GitHub API responses, SHA256 и временем.

## Отдельный GitLab mirror blocker (НЕ часть cleanup)

[#388](https://github.com/saymer-alt/keenetic-auto-setup/issues/388): GitHub `v0.1.0-beta.6` ссылается на `070faa90e15855ae6076d8738c5dcec931059a36`, а GitLab зеркало — на предшествовавший `b7d97c297a70c90980d932bf571cd0ff6ee52ad9`. Документация [docs/gitlab-mirror.md](../gitlab-mirror.md) дополнена PR #391. Нельзя лечить расхождение удалением GitHub Release либо force-push; отдельный owner GO нужен для точечной ручной сверки GitLab tag + повторной нормальной mirror sync.

## Статус

- [x] Публичные GitHub Release metadata, names, source target, digest и size собраны (read-only).
- [ ] Фактические assets скачаны, проверены и упакованы в доступный долговечный архив.
- [ ] Выверены живые Pages registry/index после **официального** beta.8, а не по предположению.
- [ ] Проверены ссылки, зависимости, практический recovery и интересы пользователей старых версий.
- [ ] Отдельный owner GO на точный deletion list получен.
- [ ] Release objects 4/5/6 удалены и послеоперационное состояние подтверждено.

**Следствие:** на текущем этапе **NO DELETE**. Этот документ сохраняет факты, но сам по себе НЕ делает архив и не снимает safety gates.
