package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func inventoryFixture(t *testing.T) (string, string) {
	t.Helper()
	if os.Geteuid() != 0 {
		t.Skip("root-owned inventory fixtures run in dedicated root CI")
	}
	root := t.TempDir()
	body := []byte("watchdog fixture\n")
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	for _, dir := range []string{"bin", "share/kas-core", "libexec/kas", "etc/kas-core"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	for _, name := range []string{"bin/mihomo_watchdog.sh", "libexec/kas/mihomo-watchdog.sh"} {
		if err := os.WriteFile(filepath.Join(root, name), body, 0600); err != nil {
			t.Fatal(err)
		}
	}
	manifest := `{"schema":1,"version":"0.0.0~proof2-1","source_sha":"` + strings.Repeat("a", 40) + `","scripts":[{"name":"mihomo-watchdog.sh","sha256":"` + digest + `"}]}`
	if err := os.WriteFile(filepath.Join(root, "share/kas-core/scripts.json"), []byte(manifest), 0600); err != nil {
		t.Fatal(err)
	}
	return root, digest
}
func inventoryReceipt(t *testing.T, root, digest, version, source string) {
	t.Helper()
	data := `{"schema":1,"component":"watchdog","bundle_version":"` + version + `","source_sha":"` + source + `","watchdog_sha256":"` + digest + `"}`
	if err := os.WriteFile(filepath.Join(root, "etc/kas-core/watchdog.json"), []byte(data), 0600); err != nil {
		t.Fatal(err)
	}
}
func TestInventoryRequiresActualWatchdogAndMatchingReceipt(t *testing.T) {
	root, digest := inventoryFixture(t)
	if got := componentInventory(root); got.Core.State != "present" || got.Watchdog.State != "unrecorded" {
		t.Fatalf("%+v", got)
	}
	inventoryReceipt(t, root, digest, "0.0.0~proof2-1", strings.Repeat("a", 40))
	if got := componentInventory(root); got.Watchdog.State != "current" || got.Watchdog.RecordedVersion != "0.0.0~proof2-1" {
		t.Fatalf("%+v", got)
	}
	if err := os.WriteFile(filepath.Join(root, "bin/mihomo_watchdog.sh"), []byte("local edit\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := componentInventory(root); got.Watchdog.State != "stale" {
		t.Fatalf("receipt trusted over actual file: %+v", got)
	}
}
func TestInventorySeparatesInstalledBundleFromPreviouslyAppliedVersion(t *testing.T) {
	root, digest := inventoryFixture(t)
	inventoryReceipt(t, root, digest, "0.0.0~proof1-1", strings.Repeat("b", 40))
	if got := componentInventory(root); got.Watchdog.State != "bundle_changed" {
		t.Fatalf("%+v", got)
	}
	if err := os.WriteFile(filepath.Join(root, "libexec/kas/mihomo-watchdog.sh"), []byte("tampered bundle\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if got := componentInventory(root); got.Core.State != "modified" || got.Watchdog.State == "current" {
		t.Fatalf("%+v", got)
	}
}
func TestInventoryUnsafeMetadataIsUnavailableAndNotReflected(t *testing.T) {
	root, digest := inventoryFixture(t)
	inventoryReceipt(t, root, digest, "0.0.0~proof2-1", strings.Repeat("a", 40))
	path := filepath.Join(root, "share/kas-core/scripts.json")
	if err := os.WriteFile(path, []byte(`{"schema":1,"version":"SECRET-TOKEN-value","source_sha":"secret"}`), 0600); err != nil {
		t.Fatal(err)
	}
	got := componentInventory(root)
	data, _ := json.Marshal(got)
	if got.Core.State != "unavailable" || strings.Contains(string(data), "SECRET") || strings.Contains(string(data), "TOKEN") {
		t.Fatal(string(data))
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "etc/kas-core/watchdog.json"), path); err != nil {
		t.Fatal(err)
	}
	if got := componentInventory(root); got.Core.State != "unavailable" {
		t.Fatalf("%+v", got)
	}
}
func TestInventoryPrivateReceiptAndMissingCoreDoNotClaimCurrent(t *testing.T) {
	root, digest := inventoryFixture(t)
	inventoryReceipt(t, root, digest, "0.0.0~proof2-1", strings.Repeat("a", 40))
	if err := os.Chmod(filepath.Join(root, "etc/kas-core/watchdog.json"), 0644); err != nil {
		t.Fatal(err)
	}
	if got := componentInventory(root); got.Watchdog.State != "invalid_receipt" {
		t.Fatalf("%+v", got)
	}
	if err := os.Remove(filepath.Join(root, "share/kas-core/scripts.json")); err != nil {
		t.Fatal(err)
	}
	if got := componentInventory(root); got.Core.State != "absent" || got.Watchdog.State == "current" {
		t.Fatalf("%+v", got)
	}
}
func TestComponentsEndpointIsReadOnlyAndUsesExistingHostGuard(t *testing.T) {
	a := newApp("127.0.0.1:18081", nil)
	for _, tc := range []struct {
		method, host string
		code         int
	}{{"GET", "127.0.0.1:18081", 200}, {"POST", "127.0.0.1:18081", 405}, {"GET", "evil.test", 403}} {
		r := httptest.NewRequest(tc.method, "http://127.0.0.1:18081/api/components", nil)
		r.Host = tc.host
		w := httptest.NewRecorder()
		a.handler().ServeHTTP(w, r)
		if w.Code != tc.code {
			t.Fatalf("%s %s: %d", tc.method, tc.host, w.Code)
		}
		if tc.code == 200 {
			if w.Header().Get("Cache-Control") != "no-store" {
				t.Fatal(w.Header())
			}
			var got componentsResponse
			if err := json.Unmarshal(w.Body.Bytes(), &got); err != nil {
				t.Fatal(err)
			}
			if got.Panel.Version == "" {
				t.Fatal("missing compiled panel identity")
			}
		}
	}
}

func TestInventoryRefusesNonRootReceiptOwnershipAndPublicStateDirectory(t *testing.T) {
	for _, kind := range []string{"file-owner", "directory-owner", "directory-mode"} {
		t.Run(kind, func(t *testing.T) {
			root, digest := inventoryFixture(t)
			inventoryReceipt(t, root, digest, "0.0.0~proof2-1", strings.Repeat("a", 40))
			directory := filepath.Join(root, "etc/kas-core")
			receipt := filepath.Join(directory, "watchdog.json")
			var err error
			switch kind {
			case "file-owner":
				err = os.Chown(receipt, 1001, 1001)
			case "directory-owner":
				err = os.Chown(directory, 1001, 1001)
			case "directory-mode":
				err = os.Chmod(directory, 0755)
			}
			if err != nil {
				if errors.Is(err, syscall.EINVAL) && os.Getenv("KAS_REQUIRE_ROOT_OWNERSHIP_TESTS") != "1" {
					t.Skip("executor UID namespace cannot create non-root ownership; mandatory native CI covers this")
				}
				t.Fatal(err)
			}
			if got := componentInventory(root); got.Watchdog.State != "invalid_receipt" {
				t.Fatalf("untrusted receipt accepted: %+v", got)
			}
		})
	}
}
