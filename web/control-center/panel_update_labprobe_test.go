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
	for _, name := range []string{"etc/kas-control-center.settings.json", "etc/kas-control-center.password",
		"etc/kas-control-center.proxy-origin", "etc/kas-control-center.export-names",
		"etc/kas-control-center.mihomo-api-secret", "etc/kas-control-center.home-only",
		"etc/mihomo/config.yaml"} {
		b, e := inventoryFile(p.root, name, 4<<20, false)
		t.Logf("config %-40q bytes=%-7d isNotExist=%-5v err=%v", name, len(b), os.IsNotExist(e), e)
		if st, statErr := os.Lstat(p.root + "/" + name); statErr == nil {
			t.Logf("config-stat %-34q mode=%v", name, st.Mode())
		}
	}
	if st, e := os.Lstat(p.root + "/etc"); e == nil {
		t.Logf("etc mode=%v uid=%d", st.Mode(), st.Uid())
	}
	if st, e := os.Lstat(p.root + "/etc/mihomo"); e == nil {
		t.Logf("etc/mihomo mode=%v uid=%d", st.Mode(), st.Uid())
	} else {
		t.Logf("etc/mihomo err=%v", e)
	}
	if _, e := p.configDigest(); e != nil {
		t.Logf("configDigest err=%v", e)
	}
}
