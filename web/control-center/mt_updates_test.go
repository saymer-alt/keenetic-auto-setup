package main

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestMTCancelledCheckDoesNotWaitForDownloaderPipe(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := collectMTCommand(exec.CommandContext(ctx, "/bin/sh", "-c", "sleep 4 & wait"))
	if err == nil || time.Since(start) > 3*time.Second {
		t.Fatalf("cancelled metadata command retained downloader pipe: %v, %v", time.Since(start), err)
	}
}
func TestMTCancelledCheckTerminatesItsDownloader(t *testing.T) {
	marker := filepath.Join(t.TempDir(), "survived")
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	_, err := collectMTCommand(exec.CommandContext(ctx, "/bin/sh", "-c", "(sleep .4; printf survived > \"$1\") & wait", "sh", marker))
	if err == nil {
		t.Fatal("cancelled check succeeded")
	}
	time.Sleep(500 * time.Millisecond)
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("cancelled downloader survived", err)
	}
}
func TestMTPackageCommandIsNotKilledByRequestCancellation(t *testing.T) {
	output, err := collectMTCommand(exec.Command("/bin/sh", "-c", "sleep .15; printf complete"))
	if err != nil || output != "complete" {
		t.Fatal(output, err)
	}
}

func mtFixture(t *testing.T) (*mtMaintenance, *[]string) {
	t.Helper()
	calls := []string{}
	version := "0.8.2-1"
	m := &mtMaintenance{process: func() string { return "running" }, ready: func() bool { return true }, config: func() string { return "config-digest" }}
	m.command = func(_ context.Context, args ...string) (string, error) {
		s := strings.Join(args, " ")
		calls = append(calls, s)
		switch s {
		case "update":
			return "", nil
		case "status magitrickle":
			return "Package: magitrickle\nVersion: " + version + "\nStatus: install user installed\n", nil
		case "list-upgradable":
			if version == "0.8.2-1" {
				return "other - 1 - 2\nmagitrickle - 0.8.2-1 - 0.8.2-2\n", nil
			}
			return "", nil
		case "install magitrickle":
			version = "0.8.2-2"
			return "PRIVATE", nil
		case "restart":
			return "", nil
		}
		t.Fatalf("unexpected command %q", s)
		return "", nil
	}
	return m, &calls
}
func TestMTUpdateUsesOnlyNamedPackageAndChecksOutcome(t *testing.T) {
	m, calls := mtFixture(t)
	check, err := m.check(context.Background())
	if err != nil || check.Relation != "newer" || check.CurrentVersion != "0.8.2-1" || check.AvailableVersion != "0.8.2-2" {
		t.Fatal(check, err)
	}
	outcome, err := m.apply()
	if err != nil || outcome != "CHANGED" {
		t.Fatal(outcome, err, *calls)
	}
	if strings.Count(strings.Join(*calls, "\n"), "install magitrickle") != 1 || (*calls)[len(*calls)-1] != "status magitrickle" {
		t.Fatal(*calls)
	}
	*calls = nil
	outcome, err = m.apply()
	if err != nil || outcome != "UNCHANGED" {
		t.Fatal(outcome, err)
	}
	for _, c := range *calls {
		if c == "restart" || strings.HasPrefix(c, "install") {
			t.Fatal("no-op restarted/installed", *calls)
		}
	}
}
func TestMTFailuresNeverClaimRollbackOrIgnoreServiceConfig(t *testing.T) {
	for _, scenario := range []string{"update", "install", "restart", "config", "process", "stopped", "early", "uninstalled", "ambiguous"} {
		t.Run(scenario, func(t *testing.T) {
			m, calls := mtFixture(t)
			run := m.command
			m.command = func(ctx context.Context, args ...string) (string, error) {
				s := strings.Join(args, " ")
				if s == scenario+" magitrickle" || s == scenario && scenario == "update" || scenario == "restart" && s == "restart" {
					return "SECRET", errors.New("SECRET")
				}
				if scenario == "uninstalled" && s == "status magitrickle" {
					return "Package: magitrickle\nVersion: 0.8.2-1\nStatus: deinstall user config-files\n", nil
				}
				if scenario == "ambiguous" && s == "list-upgradable" {
					return "magitrickle - 0.8.2-1 - 0.8.2-2\nmagitrickle - 0.8.2-1 - 0.8.2-3\n", nil
				}
				return run(ctx, args...)
			}
			reads := 0
			if scenario == "config" {
				m.config = func() string {
					reads++
					if reads == 1 {
						return "before"
					}
					return "after"
				}
			}
			if scenario == "process" {
				m.process = func() string {
					if len(*calls) > 4 {
						return "stopped"
					}
					return "running"
				}
			}
			if scenario == "stopped" {
				m.process = func() string { return "stopped" }
			}
			if scenario == "early" {
				m.ready = func() bool { return false }
			}
			_, err := m.apply()
			if err == nil || strings.Contains(err.Error(), "SECRET") || strings.Contains(err.Error(), "rollback") {
				t.Fatal(err, *calls)
			}
			if scenario == "stopped" || scenario == "early" {
				for _, c := range *calls {
					if strings.HasPrefix(c, "install") {
						t.Fatal(*calls)
					}
				}
			}
		})
	}
}
func TestMTHTTPConfirmationAndSharedMaintenance(t *testing.T) {
	a := newApp("127.0.0.1:18081", nil)
	m, _ := mtFixture(t)
	a.mt = m
	if w := updateRequest(a, "/api/updates/magitrickle", "http://127.0.0.1:18081", "update-magitrickle", "{}"); w.Code != 409 {
		t.Fatal(w.Code, w.Body.String())
	}
	if w := updateRequest(a, "/api/updates/magitrickle/check", "http://evil.test", "check-magitrickle", "{}"); w.Code != 403 {
		t.Fatal(w.Code)
	}
	if w := updateRequest(a, "/api/updates/magitrickle/check", "http://127.0.0.1:18081", "check-magitrickle", "{}"); w.Code != 200 {
		t.Fatal(w.Code, w.Body.String())
	}
	started, release := make(chan struct{}), make(chan struct{})
	run := m.command
	m.command = func(ctx context.Context, args ...string) (string, error) {
		if strings.Join(args, " ") == "install magitrickle" {
			close(started)
			<-release
		}
		return run(ctx, args...)
	}
	w := updateRequest(a, "/api/updates/magitrickle", "http://127.0.0.1:18081", "update-magitrickle", "{}")
	if w.Code != 202 {
		t.Fatal(w.Code, w.Body.String())
	}
	<-started
	if w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}"); w.Code != 409 {
		t.Fatal(w.Code)
	}
	close(release)
	for i := 0; i < 1000; i++ {
		a.mu.Lock()
		done := !a.importRunning
		r := a.updateResult
		a.mu.Unlock()
		if done {
			if r.Component != "magitrickle" || r.State != "OK" || r.Outcome != "CHANGED" {
				t.Fatal(r)
			}
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("worker did not finish")
}
