"""No network, GH, model, Git writes, secrets or external files."""
import importlib.util
from pathlib import Path
import unittest
from concurrent.futures import ThreadPoolExecutor
from threading import Barrier

PATH = Path(__file__).resolve().parents[1] / "claim_lease.py"
spec = importlib.util.spec_from_file_location("kas_claim_lease", PATH)
m = importlib.util.module_from_spec(spec)
import sys
sys.modules[spec.name] = m
spec.loader.exec_module(m)


class Tests(unittest.TestCase):
    def setUp(self):
        self.clock = [1000]
        self.store = m.MemoryCASStore()
        self.issues = m.MemoryIssues()
        self.issues.set_open(454)
        self.issues.set_open(456)
        self.c = m.Coordinator(self.store, self.issues, lambda: self.clock[0])

    def stop(self, code, f, *args, **kw):
        with self.assertRaises(m.LeaseStop) as cm:
            f(*args, **kw)
        self.assertEqual(cm.exception.code, code)

    def test_first_claim_unique(self):
        a = self.c.claim(454, "worker-A")
        self.assertEqual(a.lease.generation, 1)
        self.assertEqual(a.lease.role, "implementer")
        self.assertEqual(len(a.lease.run_id), 32)
        self.assertEqual(self.c.recovery_status(454), "CLAIMED")

    def test_duplicate_same_worker_fails(self):
        self.c.claim(454, "worker-A")
        self.stop("DUPLICATE", self.c.claim, 454, "worker-A")

    def test_duplicate_other_worker_fails(self):
        self.c.claim(454, "worker-A")
        self.stop("DUPLICATE", self.c.claim, 454, "worker-B")

    def test_two_agents_race_one_wins(self):
        a = m.Lease(m.SCHEMA, m.REPO, 454, m.ROLE, "worker-A", "a"*32, 1, 1000, 1300, "ACTIVE")
        b = m.replace(a, worker="worker-B", run_id="b"*32)
        self.store.cas(454, None, a)
        self.stop("CLAIM_RACE", self.store.cas, 454, None, b)

    def test_true_concurrent_claim_only_one_winner(self):
        barrier = Barrier(2)
        class RacingStore(m.MemoryCASStore):
            def read(self, issue):
                snap = super().read(issue)
                if snap is None:
                    barrier.wait(timeout=3)
                return snap
        self.store = RacingStore()
        self.c = m.Coordinator(self.store, self.issues, lambda: self.clock[0])
        def try_claim(name):
            try:
                return ("OK", self.c.claim(454, name))
            except m.LeaseStop as e:
                return (e.code, None)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures = [pool.submit(try_claim, w) for w in ("worker-A", "worker-B")]
            results = [f.result(timeout=4) for f in futures]
        self.assertEqual(sorted(x[0] for x in results), ["CLAIM_RACE", "OK"])
        winner = next(x[1] for x in results if x[0] == "OK")
        self.assertEqual(self.store.read(454), winner)

    def test_release_and_second_generation(self):
        a = self.c.claim(454, "worker-A")
        self.c.release(a)
        self.assertEqual(self.c.recovery_status(454), "AVAILABLE")
        b = self.c.claim(454, "worker-B")
        self.assertNotEqual(a.lease.run_id, b.lease.run_id)
        self.assertEqual(b.lease.generation, 2)
        self.stop("STALE_LEASE", self.c.fence, a)

    def test_renew_produces_new_fence(self):
        a = self.c.claim(454, "worker-A")
        self.clock[0] += 120
        b = self.c.renew(a)
        self.assertNotEqual(b.revision, a.revision)
        self.stop("STALE_LEASE", self.c.fence, a)
        self.assertEqual(self.c.fence(b), b)

    def test_old_claim_cannot_release_new(self):
        a = self.c.claim(454, "worker-A")
        self.clock[0] += 100
        b = self.c.renew(a)
        self.stop("STALE_LEASE", self.c.release, a)
        self.assertEqual(self.c.fence(b), b)

    def test_expired_no_takeover(self):
        a = self.c.claim(454, "worker-A", ttl=60)
        self.clock[0] += 60
        self.stop("EXPIRED_NEEDS_OWNER", self.c.claim, 454, "worker-B")
        self.stop("EXPIRED_NEEDS_OWNER", self.c.renew, a)
        self.stop("EXPIRED_NEEDS_OWNER", self.c.release, a)
        self.assertEqual(self.c.recovery_status(454), "EXPIRED_NEEDS_OWNER")

    def test_release_twice_refused(self):
        a = self.c.claim(454, "worker-A")
        self.c.release(a)
        self.stop("STALE_LEASE", self.c.release, a)

    def test_issue_closed_stops(self):
        self.issues.issues[454]["state"] = "CLOSED"
        self.stop("ISSUE_NOT_OPEN", self.c.claim, 454, "worker-A")

    def test_issue_closed_mid_work_stops(self):
        a = self.c.claim(454, "worker-A")
        self.issues.issues[454]["state"] = "CLOSED"
        self.stop("ISSUE_NOT_OPEN", self.c.fence, a)
        self.stop("ISSUE_NOT_OPEN", self.c.renew, a)

    def test_issue_url_mismatch_stops(self):
        self.issues.issues[454]["url"] = "https://evil.example.com/issues/454"
        self.stop("ISSUE_NOT_OPEN", self.c.claim, 454, "worker-A")

    def test_wrong_issue_in_ref_stops(self):
        a = self.c.claim(454, "worker-A")
        self.store._entries[454] = m.Snapshot(a.revision, m.replace(a.lease, issue=456))
        self.stop("BAD_STATE", self.c.fence, a)

    def test_invalid_lease_metadata_stops(self):
        a = self.c.claim(454, "worker-A")
        self.store._entries[454] = m.Snapshot(a.revision, m.replace(a.lease, schema="unexpected"))
        self.stop("BAD_STATE", self.c.fence, a)

    def test_invalid_revision_stops(self):
        a = self.c.claim(454, "worker-A")
        self.store._entries[454] = m.Snapshot("invalid", a.lease)
        self.stop("BAD_STATE", self.c.fence, a)

    def test_no_auto_recover(self):
        self.stop("RECOVERY_NEEDS_OWNER", self.c.recover, 454)

    def test_other_issue_independent(self):
        a = self.c.claim(454, "worker-A")
        b = self.c.claim(456, "worker-B")
        self.assertNotEqual(a.lease.issue, b.lease.issue)

    def test_worker_must_be_safe(self):
        for worker in ("", "a b", "../../x", "a"*65, "@a", "x\n"):
            self.stop("BAD_WORKER", self.c.claim, 454, worker)

    def test_ttl_limits(self):
        for ttl in (-1, 1, 59, 3601, True):
            self.stop("BAD_TTL", self.c.claim, 454, "worker-A", ttl=ttl)

    def test_local_clock_rollback_blocks_fencing(self):
        a = self.c.claim(454, "worker-A")
        self.clock[0] += 15
        self.assertEqual(self.c.fence(a), a)
        self.clock[0] -= 1
        self.stop("CLOCK_UNCERTAIN", self.c.fence, a)

    def test_forward_clock_jump_marks_expired(self):
        a = self.c.claim(454, "worker-A", ttl=60)
        self.clock[0] += 7200
        self.stop("EXPIRED_NEEDS_OWNER", self.c.fence, a)
        self.stop("EXPIRED_NEEDS_OWNER", self.c.claim, 454, "worker-B")

    def test_clock_behind_stored_lease_fails_closed(self):
        a = self.c.claim(454, "worker-A")
        # Different instance simulates a host whose wall clock is behind
        slow = m.Coordinator(self.store, self.issues, lambda: 999)
        self.stop("CLOCK_UNCERTAIN", slow.fence, a)
        self.stop("CLOCK_UNCERTAIN", slow.claim, 454, "worker-B")

    def test_clock_invalid_values_refused(self):
        for clock in (None, True, -1, 1.5, "1000"):
            c = m.Coordinator(self.store, self.issues, lambda x=clock: x)
            self.stop("CLOCK_UNCERTAIN", c.claim, 454, "worker-A")

    def test_renew_must_move_forward(self):
        a = self.c.claim(454, "worker-A", ttl=300)
        self.stop("NON_MONOTONIC", self.c.renew, a, ttl=60)

    def test_read_failure_stops(self):
        class Failure:
            def read(self, repo, issue):
                raise m.LeaseStop("NETWORK", "offline")
        c = m.Coordinator(self.store, Failure(), lambda: 1000)
        self.stop("NETWORK", c.claim, 454, "worker-A")

    def test_stale_snapshot_other_worker(self):
        a = self.c.claim(454, "worker-A")
        bad = m.Snapshot(a.revision, m.replace(a.lease, worker="worker-B"))
        self.stop("STALE_LEASE", self.c.fence, bad)

    def test_reviewer_only_reads(self):
        self.assertEqual(self.c.recovery_status(454), "AVAILABLE")
        self.c.claim(454, "worker-A")
        before = self.store.read(454)
        self.assertEqual(self.c.recovery_status(454), "CLAIMED")
        self.assertEqual(self.store.read(454), before)

    def test_overwriting_ref_without_cas_fails(self):
        a = self.c.claim(454, "worker-A")
        self.stop("CLAIM_RACE", self.store.cas, 454, "a"*40, m.replace(a.lease, worker="worker-B"))


if __name__ == "__main__":
    unittest.main()
