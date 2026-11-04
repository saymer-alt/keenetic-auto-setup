package main

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
)

func fakePortListener(t *testing.T) net.Listener {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	return l
}

func TestStartupAutoPortProbesActualBindInOrder(t *testing.T) {
	var attempted []string
	var savedPort int
	var savedFallback bool
	bind := func(network, address string) (net.Listener, error) {
		if network != "tcp" {
			t.Fatal(network)
		}
		attempted = append(attempted, address)
		if strings.HasSuffix(address, ":18080") || strings.HasSuffix(address, ":18081") {
			return nil, &net.OpError{Op: "listen", Net: "tcp", Err: syscall.EADDRINUSE}
		}
		return fakePortListener(t), nil
	}
	l, port, fallback, err := selectStartupListener("0.0.0.0:18080", true,
		func(selected int, didFallback bool) error {
			savedPort, savedFallback = selected, didFallback
			return nil
		}, bind)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	want := []string{"0.0.0.0:18080", "0.0.0.0:18081", "0.0.0.0:18082"}
	if !reflect.DeepEqual(attempted, want) || port != 18082 || !fallback || savedPort != 18082 || !savedFallback {
		t.Fatalf("attempted=%v selected=%d fallback=%t persisted=%d/%t", attempted, port, fallback, savedPort, savedFallback)
	}
}

func TestStartupAutoPortFreeDefaultPersistedAndFixedAfterRestart(t *testing.T) {
	path := filepath.Join(t.TempDir(), "panel.json")
	persist := func(port int, fallback bool) error {
		return saveInitialPanelConfig(path, &panelConfig{Version: 1, Port: port, AuthMode: "none", AutoPortFallback: fallback})
	}
	calls := 0
	bind := func(_, address string) (net.Listener, error) {
		calls++
		if address != "0.0.0.0:18080" {
			t.Fatal(address)
		}
		return fakePortListener(t), nil
	}
	l, port, fallback, err := selectStartupListener("0.0.0.0:18080", true, persist, bind)
	if err != nil || port != 18080 || fallback {
		t.Fatal(port, fallback, err)
	}
	l.Close()
	saved, err := readPanelConfig(path)
	if err != nil || saved.Port != 18080 || saved.AutoPortFallback {
		t.Fatal("default port not persisted", saved, err)
	}
	// A saved port is fixed, even when occupied on a later boot.
	calls = 0
	bind = func(_, address string) (net.Listener, error) {
		calls++
		if address != "0.0.0.0:18080" {
			t.Fatal("hopped saved port", address)
		}
		return nil, syscall.EADDRINUSE
	}
	l, _, _, err = selectStartupListener("0.0.0.0:"+strconv.Itoa(saved.Port), false, nil, bind)
	if l != nil || err == nil || !strings.Contains(err.Error(), "PORT_BIND_FAILED") || calls != 1 {
		t.Fatal("saved port silently moved", err, calls)
	}
}

func TestStartupPortDoesNotHopForExplicitOrOtherErrors(t *testing.T) {
	for _, tc := range []struct {
		name string
		auto bool
		err  error
	}{
		{"explicit occupied", false, syscall.EADDRINUSE},
		{"auto denied", true, syscall.EACCES},
		{"auto address unavailable", true, syscall.EADDRNOTAVAIL},
	} {
		t.Run(tc.name, func(t *testing.T) {
			attempts, saved := 0, 0
			l, _, _, err := selectStartupListener("0.0.0.0:18080", tc.auto, func(int, bool) error {
				saved++
				return nil
			}, func(_, _ string) (net.Listener, error) {
				attempts++
				return nil, &net.OpError{Op: "listen", Net: "tcp", Err: tc.err}
			})
			if l != nil || err == nil || attempts != 1 || saved != 0 || !strings.Contains(err.Error(), "PORT_BIND_FAILED") {
				t.Fatal(err, attempts, saved)
			}
		})
	}
}

func TestStartupAutoPortExhaustedFailClosed(t *testing.T) {
	attempts := 0
	l, _, _, err := selectStartupListener("0.0.0.0:18080", true, func(int, bool) error {
		t.Fatal("persisted nonexistent listener")
		return nil
	}, func(_, addr string) (net.Listener, error) {
		attempts++
		if addr != fmt.Sprintf("0.0.0.0:%d", 18079+attempts) {
			t.Fatal(addr)
		}
		return nil, syscall.EADDRINUSE
	})
	if l != nil || attempts != autoPanelLastPort-autoPanelStartPort+1 || err == nil || !strings.Contains(err.Error(), "18080-18090") {
		t.Fatal(err, attempts)
	}
}

func TestStartupSettingsFailureClosesReservedSocket(t *testing.T) {
	var obtained net.Listener
	l, _, _, err := selectStartupListener("0.0.0.0:18080", true,
		func(int, bool) error { return errors.New("readonly settings") },
		func(_, _ string) (net.Listener, error) {
			obtained = fakePortListener(t)
			return obtained, nil
		})
	if l != nil || err == nil || !strings.Contains(err.Error(), "PANEL_SETTINGS_SAVE_FAILED") {
		t.Fatal(err)
	}
	if _, err := obtained.Accept(); err == nil {
		t.Fatal("socket remained open after persistence failed")
	}
}

func TestInitialPortSettingsCreateOnlyAndPrivate(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "panel.json")
	initial := &panelConfig{Version: 1, Port: 18082, AuthMode: "entware", AutoPortFallback: true}
	if err := saveInitialPanelConfig(path, initial); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		t.Fatalf("unprotected initial settings %v %v", info, err)
	}
	saved, err := readPanelConfig(path)
	if err != nil || saved.Port != 18082 || saved.AuthMode != "entware" || !saved.AutoPortFallback {
		t.Fatal(saved, err)
	}
	if err := saveInitialPanelConfig(path, &panelConfig{Version: 1, Port: 18090, AuthMode: "none"}); err == nil {
		t.Fatal("overwrote existing explicit settings")
	}
	saved, _ = readPanelConfig(path)
	if saved.Port != 18082 || saved.AuthMode != "entware" {
		t.Fatal("existing settings mutated")
	}
}

func TestSavedCustomPortNeverAutoHops(t *testing.T) {
	// Covers existing beta.4/5 user ports, including the field workaround
	// 18082, which must never be rewritten by a beta.6 first-start policy.
	const custom = 18082
	path := filepath.Join(t.TempDir(), "panel.json")
	if err := saveInitialPanelConfig(path, &panelConfig{Version: 1, Port: custom, AuthMode: "entware"}); err != nil {
		t.Fatal(err)
	}
	cfg, err := readPanelConfig(path)
	if err != nil || cfg.Port != custom {
		t.Fatal(cfg, err)
	}
	attempts := 0
	listener, _, _, err := selectStartupListener(fmt.Sprintf("0.0.0.0:%d", cfg.Port), false,
		func(int, bool) error { t.Fatal("mutated saved config"); return nil },
		func(_, address string) (net.Listener, error) {
			attempts++
			if address != "0.0.0.0:18082" {
				t.Fatal("changed a user-selected port", address)
			}
			return nil, syscall.EADDRINUSE
		})
	if listener != nil || err == nil || attempts != 1 {
		t.Fatal(err, attempts)
	}
	after, _ := readPanelConfig(path)
	if after.Port != custom || after.AuthMode != "entware" {
		t.Fatal("user settings changed", after)
	}
}

func TestInitialSettingsConcurrentStartsCreateOnly(t *testing.T) {
	path := filepath.Join(t.TempDir(), "panel.json")
	var wg sync.WaitGroup
	outcomes := make(chan error, 2)
	for _, port := range []int{18081, 18082} {
		wg.Add(1)
		go func(selected int) {
			defer wg.Done()
			outcomes <- saveInitialPanelConfig(path, &panelConfig{
				Version: 1, Port: selected, AuthMode: "none", AutoPortFallback: true,
			})
		}(port)
	}
	wg.Wait()
	close(outcomes)
	ok := 0
	for err := range outcomes {
		if err == nil {
			ok++
		}
	}
	if ok != 1 {
		t.Fatal("create-only concurrency lost", ok)
	}
	cfg, err := readPanelConfig(path)
	if err != nil || !cfg.AutoPortFallback || (cfg.Port != 18081 && cfg.Port != 18082) {
		t.Fatal("bad persisted winner", cfg, err)
	}
}

func TestInitialPortSettingsRejectSymlinkAndUnsafeStorage(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := &panelConfig{Version: 1, Port: 18081, AuthMode: "none", AutoPortFallback: true}
	link := filepath.Join(dir, "symlink")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := saveInitialPanelConfig(link, cfg); err == nil {
		t.Fatal("symlink destination accepted")
	}
	actual, _ := os.ReadFile(target)
	if string(actual) != "keep" {
		t.Fatal("foreign target overwritten")
	}
	inside := filepath.Join(dir, "inside")
	if err := os.Mkdir(inside, 0700); err != nil {
		t.Fatal(err)
	}
	parentLink := filepath.Join(dir, "parent-link")
	if err := os.Symlink(inside, parentLink); err != nil {
		t.Fatal(err)
	}
	if err := saveInitialPanelConfig(filepath.Join(parentLink, "settings"), cfg); err == nil {
		t.Fatal("symlink directory accepted")
	}
	if err := saveInitialPanelConfig(filepath.Join(dir, "nonexistent", "settings"), cfg); err == nil {
		t.Fatal("nonexistent settings storage accepted")
	}
	if err := os.Chmod(inside, 0777); err != nil {
		t.Fatal(err)
	}
	if err := saveInitialPanelConfig(filepath.Join(inside, "settings"), cfg); err == nil {
		t.Fatal("world writable settings directory accepted")
	}
}

func TestAutoPortWildcardConflictsWithDifferentLoopbackIPv4(t *testing.T) {
	// Simulates a router service listening on its own dedicated local IP
	// (KeeneticOS nginx/ezcfg); wildcards overlap even without a bind on br0.
	other, err := net.Listen("tcp4", "127.0.0.2:0")
	if err != nil {
		t.Skip("loopback alias unavailable:", err)
	}
	defer other.Close()
	_, port, _ := net.SplitHostPort(other.Addr().String())
	wildcard, err := net.Listen("tcp4", "0.0.0.0:"+port)
	if err == nil {
		wildcard.Close()
		t.Fatal("IPv4 wildcard unexpectedly bound over another local address")
	}
	if !errors.Is(err, syscall.EADDRINUSE) {
		t.Fatal("unexpected bind error", err)
	}
}

func TestLegacyPanelMigrationAndBackup(t *testing.T) {
	for _, busy := range []bool{false, true} {
		t.Run(fmt.Sprint("occupied-", busy), func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "settings.json")
			before := &panelConfig{Version: 1, Port: 8081, AuthMode: "entware"}
			if err := saveInitialPanelConfig(path, before); err != nil { t.Fatal(err) }
			var probes []string
			listener, port, fallback, err := selectStartupListener("0.0.0.0:18080", true,
				func(p int, fb bool) error { return migrateLegacyPanelPort(path, before, p, fb) },
				func(_, address string) (net.Listener, error) {
					probes = append(probes, address)
					if busy && strings.HasSuffix(address, ":18080") { return nil, syscall.EADDRINUSE }
					return fakePortListener(t), nil
				})
			if err != nil { t.Fatal(err) }
			listener.Close()
			want := 18080; if busy { want = 18081 }
			if port != want || fallback != busy || len(probes) != 1+map[bool]int{true:1,false:0}[busy] { t.Fatal(port, fallback, probes) }
			current, err := readPanelConfig(path)
			if err != nil || current.Port != want || current.AuthMode != "entware" ||
				current.AutoPortFallback != busy { t.Fatal(current, err) }
			backup, err := readPanelConfig(path+legacyPortBackupSuffix)
			if err != nil || !samePersistedPanelConfig(backup, before) { t.Fatal(backup, err) }
			st, err := os.Stat(path+legacyPortBackupSuffix)
			if err != nil || st.Mode().Perm()&0077 != 0 { t.Fatal("backup must be private", err) }
			if !legacyPanelBackupMatches(path, current) || legacyPanelPortEligible(current) { t.Fatal("migration marker invalid") }
		})
	}
}
func TestLegacyPanelMigrationSafety(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	for _, port := range []int{8080, 18080, 18081, 19000, 443} {
		if legacyPanelPortEligible(&panelConfig{Version:1, Port:port, AuthMode:"none"}) { t.Fatal("custom port mutated", port) }
	}
	original := &panelConfig{Version:1, Port:8081, AuthMode:"none"}
	if err := saveInitialPanelConfig(path, original); err != nil { t.Fatal(err) }
	if err := migrateLegacyPanelPort(path, original, 18091, false); err == nil { t.Fatal("range bypass") }
	if err := migrateLegacyPanelPort(path, original, 18080, true); err == nil { t.Fatal("fallback mismatch") }
	if err := saveInitialPanelConfig(path+legacyPortBackupSuffix, &panelConfig{Version:1, Port:8081, AuthMode:"entware"}); err != nil { t.Fatal(err) }
	if err := migrateLegacyPanelPort(path, original, 18080, false); err == nil { t.Fatal("mismatched backup overwritten") }
	if err := os.Remove(path+legacyPortBackupSuffix); err != nil { t.Fatal(err) }
	if err := os.Symlink("elsewhere", path+legacyPortBackupSuffix); err != nil { t.Fatal(err) }
	if err := migrateLegacyPanelPort(path, original, 18080, false); err == nil { t.Fatal("symlink backup accepted") }
	c, err := readPanelConfig(path); if err != nil || c.Port!=8081 { t.Fatal(c,err) }
}
func TestLegacyPanelExhaustionKeepsOriginal(t *testing.T) {
	path := filepath.Join(t.TempDir(), "settings.json")
	original := &panelConfig{Version:1,Port:8081,AuthMode:"entware"}
	if err := saveInitialPanelConfig(path, original); err != nil { t.Fatal(err) }
	calls := 0
	l, _, _, err := selectStartupListener("0.0.0.0:18080", true,
		func(int,bool) error { t.Fatal("persist without listener"); return nil },
		func(_, _ string)(net.Listener,error){ calls++; return nil,syscall.EADDRINUSE })
	if l!=nil || err==nil || calls!=11 { t.Fatal(err,calls) }
	after,err:=readPanelConfig(path)
	if err!=nil || !samePersistedPanelConfig(after,original) { t.Fatal("settings changed",after,err) }
	if _,err:=os.Lstat(path+legacyPortBackupSuffix);!os.IsNotExist(err) { t.Fatal("backup before bind",err) }
}
