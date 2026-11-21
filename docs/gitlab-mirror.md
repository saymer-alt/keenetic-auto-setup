# GitLab-зеркало (one-way mirror)

Зеркало: **https://gitlab.com/saymer-alt/keenetic-auto-setup**
Источник истины: **https://github.com/saymer-alt/keenetic-auto-setup**

## Архитектура

```
GitHub (источник) ──push──> GitHub Actions (gitlab-mirror.yml) ──ssh──> GitLab (зеркало, только чтение)
```

- Синхронизация односторонняя: всё меняется только на GitHub; GitLab — копия для чтения.
- Workflow `.github/workflows/gitlab-mirror.yml` запускается автоматически при push
  в `main`, `stable`, при появлении тегов и вручную (`workflow_dispatch`, вкладка
  Actions → **GitLab mirror sync** → Run workflow).
- **Охват синхронизации — только `main`, `stable` и все теги** (полная история).
  Остальные ветки сознательно не зеркалятся: в KAS продолжается очистка старых
  экспериментальных веток, а зеркало никогда не удаляет ref-ы — зеркалирование
  рабочих веток накапливало бы на GitLab устаревшие копии. Отдельную ветку можно
  перенести вручную (см. ниже).
- Пуш идёт от проектного Deploy Key `github-mirror-sync` (SSH ed25519, право `can_push`
  выдано **только** этому проекту). Приватная часть ключа хранится исключительно в
  GitHub Actions secret `GITLAB_MIRROR_SSH_KEY`; в коде, логах и issues её быть не должно.
- Безопасность: зеркальный push **никогда** не делает force-push и не удаляет ветки/теги
  (нет `--force`/`+`/`--prune`/`--mirror`). Расхождение истории приводит к падению
  синхронизации с диагностикой, а не к перезаписи.
- Каждый push передаётся с опцией `-o ci.skip`, поэтому GitLab CI/CD на зеркале не
  запускается; в проекте нет и не планируется `.gitlab-ci.yml`.
- Множественные запуски сериализуются через `concurrency: gitlab-mirror`
  (без отмены выполняющегося пуша).
- От существующих процессов CI/CD KAS workflow изолирован: отдельный файл, отдельный
  secret, минимальные права (`permissions: contents: read`).

## Как проверить состояние зеркала

1. Прогон синхронизации: GitHub → **Actions** → **GitLab mirror sync** — последний
   запуск зелёный.
2. Полное сравнение ref-ов (SHA должны совпадать построчно):

   ```bash
   git ls-remote https://github.com/saymer-alt/keenetic-auto-setup.git refs/heads/main refs/heads/stable 'refs/tags/*' | sort -k2 > /tmp/gh.txt
   git ls-remote https://gitlab.com/saymer-alt/keenetic-auto-setup.git refs/heads/main refs/heads/stable 'refs/tags/*' | sort -k2 > /tmp/gl.txt
   diff /tmp/gh.txt /tmp/gl.txt && echo MIRROR-IN-SYNC
   ```

   Примечание: на GitLab также лежат снимки рабочих веток, скопированные разово
   2026-10-30 (до сужения охвата). Они не обновляются автоматически; их можно
   удалить вручную (Settings → Repository → Branches) либо оставить как архив.

3. Доступность файлов без авторизации (пример для `main`):

   ```bash
   curl -fsSL https://gitlab.com/saymer-alt/keenetic-auto-setup/-/raw/main/bootstrap.sh | head -1
   curl -fsSL https://gitlab.com/saymer-alt/keenetic-auto-setup/-/raw/main/install.sh | head -1
   ```

## Восстановление после сбоя

Сначала открыть упавший запуск Actions — шаг **Diagnose ref drift** печатает, каких
ref-ов не хватает, какие лишние и у каких разошлись SHA.

| Симптом в диагностике | Причина | Действие |
|---|---|---|
| `declined (non-fast-forward)` для ветки/тега | На GitLab вручную создан коммит/тег, которого нет на GitHub | **Перезапись запрещена.** Сравнить `git log` обеих сторон; ценное перенести на GitHub обычным PR, затем удалить лишний ref на GitLab вручную (настройка проекта → Repository → Branches/Tags) и перезапустить sync |
| Secret `GITLAB_MIRROR_SSH_KEY is not set` | Secret удалён/переименован | Заново выполнить `gh secret set GITLAB_MIRROR_SSH_KEY < key-файл` (см. ротацию ниже) |
| `Host key verification failed` | GitLab сменил host-ключи | Сверить отпечатки с https://docs.gitlab.com/user/gitlab_com/ и обновить `known_hosts` в workflow |
| Push падает сетевой ошибкой | Временная недоступность gitlab.com | Повторить: Actions → GitLab mirror sync → **Run workflow** |

После исправления запустить вручную: **Actions → GitLab mirror sync → Run workflow**
(ветка `main`) — workflow запушит `main`, `stable` и теги, отсутствующие или
обновившиеся на GitLab. Если нужно дополнительно отзеркалить рабочую ветку (не
входит в автосинхронизацию), сделайте это разово руками:

```bash
git push git@gitlab.com:saymer-alt/keenetic-auto-setup.git \
  refs/remotes/origin/<branch>:refs/heads/<branch> -o ci.skip
```

## Повторная публикация prerelease-тега и зеркало

Легитимный сценарий: prerelease (например, KAS Web beta.N) публикуется повторно
с более нового коммита `main`, и релизный тег перемещается **вперёд по истории
`main`** (старый таргет остаётся предком нового — никакой history rewrite). GitHub
при этом источник истины, но зеркало начнёт падать при каждой синхронизации:
пуш тега без force не может обновить уже существующий на GitLab тег
(`! [rejected] <tag> -> <tag> (already exists)`).

Это ожидаемое поведение, а не сбой зеркала. Восстановление — только по owner GO:

1. Убедиться, что тег на GitHub перемещён строго вперёд (старый SHA — предок
   нового) и release provenance подтверждён owner-GO запуском
   `Publish KAS WEB beta.N Release` с явным `source_sha`.
2. Проверить отсутствие потребителей старого тега на GitLab: релизы на GitLab
   не публикуются (список релизов пустой), CI отключён (`-o ci.skip`).
   Сохранить старый SHA в issue как архивную точку.
3. Удалить вручную один устаревший тег на GitLab (Settings → Repository → Tags),
   затем **Actions → GitLab mirror sync → Run workflow** — тег будет создан
   заново обычным push (создание, не force). GitHub-тег и релиз не трогать.
4. Проверить `MIRROR-IN-SYNC` (см. «Как проверить состояние зеркала»).

Исторический пример: `v0.1.0-beta.6` перепубликован
`b7d97c297a70c90980d932bf571cd0ff6ee52ad9` →
`070faa90e15855ae6076d8738c5dcec931059a36` 2026-11-03 (issue #388).
*(retired 04.11.2026: GitHub Release object beta.6 удалён; GitHub-тег и GitLab-тег сохранены.)*

Примечание: шаг **Diagnose ref drift** перечисляет все ref-ы GitLab, включая
архивные рабочие ветки вне охвата синхронизации; их расхождение —
информационный шум, блокирует пуш только расхождение `main`, `stable` или тега.

## Ротация и отзыв ключа

Ключ — Deploy Key `github-mirror-sync` в проекте GitLab + secret `GITLAB_MIRROR_SSH_KEY`
на GitHub. Обновление:

```bash
# 1. Новый ключ
ssh-keygen -t ed25519 -f gitlab-mirror-$(date +%Y%m%d) -N "" -C "kas-gitlab-mirror-deploy"

# 2. Зарегистрировать публичную часть в GitLab (с правом push)
glab api -X POST projects/saymer-alt%2Fkeenetic-auto-setup/deploy_keys \
  -f title="github-mirror-sync" -f can_push=true -f "key=$(cat gitlab-mirror-*.pub)"

# 3. Заменить secret на GitHub
gh secret set GITLAB_MIRROR_SSH_KEY < gitlab-mirror-$(date +%Y%m%d)

# 4. Проверить: Actions → Run workflow → зелёный

# 5. Отозвать старый ключ (ID из glab api .../deploy_keys)
glab api -X DELETE projects/saymer-alt%2Fkeenetic-auto-setup/deploy_keys/<ID>
```

Отзыв без замены (= выключение зеркала): удалить Deploy Key в GitLab и/или secret на
GitHub — синхронизация начнёт падать с явной ошибкой, зеркало останется доступным на
чтение.

## Ограничения зеркала

- Копируются только **`main`, `stable` и теги** (полная история коммитов).
  Рабочие ветки не зеркалятся автоматически (см. выше).
- **Не копируются автоматически**: GitHub Releases, Issues, Pull Requests, Discussions,
  артефакты и логи CI, аналитика, wiki. Установка/обновление KAS продолжают пользоваться
  GitHub Releases; зеркало — только просмотр исходников.
- На зеркале нельзя коммитить: любой сторонний коммит на GitLab остановит синхронизацию
  (защита от расхождения).
- Deploy Key действует только на этот проект — даже при компрометации ключ нельзя
  использовать для других репозиториев GitLab.

## Замечание о TLS (для работы `glab` с локальных машин)

`glab` (собран на Go ≥ 1.24) на некоторых сетях зависает с `net/http: TLS handshake
timeout` только для gitlab.com, тогда как curl/браузер работают. Обход: задать
`GODEBUG=tlsmlkem=0` **только для процесса glab** (обёртка/алиас), что отключает
post-quantum key exchange X25519MLKEM768 и уменьшает TLS ClientHello. Причина
(допустим, инспекция TLS на пути) окончательно не доказана — наблюдение задокументировано
без окончательного вердикта. На CI это не влияет: workflow использует SSH, а не HTTPS.

## Доставка скриптов установки через зеркало (Core 1.8.10, issue #232)

Начиная с Core 1.8.10 цепочка установки использует зеркало как **последний,
верифицируемый источник скриптов** (не IPK — их публикация не выполнялась):

```
bootstrap.sh  ->  setup.sh  ->  install.sh / config-import.sh
     |                |                |
     |  GitHub raw -> GitHub raw IPv4/X25519 -> GitHub Contents API
     |                |                |
     |                v                v
     |         (после отказа ВСЕХ GitHub-транспортов)
     |                |                |
     |                v                v
     |     GitLab files API (аттестация: blob_id + size + content_sha256)
     |                |
     |                v
     |     GitLab raw того же ref, та же проверка контракта
     v
(сам bootstrap.sh остаётся принятым first-fetch риском; команда с зеркала —
документированная альтернатива, см. README и 02-quick-start.md)

Первый файл с зеркала (та же команда, что в README/quick-start):

```bash
curl -fSsL https://gitlab.com/saymer-alt/keenetic-auto-setup/-/raw/stable/bootstrap.sh | sh
```
```

### Контракт целостности (обязателен для каждого кандидата)

1. `curl --fail`, bounded `--connect-timeout 7 --max-time 25` (bootstrap) /
   `--connect-timeout 5 --max-time 20` (setup.sh).
2. Кандидат непустой, первая строка `#!/bin/sh`.
3. **Контракт конца файла (EOF/size)**: последняя строка — точный маркер
   `# KAS_EOF_V1` (добавлен в `setup.sh`, `install.sh`, `config-import.sh`).
   Оборванная загрузка маркер сохранить не может, даже если `curl` вышел с 0,
   начало файла и `sh -n` выглядят корректно. Размер-пол (`>= 5000 байт`)
   страхует от грубой подмены; точную полноту обеспечивает маркер.
4. Проектные маркеры скрипта (HTML/JSON/чужой синтаксически валидный shell
   отфильтровываются).
5. `sh -n` — только синтаксис, **не** криптографическая проверка.
6. Для GitLab-этапа дополнительно: скачанные байты должны локально
   воспроизвести аттестацию зеркала — `size`, `content_sha256` (SHA256) и
   git `blob_id` (SHA1 git-объекта; совпадает с GitHub Contents API `sha`
   того же ref). Любое расхождение — fail closed, исполнение не запускается.

### Фактическая матрица доступности (измерено 2026-11-17, анонимные GET)

| Источник | bootstrap.sh | setup.sh | config-import.sh | Примечание |
| --- | --- | --- | --- | --- |
| GitHub raw `stable` | 200, 4214 B, blob `dc379dad…` | 200, 10017 B, blob `9153c8b4…` | 200, 38351 B, blob `9978c9d0…` | основной |
| GitHub Contents API `stable` | 200, `sha` == blob | 200, `sha` == blob | 200, `sha` == blob | транспорт 3 |
| GitLab raw `stable` | 200, 4214 B, blob `dc379dad…` | 200, 10017 B, blob `9153c8b4…` | 200, 38351 B, blob `9978c9d0…` | байты идентичны GitHub |
| GitLab files API `stable` | 200, `blob_id` == GitHub blob, `content_sha256` аттестован | 200, идентично | 200, идентично | `commit_id` = `2fcd1608…` |
| Ref sync | `stable` = `2fcd1608…` на обеих сторонах | — | — | зеркало в синхронизации |
| Ref sync | тег `v1.8.9` = `44c6b901…` на обеих сторонах | — | — | теги синхронны |

Вердикт на момент измерения: предусловие активации зеркала из issue #232
(«доказать совпадение bytes + Git blob / SHA256 с GitHub того же ref»)
выполнено для всех трёх скриптов; GitLab-этап активирован в коде как
последний источник. Измерение точечное — перед каждым релизом повторять
(см. ниже).

### Как перепроверить перед релизом

```bash
for S in bootstrap.sh setup.sh config-import.sh install.sh; do
  curl -fSsL "https://raw.githubusercontent.com/saymer-alt/keenetic-auto-setup/stable/$S" -o "/tmp/gh_$S"
  curl -fSsL "https://gitlab.com/saymer-alt/keenetic-auto-setup/-/raw/stable/$S" -o "/tmp/gl_$S"
  git hash-object "/tmp/gh_$S"; git hash-object "/tmp/gl_$S"
  diff -q "/tmp/gh_$S" "/tmp/gl_$S" && echo "$S: IDENTICAL"
done
git ls-remote https://github.com/saymer-alt/keenetic-auto-setup.git refs/heads/stable
git ls-remote https://gitlab.com/saymer-alt/keenetic-auto-setup.git refs/heads/stable
```

### Ограничения (важно)

- Зеркало — **fallback доступности, не доверенный якорь**: если GitHub
  недоступен, отставшее зеркало честно отдаёт предыдущий (аутентичный)
  коммит `stable`, пока синхронизация не догонит. Гарантия неизменности
  ref даёт закрепление `KAS_BOOTSTRAP_REF=<тег>`: теги неизменяемы и
  синхронизируются тем же workflow.
- Аттестация GitLab проверяет целостность транспорта (обрыв, обрезка,
  подмена при передаче) и внутреннюю согласованность репозитория GitLab,
  но не заменяет отдельный подписанный манифест. Если потребуется полная
  независимость от GitHub — отдельный authenticated immutable trust anchor
  (master plan #233, dependency caveat).
- IPK (Mihomo/MagiTrickle) через GitLab Generic Package Registry и Mos.Hub
  **не публиковались**; исполняемых адресов для них не существует, а
  bootstrap/setup.sh их не используют (master plan #233: «no invented URLs»).
