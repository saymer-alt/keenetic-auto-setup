# GitLab-зеркало Mihomo IPK (Issue #19) — конфигурация и точные команды для owner GO

**Статус:** `PREPARED, NOT PUBLISHED, NO URL VALIDATED`. Публикация — только владелец
(GitLab PAT scope `api`). Не смешивать с зеркалом MagiTrickle (docs/36 +
`mirrors/magitrickle/GITLAB-PUBLISH.md`): отдельный проект, отдельные URL, отдельный GO.

Каноническая процедура публикации — скрипт
`scripts/publish-mihomo-gitlab.sh`. Он реализует fail-closed контракт, описанный
ниже; ручные ad-hoc команды `curl --user "name:<PAT>"` из прежней версии этого
документа **удалены** (PAT попадал в argv процесса и в историю shell).

## Что публикуем

Ровно **шесть** файлов из verified snapshot `mirrors/mihomo/1.19.34-3.lock.json`
(пять IPK + `SHA256SUMS`; скачаны из официального релиза `saymer-alt/entware-go`
`latest` и независимо хешированы 19–20.11.2026; control-поля проверены:
`Package: mihomo` / `mihomo_nohf`, `Version: 1.19.34-3`, `Depends: ca-bundle`;
sizes/SHA256 перепроверены против GitHub API asset digests 20.11.2026). Это первый
снапшот с упакованным `S28mihomo` (ee4b689, network-service ordering): `data.tar.gz`
содержит ровно `./opt/etc/init.d/S28mihomo` и не содержит `S99mihomo` —
`scripts/verify_mihomo_mirror.py` проверяет data-level init identity для
каждого reviewed снапшота:

| ABI | Файл | SHA256 |
|---|---|---|
| aarch64-3.10 | `mihomo_1.19.34-3_aarch64-3.10.ipk` | `8b4f4b5b…73f07` |
| armv7-3.2 | `mihomo_1.19.34-3_armv7-3.2.ipk` | `f93b1937…ec2d9` |
| mips-3.4 | `mihomo_1.19.34-3_mips-3.4.ipk` | `3b06d541…048b` |
| mipsel-3.4 | `mihomo_1.19.34-3_mipsel-3.4.ipk` | `3176e3f4…948f` |
| armv7-3.2 (nohf) | `mihomo_nohf_1.19.34-3_armv7-3.2.ipk` | `7ae72258…6283` |

Полные SHA256 — в lock manifest. Повторная сборка не выполняется: это **те же байты**
официального релиза `entware-go`.

Snapshot `1.19.34-2` (`S99mihomo`, манифест `1.19.34-2.lock.json`) —
SUPERSEDED: не публиковать без отдельного owner GO; остаётся reviewed
историей для verify-скрипта. Апстрим-ассет `mihomo_1.19.34-3_x64-3.2.ipk`
существует, но намеренно вне router-области зеркала (как и в снапшоте -2).

## Версионирование: НЕ `latest`

Upstream-тег `latest` — движущийся, а его REST-указатель `releases/latest`
может быть перехвачен более новым архивным релизом (entware-go issue #71).
GitLab-публикация использует **фиксированную** версию пакета `1.19.34-3`
(соответствует `Package/Version` внутри IPK): URL содержит
версию, metadata не может разойтись с payload. Каждая новая сборка upstream — новый
reviewed manifest и новая версия пакета на GitLab; перезапись опубликованных версий
запрещена (см. классификацию состояний ниже).

## Классификация состояний (fail-closed контракт)

Любой ответ на pre-publish probe трактуется строго:

| Ответ | Интерпретация | Действие |
|---|---|---|
| `404` (подтверждённый) | файл не опубликован | продолжать; публиковать можно только если **все 6 файлов** подтвердили 404 |
| `200` | версия уже существует — полностью или частично | **ABORT** (exit 2). Никогда не перезаписывать, никогда не «чинить» частичную публикацию удалением файлов — решает owner |
| `401/403` | PAT невалиден или нет доступа | **STOP** (exit 1) — состояние неизвестно |
| `429/5xx`, обрыв соединения, DNS/TLS ошибка | состояние неизвестно | **STOP** (exit 1). Любой отказ curl ≠ «не опубликовано» |

Отдельно: `PUT` должен вернуть `201`; иное — «публикация НЕЗАВЕРШЕНА», STOP.
Повторный запуск скрипта после незавершённой публикации безопасен по построению:
probe увидит `200` у уже загруженных файлов и откажется продолжать.

## Шаг 0 — предусловия

1. Публичный проект-приёмник на GitLab (рекомендация: `saymer-alt/entware-go-ipk-mirror`,
   visibility Public — обязателен для анонимного wget/curl с роутера; скрипт
   проверяет visibility и отказывается публиковать в непубличный проект).
   Project ID — на главной странице проекта.
2. Verified-файлы: `python3 scripts/verify_mihomo_mirror.py --manifest
   mirrors/mihomo/1.19.34-3.lock.json --output <bundle>` (скачает и проверит 5 файлов,
   включая data-level init identity `S28mihomo`), либо проверенные локально копии
   с совпадающими SHA256. Скрипт публикации перед любым PUT сверяет бандл не
   только с его собственным `SHA256SUMS` (допускает генерацию sums из уже
   проверенного бандла), но и с независимым доверенным lock-манифестом — тем же
   `verify_mihomo_mirror.py --offline`. Если подменены и IPK, и `SHA256SUMS`
   одновременно, публикация откажется (exit 3) до любого сетевого действия.
   Нужен `python3` на машине владельца (WSL Ubuntu подходит).
3. PAT `api`, минимальный срок. **Правила обращения (обязательны):**
   - PAT в Git, в CI, в логах, в stdout/stderr — запрещён;
   - PAT передаётся только через файл с правами `0600`, путь — в переменной
     `KAS_GITLAB_PAT_FILE`;
   - скрипт передаёт секрет в curl исключительно через временный конфиг
     `--config` с правами `0600`, который удаляется на любом выходе (trap);
     ни одна команда curl не получает `--user` в argv — секрет не виден в
     `/proc/<pid>/cmdline` и не попадает в историю shell;
   - `set -x` / `bash -x` во время работы с секретом — запрещён;
   - по завершении удалить файл PAT; в этом документе и в отчётах реальные
     секреты не приводятся.

## Шаг 1 — публикация (owner, локально на Linux; протестировано в WSL Ubuntu)

Запуск из корня репозитория. `export` обязателен: скрипт читает переменные из
окружения дочернего процесса, а простые присваивания без `export` в дочерний
`sh` не попадают (скрипт увидит пустые `PROJECT_ID`/`BUNDLE_DIR` и откажется
на preflight — это проверено синтетическим тестом).

```sh
export GITLAB_HOST="https://gitlab.com"
export PROJECT_ID="<numeric project id>"
export BUNDLE_DIR="<bundle>"               # каталог verified bundle
export KAS_GITLAB_PAT_FILE="$HOME/.kas-gl-pat"   # 0600, вне репозитория, удалить после

sh scripts/publish-mihomo-gitlab.sh
```

`KAS_LOCK_MANIFEST` по умолчанию указывает на
`mirrors/mihomo/1.19.34-3.lock.json` относительно каталога самого скрипта —
переопределять его без причины не нужно.

Коды выхода: `0` — опубликовано и анонимно верифицировано; `1` — STOP
(неизвестное состояние, не повторять вслепую); `2` — ABORT (версия уже
существует полностью/частично); `3` — preflight отказ (env/PAT/бандл/
несовпадение с lock-манифестом).
Скрипт выполняет: сверку бандла с независимым lock-манифестом → проверку
проекта и visibility → probe всех 6 файлов (только подтверждённые 404
позволяют продолжить) → PUT пяти IPK и затем `SHA256SUMS` как commit-marker
(ожидаемый код `201`) → обязательную анонимную обратную проверку каждого
файла (HTTP 200 + побайтовое равенство с бандлом). Локальный `http://`-override
разрешён только для loopback-хостов и существует исключительно для
синтетических тестов.

## Шаг 2 — обратная проверка (обязательна, анонимно, как роутер)

### 2a. Полная верификация против reviewed manifest

Блок самодостаточный (переменные задаются заново). Абсолютный путь к корню
репозитория сохраняется **до** `cd verify-mihomo` — после перехода
относительные пути `scripts/…` и `mirrors/…` перестали бы указывать на репозиторий.

```sh
export GITLAB_HOST="https://gitlab.com"
export PROJECT_ID="<numeric project id>"
REPO_ROOT="$(pwd)"                          # выполняется из корня репозитория

mkdir -p verify-mihomo && cd verify-mihomo
for f in mihomo_1.19.34-3_aarch64-3.10.ipk mihomo_1.19.34-3_armv7-3.2.ipk \
         mihomo_1.19.34-3_mips-3.4.ipk mihomo_1.19.34-3_mipsel-3.4.ipk \
         mihomo_nohf_1.19.34-3_armv7-3.2.ipk SHA256SUMS; do
  code=$(curl -sS -L -o "$f" -w '%{http_code}' --proto =https --proto-redir =https \
    "${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}/packages/generic/kas-mihomo-mirror/1.19.34-3/$f")
  [ "$code" = "200" ] || { echo "FAIL $f: HTTP $code"; exit 1; }
done
sha256sum -c SHA256SUMS     # ВСЕ OK, иначе публикация считается несостоявшейся
# Проверка Package/Version/Architecture/Depends/S28 против доверенного manifest:
python3 "$REPO_ROOT/scripts/verify_mihomo_mirror.py" --manifest \
  "$REPO_ROOT/mirrors/mihomo/1.19.34-3.lock.json" --output "$(pwd)" --offline
```

`--offline` повторно проверяет size, SHA256 и data-level init identity
(`S28mihomo`) скачанных файлов против reviewed manifest — та же цепочка
доверия, что и при подготовке бандла.

### 2b. BusyBox-совместимость анонимного скачивания

Реальный Entware/BusyBox wget или `busybox wget -q -T 20 -O /dev/null <URL>`:
200, не HTML, не логин-редирект. GitLab может отдавать anonymous generic-package
downloads через подписанные ссылки (consolidated CDN) — на роутере важен
итоговый HTTP 200 c корректным телом, а не код промежуточного редиректа.

## Шаг 3 — только после шага 2

1. Записать в Issue #19: `MIRROR PUBLISHED (GitLab mihomo) 1.19.34-3, URL..., SHA256...`.
2. Отдельным PR (не этим!) прописать URL в `install.sh` между GitHub Asset API и
   последним `opkg install mihomo` — по контракту Issue #19: exact basename, verified
   ABI, size/sha256, HTTPS, без `curl -k`, отказ GitLab = fallback, а не proof failure.
3. `update-mihomo.sh` не менять в том же PR (отдельное проектное решение).

## Синтетические отрицательные тесты (без реального PUT)

`tests/publish-mihomo-gitlab-regression.py` гоняет реальный скрипт против
loopback-симулятора GitLab: happy path (все 404 → 6 PUT → анонимная
верификация, байты побайтово совпадают), частичная публикация (любой 200 →
ABORT, ноль PUT), неизвестное состояние (500/403/обрыв соединения → STOP,
ноль PUT), непубличный проект и отказ PAT (→ STOP, ноль PUT), отказ PUT
посреди публикации и безопасный повторный запуск (→ ABORT вместо
перезаписи), подмена SHA256SUMS в бандле (→ отказ до любого HTTP), запрет
`--user`/DELETE в исходнике, отсутствие секретов в выводе, очистка
временного 0600-конфига, несовпадение анонимных байтов (→ STOP).
Дополнительно 21.11.2026: документированный запуск Шага 1 в форме `export`
воспроизведён буквально (exit 0, 6 PUT) против loopback-симулятора; та же
команда без `export` отказывает на preflight (exit 3, ноль HTTP) — это и есть
почему `export` обязателен; подмена IPK с перегенерированным `SHA256SUMS`
отказывается гейтом lock-манифеста до любого HTTP; override верификатора
вне loopback-хоста отказывается; Шаг 2a выполняется из реально созданного
каталога `verify-mihomo` (пути к `scripts/verify_mihomo_mirror.py` и
`mirrors/mihomo/1.19.34-3.lock.json` резолвятся через абсолютный `REPO_ROOT`).
Результат 21.11.2026: WSL Ubuntu — ALL PASS; Windows/MSYS —
универсальная часть OK, mode-зависимые сценарии честно SKIP (эмуляция
POSIX-прав 0600 невозможна; см. NOTE в выводе теста).

## Ограничения

- Generic Package Registry, не OPKG feed (`Packages.gz` нет).
- Файлы ~13 MB × 5 — лимит GitLab free (5 GB/package) не задет.
- Никаких auto-publish из CI; только ручной owner-запуск.
- Между probe и PUT существует теоретическое окно TOCTOU (одновременная
  публикация тем же owner с другой машины); риск принят и задокументирован —
  GitLab generic registry в этой схеме пишет только owner.
- KAS Asset API совместимость: имена файлов сохранены ровно как в upstream release,
  поэтому существующие `install.sh`-пути (basename) валидны и для зеркала.
