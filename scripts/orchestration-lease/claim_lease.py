#!/usr/bin/env python3
"""Fail-closed single-implementer lease state machine for KAS coordination.

Issue #461. Intentionally NOT wired to the existing KAS orchestration CLI.
No live GitHub writes, gh calls, model calls, credentials, or auto-recovery.

A future remote store MUST implement atomic create-if-absent and compare-and-swap
of a single per-issue Git ref. A GitHub Issue comment/label is not a mutex.
"""
from __future__ import annotations

from dataclasses import dataclass, replace
from hashlib import sha256
from threading import Lock
from typing import Callable, Protocol
import json
import re
import secrets

REPO = "saymer-alt/keenetic-auto-setup"
ROLE = "implementer"  # Reviewer is a read-only observer, not a claim holder.
SCHEMA = "kas-orch-lease/v1"
MIN_TTL = 60
MAX_TTL = 3600
WORKER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
RUN_RE = re.compile(r"^[0-9a-f]{32}$")


class LeaseStop(Exception):
    def __init__(self, code: str, message: str) -> None:
        self.code = code
        super().__init__(f"STOP_{code}: {message}")


@dataclass(frozen=True)
class Lease:
    schema: str
    repo: str
    issue: int
    role: str
    worker: str
    run_id: str
    generation: int
    issued_at: int
    expires_at: int
    state: str  # ACTIVE or RELEASED; never delete Git ref

    def validate(self) -> None:
        if (self.schema != SCHEMA or self.repo != REPO or self.role != ROLE or
                not isinstance(self.issue, int) or isinstance(self.issue, bool) or self.issue <= 0 or
                not isinstance(self.worker, str) or not WORKER_RE.fullmatch(self.worker) or
                not isinstance(self.run_id, str) or not RUN_RE.fullmatch(self.run_id) or
                not isinstance(self.generation, int) or isinstance(self.generation, bool) or
                self.generation <= 0 or
                not isinstance(self.issued_at, int) or not isinstance(self.expires_at, int) or
                self.issued_at < 0 or self.expires_at <= self.issued_at or
                self.state not in ("ACTIVE", "RELEASED")):
            raise LeaseStop("BAD_STATE", "lease metadata invalid or unsupported")

    def serialize(self) -> str:
        self.validate()
        return json.dumps(self.__dict__, sort_keys=True, separators=(",", ":"))


@dataclass(frozen=True)
class Snapshot:
    revision: str  # immutable Git commit SHA in a future real transport
    lease: Lease


class Store(Protocol):
    """CAS is REQUIRED to be atomic across *all machines*, not just threads."""

    def read(self, issue: int) -> Snapshot | None: ...
    def cas(self, issue: int, expected_revision: str | None, lease: Lease) -> Snapshot: ...


class IssueReader(Protocol):
    def read(self, repo: str, issue: int) -> dict: ...


class MemoryCASStore:
    """TEST-ONLY CAS store, never a distributed GitHub lock."""

    def __init__(self) -> None:
        self._entries: dict[int, Snapshot] = {}
        self._guard = Lock()
        self._counter = 0

    def read(self, issue: int) -> Snapshot | None:
        with self._guard:
            return self._entries.get(issue)

    def cas(self, issue: int, expected_revision: str | None, lease: Lease) -> Snapshot:
        lease.validate()
        with self._guard:
            old = self._entries.get(issue)
            if (old.revision if old else None) != expected_revision:
                raise LeaseStop("CLAIM_RACE", "claim ref changed; STOP without retry")
            self._counter += 1
            revision = sha256(f"{self._counter}:{lease.serialize()}".encode()).hexdigest()[:40]
            snap = Snapshot(revision, lease)
            self._entries[issue] = snap
            return snap


class MemoryIssues:
    """TEST-ONLY issue identity fixture."""

    def __init__(self) -> None:
        self.issues: dict[int, dict] = {}

    def set_open(self, issue: int) -> None:
        self.issues[issue] = {"number": issue, "state": "OPEN",
                              "url": f"https://github.com/{REPO}/issues/{issue}"}

    def read(self, repo: str, issue: int) -> dict:
        return self.issues.get(issue, {})


class Coordinator:
    """Pure claim/lease workflow. No native GitHub transport in Stage A.

    fence(snapshot) MUST precede every external side effect. It rejects a
    stale revision or run even when the process still holds old local state.
    This check is cooperative: it is not an operating-system process sandbox.
    """

    def __init__(self, store: Store, issues: IssueReader,
                 now: Callable[[], int]) -> None:
        self.store, self.issues, self.now = store, issues, now
        # Local conservative clock rollback guard. NOT a cross-host time authority.
        self._last_clock: int | None = None

    def _time(self) -> int:
        stamp = self.now()
        if type(stamp) is not int or stamp < 0:
            raise LeaseStop("CLOCK_UNCERTAIN", "clock must return nonnegative integer seconds")
        if self._last_clock is not None and stamp < self._last_clock:
            raise LeaseStop("CLOCK_UNCERTAIN", "local clock moved backwards; STOP")
        self._last_clock = stamp
        return stamp

    def _issue_open(self, issue: int) -> None:
        data = self.issues.read(REPO, issue)
        if (not isinstance(data, dict) or data.get("number") != issue or
                data.get("state") != "OPEN" or
                data.get("url") != f"https://github.com/{REPO}/issues/{issue}"):
            raise LeaseStop("ISSUE_NOT_OPEN", "Issue identity, state or read failed")

    @staticmethod
    def _worker(worker: str) -> None:
        if not isinstance(worker, str) or not WORKER_RE.fullmatch(worker):
            raise LeaseStop("BAD_WORKER", "worker id must be 1-64 safe ASCII chars")

    @staticmethod
    def _ttl(ttl: int) -> None:
        if not isinstance(ttl, int) or isinstance(ttl, bool) or not MIN_TTL <= ttl <= MAX_TTL:
            raise LeaseStop("BAD_TTL", "TTL must be between 60 and 3600 seconds")

    def _read(self, issue: int) -> Snapshot | None:
        snap = self.store.read(issue)
        if snap is not None:
            if not isinstance(snap, Snapshot) or not re.fullmatch(r"[0-9a-f]{40}", snap.revision):
                raise LeaseStop("BAD_STATE", "invalid ref revision")
            snap.lease.validate()
            if snap.lease.issue != issue:
                raise LeaseStop("BAD_STATE", "claim ref/Issue mismatch")
        return snap

    def claim(self, issue: int, worker: str, ttl: int = 300) -> Snapshot:
        self._worker(worker)
        self._ttl(ttl)
        self._issue_open(issue)
        old = self._read(issue)
        stamp = self._time()
        if old is not None and stamp < old.lease.issued_at:
            raise LeaseStop("CLOCK_UNCERTAIN", "stored lease timestamp is in the future")
        if old is not None:
            prev = old.lease
            if prev.state == "ACTIVE":
                if stamp >= prev.expires_at:
                    raise LeaseStop("EXPIRED_NEEDS_OWNER", "expired active worker: no auto takeover")
                raise LeaseStop("DUPLICATE", "implementer already owns the Issue")
            generation = prev.generation + 1
        else:
            generation = 1
        lease = Lease(SCHEMA, REPO, issue, ROLE, worker, secrets.token_hex(16),
                      generation, stamp, stamp + ttl, "ACTIVE")
        return self.store.cas(issue, old.revision if old else None, lease)

    def fence(self, claimed: Snapshot) -> Snapshot:
        """Refresh the remote ref before EVERY action with side effects."""
        if not isinstance(claimed, Snapshot):
            raise LeaseStop("BAD_STATE", "missing claim snapshot")
        claimed.lease.validate()
        self._issue_open(claimed.lease.issue)
        current = self._read(claimed.lease.issue)
        if (current is None or current.revision != claimed.revision or
                current.lease != claimed.lease):
            raise LeaseStop("STALE_LEASE", "claim ref/generation/run changed")
        if current.lease.state != "ACTIVE":
            raise LeaseStop("NOT_ACTIVE", "released claim cannot perform work")
        stamp = self._time()
        if stamp < current.lease.issued_at:
            raise LeaseStop("CLOCK_UNCERTAIN", "lease timestamp is in the future")
        if stamp >= current.lease.expires_at:
            raise LeaseStop("EXPIRED_NEEDS_OWNER", "cannot act after expiry")
        return current

    def renew(self, claimed: Snapshot, ttl: int = 300) -> Snapshot:
        self._ttl(ttl)
        current = self.fence(claimed)
        stamp = self._time()
        updated = replace(current.lease, expires_at=stamp + ttl)
        if updated.expires_at <= current.lease.expires_at:
            raise LeaseStop("NON_MONOTONIC", "renewal must move expiration forward")
        return self.store.cas(current.lease.issue, current.revision, updated)

    def release(self, claimed: Snapshot) -> Snapshot:
        current = self.fence(claimed)
        tombstone = replace(current.lease, state="RELEASED")
        return self.store.cas(current.lease.issue, current.revision, tombstone)

    def recovery_status(self, issue: int) -> str:
        """Inspection only. NEVER automatically reclaim an expired claim."""
        self._issue_open(issue)
        current = self._read(issue)
        if current is None or current.lease.state == "RELEASED":
            return "AVAILABLE"
        stamp = self._time()
        if stamp < current.lease.issued_at:
            raise LeaseStop("CLOCK_UNCERTAIN", "stored lease timestamp is in the future")
        if stamp >= current.lease.expires_at:
            return "EXPIRED_NEEDS_OWNER"
        return "CLAIMED"

    def recover(self, issue: int) -> None:
        raise LeaseStop("RECOVERY_NEEDS_OWNER", "no automatic reclaim; manual owner fencing design required")
