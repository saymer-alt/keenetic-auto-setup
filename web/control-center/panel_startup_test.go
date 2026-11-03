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
		if strings.HasSuffix(address, ":8081") || strings.HasSuffix(address, ":8082") {
			return nil, &net.OpError{Op: "listen", Net: "tcp", Err: syscall.EADDRINUSE}
		}
		return fakePortListener(t), nil
	}
	l, port, fallback, err := selectStartupListener("0.0.0.0:8081", true,
		func(selected int, didFallback bool) error {
			savedPort, savedFallback = selected, didFallback
			return nil
		}, bind)
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	want := []string{"0.0.0.0:8081", "0.0.0.0:8082", "0.0.0.0:8083"}
	if !reflect.DeepEqual(attempted, want) || port != 8083 || !fallback || savedPort != 8083 || !savedFallback {
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
		if address != "0.0.0.0:8081" {
			t.Fatal(address)
		}
		return fakePortListener(t), nil
	}
	l, port, fallback, err := selectStartupListener("0.0.0.0:8081", true, persist, bind)
	if err != nil || port != 8081 || fallback {
		t.Fatal(port, fallback, err)
	}
	l.Close()
	saved, err := readPanelConfig(path)
	if err != nil || saved.Port != 8081 || saved.AutoPortFallback {
		t.Fatal("default port not persisted", saved, err)
	}
	// A saved port is fixed, even when occupied on a later boot.
	calls = 0
	bind = func(_, address string) (net.Listener, error) {
		calls++
		if address != "0.0.0.0:8081" {
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
			l, _, _, err := selectStartupListener("0.0.0.0:8081", tc.auto, func(int, bool) error {
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
	l, _, _, err := selectStartupListener("0.0.0.0:8081", true, func(int, bool) error {
		t.Fatal("persisted nonexistent listener")
		return nil
	}, func(_, addr string) (net.Listener, error) {
		attempts++
		if addr != fmt.Sprintf("0.0.0.0:%d", 8080+attempts) {
			t.Fatal(addr)
		}
		return nil, syscall.EADDRINUSE
	})
	if l != nil || attempts != autoPanelLastPort-autoPanelStartPort+1 || err == nil || !strings.Contains(err.Error(), "8081-8090") {
		t.Fatal(err, attempts)
	}
}

func TestStartupSettingsFailureClosesReservedSocket(t *testing.T) {
	var obtained net.Listener
	l, _, _, err := selectStartupListener("0.0.0.0:8081", true,
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
	initial := &panelConfig{Version: 1, Port: 8083, AuthMode: "entware", AutoPortFallback: true}
	if err := saveInitialPanelConfig(path, initial); err != nil {
		t.Fatal(err)
	}
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
		t.Fatalf("unprotected initial settings %v %v", info, err)
	}
	saved, err := readPanelConfig(path)
	if err != nil || saved.Port != 8083 || saved.AuthMode != "entware" || !saved.AutoPortFallback {
		t.Fatal(saved, err)
	}
	if err := saveInitialPanelConfig(path, &panelConfig{Version: 1, Port: 8090, AuthMode: "none"}); err == nil {
		t.Fatal("overwrote existing explicit settings")
	}
	saved, _ = readPanelConfig(path)
	if saved.Port != 8083 || saved.AuthMode != "entware" {
		t.Fatal("existing settings mutated")
	}
}

func TestInitialPortSettingsRejectSymlinkAndUnsafeStorage(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "target")
	if err := os.WriteFile(target, []byte("keep"), 0600); err != nil {
		t.Fatal(err)
	}
	cfg := &panelConfig{Version: 1, Port: 8082, AuthMode: "none", AutoPortFallback: true}
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
