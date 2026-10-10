# GitHub Release Standard

This document is the release-format contract for repositories under `saymer-alt` that publish GitHub Releases. Agents and maintainers preparing a release must follow the applicable profile below.

## 1. Core rules for every release

1. **Do not duplicate the release title inside the body.** GitHub already renders the Release name as the page heading. The body MUST NOT start with `# vX.Y.Z ...`, `## vX.Y.Z ...`, or another heading that repeats the Release name/tag.
2. **Release name and tag are separate fields.** The tag stays machine-oriented (`vX.Y.Z`, `mipsel-vX.Y.Z`, `latest`, etc.); the Release name is the human-facing title.
3. **The body starts with content, not a repeated heading.** Start with a 1–2 sentence summary or directly with the first `##` section.
4. **Omit empty sections.** Do not add headings with no useful content.
5. **Do not silently change history.** Historical Release cleanup may reformat title/body only; never move/recreate tags or change the commit they identify just for presentation.
6. **Release provenance must be explicit.** A versioned production release must identify the tested production state/tag; an automated artifact release must identify its build source/version when useful.
7. **CHANGELOG is the detailed source of truth when the repository has one.** The GitHub Release should summarize the version for humans, not become a second divergent changelog.

## 2. Profile A — human-facing versioned release

Use this profile for ordinary project releases such as `link-generators`, `keenetic-auto-setup`, and `amnezia-mihomo-gateway`.

### Release name

Preferred format:

```text
vX.Y.Z — Короткое название релиза
```

Keep it concise. Russian is preferred for owner-facing projects; established technical names and protocol terms may remain in English.

### Body structure

Start with a short summary paragraph. Then use the following section order where applicable:

```markdown
Короткое описание релиза в 1–2 предложениях.

## Главное

## Добавлено

## Изменено

## Исправлено

## Безопасность

## Проверено

## Совместимость и границы
```

Rules:
- use `##` for top-level body sections;
- do not repeat `vX.Y.Z` as a heading in the body;
- omit sections that do not apply;
- put user-visible impact before implementation trivia;
- large file/line-count statistics belong in PRs/CHANGELOG unless they materially help users;
- state limitations honestly under `Совместимость и границы` rather than implying untested support.

### Provenance footer

For repositories with a `main → stable → release` model, end with a concise provenance statement, for example:

```text
Тег vX.Y.Z соответствует протестированному stable abc1234.
```

The tag must point to the same production state that was accepted by the release process.

## 3. Profile B — automated artifact/feed release

Use this profile for repositories where Releases primarily distribute build artifacts, package feeds, rolling assets, or architecture-specific binaries (for example `mihomo-auto-build` and `entware-go`).

The human-release section order is NOT mandatory. Automation may keep a compact technical body.

Still mandatory:
- no duplicated Release-name heading in the body;
- stable, deterministic Release naming;
- build/upstream version and architecture/source are clear;
- asset/install information is concise and current;
- automated workflows must not inject an H1/H2 that repeats the Release name.

Suggested structure when a body is useful:

```markdown
Short build/feed summary.

## Build

## Assets

## Install / Usage

## Verification / Compatibility
```

Rolling releases such as `latest` may keep the machine-oriented Release name `latest`; do not fabricate semantic versions only to satisfy presentation consistency.

## 4. Legacy placeholder releases

Repositories with an old non-versioned placeholder Release such as `Releases` do not need history rewritten merely to comply with this document. If normal versioned releases resume, use Profile A from that point onward.

## 5. Release creation checklist

Before publishing a human-facing versioned release:

- [ ] exact release commit/state has passed the repository's required CI/tests/field gates;
- [ ] production branch/promotion requirements are satisfied where applicable;
- [ ] tag points to the accepted production commit;
- [ ] Release name follows the repository profile;
- [ ] body does not repeat the Release name/tag as an H1/H2;
- [ ] body uses the standard section order, omitting empty sections;
- [ ] claims match actual tested behavior;
- [ ] secrets/private endpoints are absent;
- [ ] provenance/limitations are stated;
- [ ] GitHub Release is published only after the repository's release invariant allows it.

## 6. Historical cleanup policy

It is allowed to normalize old GitHub Release pages later, but only as **metadata/presentation cleanup**:

- remove duplicated first H1/H2 headings;
- normalize Release names where safe;
- normalize section headings/order without changing historical meaning;
- preserve tag, target commit, publication semantics, assets, and factual content.

Historical cleanup is never a reason to retag an old version.
