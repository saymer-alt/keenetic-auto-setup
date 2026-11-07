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

`--json` makes every command machine-readable (ChatGPT reads the file, the
owner pastes nothing).

## Executors

- `dry-run` (default): print the exact executor command, run nothing.
- `mock`: simulated successful dispatch for tests; no model call.
- `zcode-cli`: build and run the headless command **always with `--mode plan`**
  (yolo/build/edit are refused by construction). Currently NOT_VERIFIED
  end-to-end: the CLI v0.17.1 selects the first personal provider rule, not
  the Z.AI Coding Plan — see the docs file before any attempt.

## Safety properties

- One active task; duplicate dispatch and re-fetch while active → `STOP_*`;
  an OS-level interprocess lock (`fcntl`/`msvcrt`) serializes all commands per
  state dir and is released automatically if a process dies (`STOP_LOCKED`).
- GitHub account must equal the repository owner (`gh api user`) and the issue
  payload schema is validated (number/title/body/url/updatedAt) — malformed
  data fails closed (`STOP_BAD_ACCOUNT`, `STOP_MALFORMED_ISSUE`).
- Repo owner allowlist; issue must be `OPEN`; the checkout HEAD is re-verified
  against the contract base SHA before dispatch AND checkpoint
  (`STOP_STALE_SHA`).
- Issue body is capped at 50 KB with an explicit truncation marker.
- `dry-run` never claims the task (state stays READY). Real executors run with
  `ELECTRON_RUN_AS_NODE=1` and `--mode plan` only; a non-zero executor exit
  code or timeout moves the task to BLOCKED (`STOP_EXECUTOR_FAILED` /
  `STOP_EXECUTOR_TIMEOUT`) — a false PASS is impossible.
- Posting a checkpoint to GitHub is double-locked
  (`--post` + `--confirm` + `KAS_ORCH_ALLOW_WRITE=1`) and additionally stopped
  in this POC build; the file is delivered manually.
- Exit codes: `0` OK, `2` STOP (safe refusal), `1` internal error.

## Tests (no network, mock GitHub)

```bash
python -m unittest discover -s scripts/orchestration-poc/tests -v
```

25 tests cover the happy path and the negative cases: stale SHA at dispatch
and checkpoint, duplicate dispatch, malformed issue payloads, wrong GitHub
account, missing auth, network failure, lock contention, executor failure and
timeout (verifying `ELECTRON_RUN_AS_NODE=1`, `--mode plan` and BLOCKED state),
plus the no-opt-in posting guard. The `mock` executor proves the state machine
only — it is NOT proof of full automation.

## Disable / uninstall

Nothing is installed or resident. To remove the POC: delete the branch /
`scripts/orchestration-poc/` and `docs/agent-orchestration-poc.md`, then
`reset --confirm` or delete the state directory. No registry, autostart,
hook or Actions change is made by this tool.
