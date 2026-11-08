# KAS Issue claim/lease prototype — #461 / #456

**Stage A: MOCK ONLY.** No GitHub writes, CLI integration, model calls, credentials,
background task, scheduler, or auto-recovery. The Python module is an independent
protocol kernel; it is **not** wired into `scripts/orchestration-poc/` while #454/#458
is being reviewed. No lease is actually enforced across machines yet.

Run tests without network:

```bash
python -m unittest discover -s scripts/orchestration-lease/tests -v
```

## Contract

- One `implementer` per `(repo, issue)`; a second claimant always receives
  `STOP_DUPLICATE`. Independent reviewer may **read** but not acquire an
  implementer lease. If a claim's TTL expires, any claimant receives
  `STOP_EXPIRED_NEEDS_OWNER`, never automatic takeover.
- `claim` creates a unique 32-character `run_id`, a monotonically increasing
  `generation`, and a 60–3600 second lease. A released lease uses an append-only
  tombstone and can be claimed again with a new generation.
- `renew` rotates the revision (fencing token); **every external side effect
  requires a fresh `fence(snapshot)` check**, current OPEN Issue, exact worker,
  run and revision, and a non-expired lease. An old lease cannot release or
  authorize a new one. This is cooperative fencing, NOT an OS sandbox.
- On error/malformed state/Issue closed or moved/network outage/expired lease,
  **STOP**. No `force` ref changes, silent repair, or retry loops. Future owner
  recovery must verify the previous process stopped before allowing a new
  generation. `recover()` is disabled in Stage A.

## GitHub transport design (future Stage B: separate GO)

GitHub Issue comments/labels are **not atomic locks**. Future transport must
create an exclusive Git ref under e.g. `refs/heads/kas-orch-claims/issue-<N>`
using GitHub `POST /git/refs` (only one creation succeeds). Store the lease JSON
as a commit message. Renew/release by creating an append-only commit with the
current ref commit as parent, then `PATCH /git/refs/...` with `force=false`;
competing updates from the same parent are siblings and cannot both fast-forward.
Use **fail-closed** behavior on ambiguous GitHub/network results and verify
current ref/commit after each operation. If the authenticated connector offers
explicit `expected_sha` compare-and-swap, require it as well. Never delete a
lock ref to release; retain a tombstone so an old agent cannot unknowingly
recreate the same ref. Limit claim branch permissions and prevent untrusted
users rewriting those refs. GitHub branch-ref update is only a protocol
building block, not a proof that the eventual deployment is safe.

### Boundaries of this implementation

`MemoryCASStore` is a **thread-safe test double in one Python process**, not
cross-host synchronization. Stage B still needs an independently reviewed
GitHub-backed transport, a real fencing gate in the executor before **each**
write, owner-scoped recovery and a single controlled live claim test. Stage C
can wire claim checks into the existing Issue→contract→dispatch→checkpoint
flow after #454; do not modify that active POC concurrently.

**No merge, live claim, release or production dispatch without owner GO.**
