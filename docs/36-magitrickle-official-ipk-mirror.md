# Зеркало MagiTrickle 0.8.2-2 — официальные Entware IPK без пересборки

**Статус:** prepared in Draft PR; `NOT PUBLISHED` до merge/отдельного manual dispatch. Связанные [#505](https://github.com/saymer-alt/keenetic-auto-setup/issues/505), [#483](https://github.com/saymer-alt/keenetic-auto-setup/issues/483), [#493](https://github.com/saymer-alt/keenetic-auto-setup/issues/493).

## Почему так

Официальный [GitHub release 0.8.2-rev2](https://github.com/MagiTrickle/MagiTrickle/releases/tag/0.8.2-rev2) по состоянию проверки 10.11.2026 — последний в GitHub Releases; только три Keenetic-специфичных Entware IPK (`aarch64-3.10_kn`, `mips-3.4_kn`, `mipsel-3.4_kn`) имеют версию `0.8.2-2`. Сообщение владельца подтверждает отсутствие более нового релиза в его опыте, но **мы не проверили байты и версии текущего `bin.magitrickle.dev` OPKG feed для всех ABI**. В предыдущем полевом отчёте KN-1010 `opkg` устанавливал `0.8.2-1`, поэтому никогда не приравнивайте две ревизии автоматически.

### Содержимое

- `mirrors/magitrickle/0.8.2-2.lock.json` — SHA256, размеры, 3 поддерживаемых `_kn` ABI; generic пакеты не применяются на Keenetic, исходный upstream тег/коммит, лицензия
- `scripts/verify_magitrickle_mirror.py` — безопасный скачиватель с ограниченными попытками + SHA-256/size/IPK control/postinst inspection, не исполняет скрипты и ничего не устанавливает
- `.github/workflows/mirror-magitrickle-ipk.yml` — **только ручная** проверка или публикация. Нет triggers push, pull_request, schedule, release; по умолчанию `verify`
- `mirrors/magitrickle/RELEASE_NOTES.md` — описывает происхождение и ограничения пакетов в будущем GitHub Release

## Безопасный путь к публикации

1. Review Draft PR: точно 3 upstream `_kn` IPK, проверенные official release SHA, источник tag `9337c101...`; без редактирования `AGENTS.md`, `install.sh`, router конфигов или `stable`.
2. Merge **после review и нужного GO** в `main`. Пока workflow отсутствует в default branch, обычный manual dispatcher на GitHub может быть недоступен.
3. В GitHub Actions выбрать `MagiTrickle official IPK mirror (manual)`, operation `verify`. Проверить CI отчёт, `SHA256SUMS`, license/source. Данный запуск **ничего не публикует**.
4. Только после explicit approval запустить operation `publish` **из main**. Workflow повторно проверит staged файлы, создаст **отдельный** релиз `thirdparty-magitrickle-0.8.2-2` c `--latest=false` и тремя IPK `_kn`, SHA256SUMS и соответствующим source archive. Если релиз уже существует, задача прервётся вместо перезаписи.
5. Сверить публичные байты с lock manifest, проверить, что GitHub `latest` для KAS Core не поменялся, `updates-pages` стабильный/experimental не переключился. В отчёте различать `WORKFLOW VERIFIED`, `MIRROR PUBLISHED` и `ROUTER FIELD PASS`.

Это **резервный download**, а не готовая замена репозитория. Чтобы `opkg install magitrickle` автоматически использовал зеркало, нужен отдельный подписанный/проверяемый OPKG feed с `Packages.gz` и безопасным управлением ключом/версиями; в этой работе его **нет**. Для безопасной fallback-интеграции в KAS нужна отдельная задача, без silent downgrade/forced reinstall и с сохранением пользовательского YAML.

## Проверки до полевой интеграции

- [ ] Проверка lock manifest и official GitHub digest каждого ABI с финальным `PASS` в Actions
- [ ] Проверка совпадения upstream source tag, source archive и GPL лицензии
- [ ] Кандидатный mirror release опубликован только отдельным разрешённым ручным запуском
- [ ] Native QEMU (OPKG install/reinstall/upgrade) и реальные маршрутизаторы проверены отдельно: PID магитрикл, порт DNS из конфига, user config preservation и контроль `postinst`
- [ ] В существующем installed state официальный `0.8.2-1` не обновлять/заменять автоматически зеркальной `0.8.2-2` до утвержденного контракта

**НЕ ДЕЛАТЬ:** не создавать автоматический `curl|sh`, не подменять доверенные upstream feed, не скачивать/исполнять IPK на production в рамках верификации, не использовать override TLS. Этот mirror не создаёт самостоятельный MT-C backend.
