# KAS WEB release hygiene inventory — 30 Oct 2026

**Scope:** repo `saymer-alt/keenetic-auto-setup`, preparation for beta2. User requests cleanup and consolidation; this source-pinned snapshot is a rollback ledger, not a mandate to delete every historical asset.

## Current inventory

- **60 branches**, **34 releases** (16 pre-releases, 18 ordinary), **38 open PRs**. Exactly **12 `publish/*` branches**; **9** have immutable matching Git tags and no open PR head/base, **3** have no matching tag (KEEP pending research).
- Full all-time PR scan was separately performed across pages 1–4 (232 PRs); **none of the `publish/*` branches are PR head/base**. Existing stacked WEB Draft PRs must remain until consolidated integration PR is validated.
- Source of public WEB beta1: `92e301da2464ac9694fff3f41f4ee1cb9be90708`. Active experimental release/index `kas-web-channel-experimental` points to `kas-web-ipk-92e301d`. Do not delete either.
- Separate KAS Core latest release `v1.8.4`. No main/stable merge or latest reassignment is in this cleanup.

## Reversible first batch: 9 publish-only *branch refs* (tags untouched)

| Branch ref | Exact SHA | Immutable Git tag (must match) |
|---|---|---|
| `publish/kas-web-ipk-08ae70e` | `bf0bccf6a0cc292e0d454faefa49e11e4e7e45a9` | `refs/tags/kas-web-ipk-08ae70e` |
| `publish/kas-web-ipk-57ea99c` | `c63e0e42598380b0b24848eb626be1f77248c838` | `refs/tags/kas-web-ipk-57ea99c` |
| `publish/kas-web-ipk-66d976e` | `6f8fd2075ba9dc4718dd8bf3a74567689f32f933` | `refs/tags/kas-web-ipk-66d976e` |
| `publish/kas-web-ipk-77ac40e` | `2baeed4d880471ff6aa630d6ef04c46c0ea548da` | `refs/tags/kas-web-ipk-77ac40e` |
| `publish/kas-web-ipk-894a524` | `bf471e7b7c26de4f1b0d018c976e113a6e169e10` | `refs/tags/kas-web-ipk-894a524` |
| `publish/kas-web-ipk-b0e3c0c` | `71f88fa86c06de76904e65d7aeb2428b00e8d260` | `refs/tags/kas-web-ipk-b0e3c0c` |
| `publish/kas-web-ipk-c0dac74` | `ea669c18ee2d985bce11b8ad67270f47d931b9f6` | `refs/tags/kas-web-ipk-c0dac74` |
| `publish/kas-web-ipk-c3cc2ce` | `4e62cdc199aa462e7af34f4e7fe6b3398a33bf73` | `refs/tags/kas-web-ipk-c3cc2ce` |
| `publish/kas-web-kn1010-ui-66ab147` | `a35624b9c6dfee160c903093e2cf7edd6d30f006` | `refs/tags/kas-web-kn1010-ui-66ab147` |

**Rollback:** use `git push origin SHA:refs/heads/REF` or GitHub's create branch from exact SHA above; underlying Git tag remains immutable and points to same object. The cleanup workflow refuses any mismatch, active PR base/head, missing matching tag, or changed branch SHA. It doesn't delete GitHub Releases, tags or build assets.

## KEEP: unmatched publish branches pending evidence

- `publish/kas-web-ipk-c8f7c58` → `991b1fd2c1d117dfcfb0d19e9193eefa79c4bd48`: no independent matching immutable Git tag; needs further reachability analysis before deletion.
- `publish/kas-web-ipk-checksums-c0dac74` → `6b21edd939d67555b17292a07e93f3beb8c2ba73`: no independent matching immutable Git tag; needs further reachability analysis before deletion.
- `publish/kas-web-ipk-control` → `5b2d2cfc19adf802cf0db81227836335e2b2fc18`: no independent matching immutable Git tag; needs further reachability analysis before deletion.

## GitHub prereleases (preserve release assets for now)

| Tag | Published | Downloads (sum across assets) | Binary assets | First-pass decision |
|---|---|---:|---:|---|
| `v0.1.0-beta.1` | 2026-10-30T08:27:35Z | 5 | 5 | KEEP |
| `kas-web-ipk-9c71528` | 2026-10-30T07:06:59Z | 6 | 5 | KEEP |
| `kas-web-ipk-92e301d` | 2026-10-30T08:34:32Z | 1 | 5 | KEEP |
| `kas-web-channel-experimental` | 2026-10-30T07:07:03Z | 3 | 1 | KEEP |
| `kas-web-ipk-c3cc2ce` | 2026-10-29T07:04:43Z | 7 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-b0e3c0c` | 2026-10-29T12:37:54Z | 7 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-894a524` | 2026-10-29T06:21:49Z | 7 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-77ac40e` | 2026-10-29T13:48:28Z | 7 | 5 | KEEP |
| `kas-web-ipk-66d976e` | 2026-10-29T10:28:12Z | 6 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-57ea99c` | 2026-10-29T09:16:05Z | 6 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-08ae70e` | 2026-10-29T08:23:11Z | 6 | 5 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-kn1010-ui-66ab147` | 2026-10-28T13:36:32Z | 4 | 2 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-kn1010-sstp-58ff21d` | 2026-10-28T12:54:35Z | 4 | 2 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-kn1010-ef63bcc` | 2026-10-28T12:31:18Z | 5 | 2 | CANDIDATE LATER — source/tag/asset dependency check |
| `kas-web-ipk-c0dac74` | 2026-10-28T15:38:55Z | 14 | 5 | KEEP |
| `kas-web-ipk-62a97a3` | 2026-10-30T03:37:54Z | 6 | 5 | KEEP |

**Candidate releases for a later carefully reviewed batch:** `kas-web-ipk-c3cc2ce`, `kas-web-ipk-b0e3c0c`, `kas-web-ipk-894a524`, `kas-web-ipk-66d976e`, `kas-web-ipk-57ea99c`, `kas-web-ipk-08ae70e`, `kas-web-kn1010-ui-66ab147`, `kas-web-kn1010-sstp-58ff21d`, `kas-web-kn1010-ef63bcc`. Their binaries are **not** deleted by this plan. Download counts are NOT proof of deployed users; read-only snapshots don't establish that a release is unused. Before deleting a Release: archive exact metadata+checksums, prove no active channel points there, map external docs/CI/issue links, and keep annotated source Git tags even if release assets are retired.

## Integration and beta2

- Integration base: [Draft PR #291](https://github.com/saymer-alt/keenetic-auto-setup/pull/291), squash-consolidated from beta1 on latest main; code review/test required before merging.
- Functional milestone: [#289](https://github.com/saymer-alt/keenetic-auto-setup/issues/289) — user-facing beta2 selects experimental vs stable and supports beta2→beta3→stable manual WEB self-update; beta1 installed only on owner's test KN-1010, one-time manual transition allowed.
- Cleanup coordination: [#282](https://github.com/saymer-alt/keenetic-auto-setup/issues/282), [#290](https://github.com/saymer-alt/keenetic-auto-setup/issues/290). Keep all active web updater index assets, field-test tags, core releases, primary branch history, and open PR bases/heads.

## What must **not** be done by first branch batch

Do not merge/force-push `main`/`stable`, close PRs, delete release objects or asset files, reassign `latest`, rotate channel pointers, upgrade routers, or delete Git tags.
