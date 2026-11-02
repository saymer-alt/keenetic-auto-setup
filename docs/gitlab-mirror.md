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
