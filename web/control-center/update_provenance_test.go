package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestInventoryMihomoReleaseProvenance(t *testing.T) {
	if os.Getuid() != 0 {
		t.Skip("protected inventory fixture requires root; mandatory CI root inventory step")
	}
	root := t.TempDir()
	for _, d := range []string{"bin", "etc", "lib/opkg/info"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(p, s string) {
		if err := os.WriteFile(filepath.Join(root, p), []byte(s), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("bin/mihomo", "binary")
	write("lib/opkg/info/mihomo.control", "Package: mihomo\nVersion: 1.19.32-1\n")
	base := updateCheck{State: "AVAILABLE", Architecture: "mipsel-3.4", CurrentVersion: "1.19.33", AvailableVersion: "1.19.33", PackageRelease: 2, Relation: "same_runtime"}
	got := enrichMihomoCheck(root, base)
	if got.Relation != "same_runtime" || got.InstalledPackageVersion != "1.19.32-1" || got.RecordedPackageRelease != 0 {
		t.Fatal(got)
	}
	state := "state_format=1\nruntime_version=1.19.33\nsource=entware-go-binary-updater\nasset=mihomo_1.19.33-2_mipsel-3.4.ipk\npackage_release=2\nbinary_size_bytes=6\n"
	write("etc/keenetic-auto-setup-mihomo.state", state)
	got = enrichMihomoCheck(root, base)
	if got.Relation != "same_package" || got.RecordedPackageRelease != 2 {
		t.Fatal(got)
	}
	newer := base
	newer.PackageRelease = 3
	if g := enrichMihomoCheck(root, newer); g.Relation != "newer_package" {
		t.Fatal(g)
	}
	older := base
	older.PackageRelease = 1
	if g := enrichMihomoCheck(root, older); g.Relation != "older_package" {
		t.Fatal(g)
	}
	write("bin/mihomo", "different-size")
	if g := enrichMihomoCheck(root, base); g.Relation != "invalid_state" || g.RecordedPackageRelease != 0 {
		t.Fatal(g)
	}
	write("bin/mihomo", "binary")
	write("etc/keenetic-auto-setup-mihomo.state", state+"package_release=2\n")
	if g := enrichMihomoCheck(root, base); g.Relation != "invalid_state" {
		t.Fatal(g)
	}
	write("etc/keenetic-auto-setup-mihomo.state", "package_release=\n"+state)
	if g := enrichMihomoCheck(root, base); g.Relation != "invalid_state" {
		t.Fatal("empty duplicate accepted", g)
	}
}
