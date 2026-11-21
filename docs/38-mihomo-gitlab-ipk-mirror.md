# GitLab-зеркало проектных Mihomo IPK — подготовка

**Статус:** `DESIGN + VERIFIED SNAPSHOT; NOT PUBLISHED; NO URL VALIDATED; install.sh НЕ меняется`.

## Что сделано (12.11.2026, Agent D)

1. **Verified snapshot.** `mirrors/mihomo/1.19.34-2.lock.json` — 5 артефактов текущего
   официального релиза [`saymer-alt/entware-go` `latest`](https://github.com/saymer-alt/entware-go/releases/tag/latest)
   (2026-05-16): `mihomo 1.19.34-2` для `aarch64-3.10`, `armv7-3.2`, `mips-3.4`,
   `mipsel-3.4` + `mihomo_nohf` (`Package: mihomo_nohf`, тот же `armv7-3.2`).
   Все 5 скачаны и независимо хешированы; control-поля проверены
   (`Depends: ca-bundle`; базовое имя пакета совпадает с существующими basename
   путями KAS, т.е. совместимо с будущим Asset-API fallback).
2. **Fail-closed верификатор** `scripts/verify_mihomo_mirror.py`: pinned allowlist
   ровно одного reviewed-снапшота; drift size/SHA/architecture или чужой manifest
   отвергаются; контроль `control`-полей; `--offline` для re-check staged файлов.
   Локально проверено на реальных байтах: 5/5 PASS; drift-и tamper-негативы — FAIL
   (ожидаемо).
3. **Конфигурация публикации** `mirrors/mihomo/GITLAB-PUBLISH.md`: точные owner-GO
   команды GitLab Generic Package Registry (проект-приёмник публичный), anti-overwrite
   guard, versioned URL `.../packages/generic/kas-mihomo-mirror/1.19.34-2/<file>`
   (движущийся upstream-тег `latest` никогда не проецируется в имя версии),
   обязательная анонимная обратная проверка `sha256sum -c` + BusyBox wget-совместимость.

## Что НЕ сделано сознательно

- Публикация (нужен owner GO + PAT): см. GITLAB-PUBLISH.md.
- Изменения `install.sh`/`update-mihomo.sh`: по контракту Issue #19 URL прописывается
  только после существования и live-проверки HTTPS URL; отдельный PR, не смешивать
  с MagiTrickle-зеркалом (docs/36) и с updater'ом.
- OPKG feed (`Packages.gz`) — не создаём; это Generic Package Registry.

## Риски/открытые вопросы для review

- Anonymous download GitLab generic packages: публичность проекта обязательна;
  возможны подписанные CDN-редиректы — итоговая проверка должна быть по телу
  (200 + размер + SHA), а не по коду промежуточного ответа. Реальная проверка
  BusyBox wget — на этапе Шага 2 (требует доступа к Entware-окружению/QEMU).
- Если upstream перевыпустит тег `latest` с новыми байтами, snapshot в этом PR
  останется валидным как исторический снапшот, но для **новой** версии нужен новый
  reviewed manifest (автоматического отслеживания нет и не планируется).
- Квоты GitLab free: ~13 MB × 5 файлов на пакет — в лимитах.

## Чек-лист до FIELD

- [ ] Owner GO: проект + PAT + публикация по Шагу 1
- [ ] Шаг 2: анонимный `sha256sum -c` OK + BusyBox wget 200/размер/SHA
- [ ] Отдельный PR с URL в `install.sh` (после live-валидации)
- [ ] Native/QEMU и FIELD — отдельно, по общим правилам KAS
