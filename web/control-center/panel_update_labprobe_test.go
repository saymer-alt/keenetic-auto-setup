package main

import (
	"os"
	"testing"
)

// Lab-only probe for the disposable selfupdate service VM: prints the raw
// inventory errors the worker paths otherwise reduce to sentinel codes.
// Skipped unless KAS_LAB_PROBE=1; never asserts on host state.
func TestPanelLabInventoryProbe(t *testing.T) {
	if os.Getenv("KAS_LAB_PROBE") == "" {
		t.Skip("lab probe")
	}
	p := newPanelUpdater("/opt")
	for _, probe := range []struct {
		relative string
		max      int64
		private  bool
	}{{"lib/opkg/info/kas-control-center.control", 65536, false},
		{"share/kas-control-center/BUILD_INFO", 8192, false},
		{"bin/kas-control-center", panelMaxPayload, false},
		{"etc/init.d/S98kas-control-center", 128 << 10, false},
		{"lib/opkg/info/kas-control-center.list", 65536, false},
		{"bin/opkg", 8 << 20, false},
		{"etc/kas-control-center-update/job.json", 16384, true}} {
		b, e := inventoryFile(p.root, probe.relative, probe.max, probe.private)
		t.Logf("inventory %-48q bytes=%-8d err=%v", probe.relative, len(b), e)
	}
	version, sha, e := p.installed()
	t.Logf("installed: version=%q sha=%q err=%v", version, sha, e)
	if e := p.integrity(); e != nil {
		t.Logf("integrity err=%v", e)
	}
}
