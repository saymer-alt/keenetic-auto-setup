# KAS Agent Orchestration POC (issue #430) — launch / disable

Read-only transport of one GitHub Issue into a validated task contract and a
structured checkpoint, with a dry-run executor. **No server, no daemon, no
webhook, no new Actions, no API token handling** — `gh` provides auth from its
existing keyring.

## Requirements

- Python 3.12+ (stdlib only), `gh` CLI authenticated (`gh auth status`).
- Optional executor: ZCode desktop install (see `docs/agent-orchestration-poc.md`
  for the verified CLI facts and the current model-selection limitation).

## Run

```bash
cd <KAS checkout>

# 1. Fetch and validate exactly one issue (read-only GitHub call)
python scripts/orchestration-poc/kas_orchestrate.py --repo-path . \
  --state-dir "$TEMP/kas-orch" fetch --issue 430

# 2. Hand off to the executor (dry-run prints the exact command; nothing runs)
python scripts/orchestration-poc/kas_orchestrate.py --repo-path . \
  --state-dir "$TEMP/kas-orch" dispatch --executor dry-run

# 3. Produce the structured checkpoint (local file, not posted)
python scripts/orchestration-poc/kas_orchestrate.py --repo-path . \
  --state-dir "$TEMP/kas-orch" checkpoint --status NOT_TESTED \
  --evidence "path/to/artifact" --blocker "..." --next "owner decision"

# 4. Clear local state when done
python scripts/orchestration-poc/kas_orchestrate.py --repo-path . \
  --state-dir "$TEMP/kas-orch" reset --confirm
```

`--json` makes every command machine-readable **on the local PC**. The output
is not automatically visible to ChatGPT: until a safe GitHub checkpoint writer
is accepted under a separate GO, automatic result handoff remains NOT_VERIFIED.

## Executors

- `dry-run` (default): print the exact executor command, run nothing.
- `mock`: simulated successful dispatch for tests; no model call.
- `zcode-cli`: build and run the headless command **always with `--mode plan`**
  (yolo/build/edit are refused by construction). Currently BLOCKED end-to-end:
  headless model selection needs the standalone credential identity pointer
  (`account-provider:account:<providerId>:identity`), which this machine does
  not have — the CLI falls back to the first personal provider rule or fails
  with "Select a model". Any credential fix is a separate owner GO — see the
  docs file and Issue #430 for GO-A/GO-A2. GO-A3 ended `FAILED_AUTH_TIMEOUT`
  without completing OAuth sign-in or changing saved credentials. No further
  login/credential edits or API usage are authorized by this POC.

## Safety properties

- One active task; each fresh fetch generates a unique random `run_id` even
  when the deterministic `task_id` and base SHA repeat; duplicate dispatch
  and re-fetch while active → `STOP_*`;
  an OS-level interprocess lock (`fcntl`/`msvcrt`) serializes all commands per
  state dir and is released automatically if a process dies (`STOP_LOCKED`).
- GitHub account must equal the repository owner (`gh api user`) and the issue
  payload schema is validated (number/title/body/url/updatedAt) — malformed
  data fails closed (`STOP_BAD_ACCOUNT`, `STOP_MALFORMED_ISSUE`).
- Repo owner allowlist; issue must be `OPEN`; the issue's **exact** URL and
  requested number must match. The contract saves the original `updatedAt`;
  before **every real dispatch** (`mock` or `zcode-cli`) the Issue is
  fetched again, and a closed, replaced or edited Issue stops **before** any
  executor runs (`STOP_ISSUE_CLOSED`, `STOP_MALFORMED_ISSUE`,
  `STOP_ISSUE_CHANGED`, or `STOP_NETWORK`).
- The checkout HEAD is also re-verified against the contract base SHA before
  dispatch AND checkpoint (`STOP_STALE_SHA`). `dry-run` only reads the cached
  Issue contract and does not start a model.
- Issue body is capped at 50 KB with an explicit truncation marker.
- `dry-run` never claims the task (state stays READY). Real executors run with
  `ELECTRON_RUN_AS_NODE=1` and `--mode plan` only; a non-zero executor exit
  code or timeout moves the task to BLOCKED (`STOP_EXECUTOR_FAILED` /
  `STOP_EXECUTOR_TIMEOUT`). Manual `checkpoint --status PASS` additionally
  requires REVIEW_READY and a matching task_id **and run_id** journal record
  of successful real `zcode-cli` execution after the corresponding fetch
  (`STOP_PASS_UNEARNED`). Missing/legacy run IDs, mock/dry-run or historical
  successes retained by reset cannot earn PASS. Executor exit 0 is not proof
  of validated implementation, CI or real-device FIELD PASS.
- Earned-PASS validation executes **before** any prospective posting, and a
  guarded publisher (issue #454) posts only `BLOCKED`/`NOT_TESTED` via one
  `gh issue comment` (body via stdin, never argv): triple opt-in
  (`--post` + `--confirm` + `KAS_ORCH_ALLOW_WRITE=1`), then a status
  allowlist, then the module constant `LIVE_POST_ENABLED` (default **False**)
  as the sole live-write switch until owner GO-B. Pre-write re-verification
  covers auth, account, repo allowlist, Issue OPEN/exact URL/updatedAt,
  task_id + run_id (matching the latest `fetched` journal event) and
  `base_sha == HEAD`; a marker `[KAS-ORCH: checkpoint marker …]` scanned
  across **all** comment pages makes re-runs idempotent (`already_posted`,
  no second comment) and unreadable comments STOP the post. Payload is a
  short normalized checkpoint explicitly marked "local agent message,
  unvalidated — not CI", bounded in size, secret-scanned, and refused when
  it contains any `PASS`/`CI PASS`/`FIELD PASS` token. Network uncertainty
  after a post attempt → `STOP_POST_UNCERTAIN`, manual verification, no
  auto-retries. Milestones stay separate: `MOCK_WRITER_PASS` (64 mock tests)
  ≠ `LIVE_CHECKPOINT_POST_NOT_TESTED` (no live write has been performed).
- Exit codes: `0` OK, `2` STOP (safe refusal), `1` internal error.

## Tests (no network, mock GitHub)

```bash
python -m unittest discover -s scripts/orchestration-poc/tests -v
```

The 64-test mock suite (issue #454 expanded the 39-test set by 25) covers the
happy path and negative cases: stale SHA at dispatch/checkpoint/post; an Issue
closed, edited, renumbered, or unreachable after fetch and at the post gate;
strict URL matching; duplicate dispatch; malformed data; wrong GitHub account
and out-of-allowlist repo; missing auth; lock contention; executor failure and
timeout (checking `ELECTRON_RUN_AS_NODE=1`, `--mode plan` and BLOCKED state);
unearned PASS claims (READY/mock/other run_id/legacy state); proof-before-
posting guards; publisher gates (no post by default, missing opt-in, live gate
closed, wrong account/repo, edited/closed Issue, malformed/unreadable comment
pages, missing/stale run_id, oversized and secret-bearing payloads, PASS-like
tokens fail-closed, FAIL local-only, earned PASS unpostable, duplicate marker
no-op, timeout/network failure without retry). The `mock` executor proves the
state machine only — it is NOT proof of full automation, and the guarded
writer is NOT proof of a live GitHub post.

## Disable / uninstall

Nothing is installed or resident. To remove the POC: delete the branch /
`scripts/orchestration-poc/` and `docs/agent-orchestration-poc.md`, then
`reset --confirm` or delete the state directory. No registry, autostart,
hook or Actions change is made by this tool.
