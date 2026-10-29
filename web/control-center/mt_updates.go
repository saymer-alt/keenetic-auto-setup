package main

// MagiTrickle remains opkg-managed. No binary replacement, repo bootstrap,
// force switches or upgrade-all. Package hooks/conffile behavior belong to opkg;
// unlike the Mihomo updater, this path does not promise transactional rollback.
import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"time"
)

type mtUpdateCheck struct {
	State            string `json:"state"`
	Time             string `json:"timestamp"`
	CurrentVersion   string `json:"current_version,omitempty"`
	AvailableVersion string `json:"available_version,omitempty"`
	Relation         string `json:"relation,omitempty"`
	ErrorCode        string `json:"error_code,omitempty"`
}
type mtMaintenance struct {
	command func(context.Context, ...string) (string, error)
	process func() string
	ready   func() bool
	config  func() string
	wait    func(time.Duration)
}

func newMTMaintenance() *mtMaintenance {
	return &mtMaintenance{command: mtCommand, process: func() string {
		return processEvidence("/proc", []string{"/opt/bin/magitrickled", "/opt/bin/magitrickle"})
	}, ready: func() bool {
		b, e := os.ReadFile("/proc/uptime")
		if e != nil {
			return false
		}
		f := strings.Fields(string(b))
		if len(f) == 0 {
			return false
		}
		n, e := strconv.ParseFloat(f[0], 64)
		return e == nil && n > 300
	}, config: func() string { return mtConfigDigest("/opt") }, wait: time.Sleep}
}
func mtCommand(ctx context.Context, args ...string) (string, error) {
	path := "/opt/bin/opkg"
	cmdArgs := args
	switch strings.Join(args, " ") {
	case "update", "status magitrickle", "list-upgradable", "install magitrickle":
		if _, err := inventoryFile("/opt", "bin/opkg", 8*1024*1024, false); err != nil {
			return "", errors.New("OPKG_UNAVAILABLE")
		}
	case "restart":
		if _, err := inventoryFile("/opt", "etc/init.d/S99magitrickle", 65536, false); err != nil {
			return "", errors.New("MT_SERVICE_UNAVAILABLE")
		}
		path = "/bin/sh"
		cmdArgs = []string{"/opt/etc/init.d/S99magitrickle", "restart"}
	default:
		return "", errors.New("MT_COMMAND_BLOCKED")
	}
	var cmd *exec.Cmd
	if args[0] == "install" || args[0] == "restart" {
		cmd = exec.Command(path, cmdArgs...)
	} else {
		cmd = exec.CommandContext(ctx, path, cmdArgs...)
	}
	return collectMTCommand(cmd)
}
func collectMTCommand(cmd *exec.Cmd) (string, error) {
	cmd.WaitDelay = 2 * time.Second
	if cmd.Cancel != nil {
		// Metadata commands only: terminate their downloader as well as opkg.
		// install/restart use exec.Command without a request cancellation hook.
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		cmd.Cancel = func() error { return syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL) }
	}
	cmd.Stdin = nil
	cmd.Stderr = io.Discard
	output := &capWriter{limit: 262145}
	cmd.Stdout = output
	err := cmd.Run()
	if err != nil || len(output.data) > 262144 {
		return "", errors.New("MT_COMMAND_FAILED")
	}
	return string(output.data), nil
}
func mtConfigDigest(root string) string {
	hash := sha256.New()
	for i, p := range []string{"var/lib/magitrickle/config.yaml", "etc/config/magitrickle.conf"} {
		b, e := inventoryFile(root, p, 4*1024*1024, false)
		if os.IsNotExist(e) && i == 1 {
			hash.Write([]byte("absent"))
			continue
		}
		if e != nil {
			return ""
		}
		hash.Write([]byte(p + "\x00" + strconv.Itoa(len(b)) + "\x00"))
		hash.Write(b)
	}
	return hex.EncodeToString(hash.Sum(nil))
}
func parseMTInstalled(raw string) string {
	version := parsePackageVersion(raw, "magitrickle")
	if version == "" {
		return ""
	}
	status := ""
	count := 0
	for _, line := range strings.Split(raw, "\n") {
		if strings.HasPrefix(line, "Status:") {
			status = strings.TrimSpace(strings.TrimPrefix(line, "Status:"))
			count++
		}
	}
	f := strings.Fields(status)
	if count != 1 || len(f) != 3 || f[0] != "install" || f[2] != "installed" {
		return ""
	}
	return version
}
func (m *mtMaintenance) installed(ctx context.Context) (string, error) {
	raw, e := m.command(ctx, "status", "magitrickle")
	v := parseMTInstalled(raw)
	if e != nil || v == "" {
		return "", errors.New("MT_NOT_INSTALLED")
	}
	return v, nil
}
func (m *mtMaintenance) check(ctx context.Context) (mtUpdateCheck, error) {
	current, e := m.installed(ctx)
	if e != nil {
		return mtUpdateCheck{}, e
	}
	if _, e = m.command(ctx, "update"); e != nil {
		return mtUpdateCheck{}, errors.New("MT_INDEX_UPDATE_FAILED")
	}
	raw, e := m.command(ctx, "list-upgradable")
	if e != nil {
		return mtUpdateCheck{}, errors.New("MT_METADATA_FAILED")
	}
	c := mtUpdateCheck{State: "AVAILABLE", Time: now(), CurrentVersion: current, Relation: "no_upgrade"}
	count := 0
	for _, line := range strings.Split(raw, "\n") {
		f := strings.Split(line, " - ")
		if strings.TrimSpace(f[0]) != "magitrickle" {
			continue
		}
		count++
		if count != 1 || len(f) != 3 || f[1] != current || !componentVersionPattern.MatchString(f[2]) || f[2] == current {
			return mtUpdateCheck{}, errors.New("MT_METADATA_INVALID")
		}
		c.AvailableVersion = f[2]
		c.Relation = "newer"
	}
	return c, nil
}
func (m *mtMaintenance) apply() (string, error) {
	if !m.ready() {
		return "", errors.New("MT_EARLY_BOOT")
	}
	if m.process() != "running" {
		return "", errors.New("MT_SERVICE_NOT_RUNNING")
	}
	before := m.config()
	if before == "" {
		return "", errors.New("MT_CONFIG_UNVERIFIED")
	}
	ctx := context.Background() // never timeout-kill package hooks after browser disconnect
	c, e := m.check(ctx)
	if e != nil {
		return "", e
	}
	if c.Relation != "newer" {
		return "UNCHANGED", nil
	}
	if !m.ready() || m.process() != "running" || m.config() != before {
		return "", errors.New("MT_STATE_CHANGED")
	}
	if _, e = m.command(ctx, "install", "magitrickle"); e != nil {
		return "", errors.New("MT_INSTALL_FAILED")
	}
	if m.config() != before {
		return "", errors.New("MT_CONFIG_CHANGED")
	}
	if _, e = m.command(ctx, "restart"); e != nil {
		return "", errors.New("MT_RESTART_FAILED")
	}
	for i := 0; i < 10; i++ {
		if m.process() == "running" {
			break
		}
		if m.wait != nil {
			m.wait(time.Second)
		}
	}
	if m.process() != "running" {
		return "", errors.New("MT_SERVICE_UNVERIFIED")
	}
	actual, e := m.installed(ctx)
	if e != nil || actual != c.AvailableVersion {
		return "", errors.New("MT_VERSION_UNVERIFIED")
	}
	if m.config() != before {
		return "", errors.New("MT_CONFIG_CHANGED")
	}
	return "CHANGED", nil
}
func (a *app) handleMTCheck(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "check-magitrickle") {
		return
	}
	a.mu.Lock()
	if a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		a.mu.Unlock()
		updateJSON(w, 409, mtUpdateCheck{State: "UNKNOWN", Time: now(), ErrorCode: "BUSY"})
		return
	}
	a.importRunning = true
	a.lastMTCheck = mtUpdateCheck{}
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.importRunning = false; a.mu.Unlock() }()
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	c, e := a.mt.check(ctx)
	if e != nil {
		updateJSON(w, 502, mtUpdateCheck{State: "UNKNOWN", Time: now(), ErrorCode: e.Error()})
		return
	}
	a.mu.Lock()
	a.lastMTCheck = c
	a.mu.Unlock()
	updateJSON(w, 200, c)
}
func (a *app) handleMTUpdate(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "update-magitrickle") {
		return
	}
	a.mu.Lock()
	if a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		a.mu.Unlock()
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "BUSY"})
		return
	}
	checked, e := time.Parse(time.RFC3339, a.lastMTCheck.Time)
	if e != nil || time.Since(checked) > 10*time.Minute || a.lastMTCheck.State != "AVAILABLE" || a.lastMTCheck.Relation != "newer" {
		a.mu.Unlock()
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "CHECK_REQUIRED"})
		return
	}
	id := make([]byte, 12)
	if _, e = rand.Read(id); e != nil {
		a.mu.Unlock()
		updateJSON(w, 503, updateOperation{State: "UNKNOWN", Time: now(), ErrorCode: "STAGING_FAILED"})
		return
	}
	entry := updateOperation{ID: hex.EncodeToString(id), Component: "magitrickle", State: "RUNNING", Time: now()}
	a.importRunning = true
	a.updateResult = entry
	a.lastMTCheck = mtUpdateCheck{}
	a.lastUpdateCheck = updateCheck{}
	a.mu.Unlock()
	go func(entry updateOperation) {
		outcome, err := a.mt.apply()
		entry.Time = now()
		entry.State = "OK"
		entry.Outcome = outcome
		if err != nil {
			entry.State = "FAIL"
			entry.ErrorCode = err.Error()
		}
		a.mu.Lock()
		a.updateResult = entry
		a.importRunning = false
		a.mu.Unlock()
	}(entry)
	updateJSON(w, 202, entry)
}
