package main

// A one-shot read-only adapter for the existing canonical kas-sys-metrics.sh.
// It never runs automatically, executes no external network checks and installs
// no new service. All values remain observations, not health diagnoses.
import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"time"
)

type systemMetrics struct {
	Schema      string `json:"schema"`
	Tool        string `json:"tool"`
	ToolVersion string `json:"tool_version"`
	Generated   string `json:"generated_utc"`
	ExitCode    int    `json:"exit_code"`
	Temperature struct {
		Status  string `json:"status"`
		Celsius string `json:"celsius"`
		Zone    string `json:"zone"`
		Type    string `json:"type"`
		Source  string `json:"source"`
		Note    string `json:"note"`
	} `json:"temperature"`
	Load struct {
		Status  string `json:"status"`
		OneMin  string `json:"one_min"`
		FiveMin string `json:"five_min"`
		FifteenMin string `json:"fifteen_min"`
		Note string `json:"note"`
	} `json:"load"`
	Uptime struct {
		Status string `json:"status"`
		Seconds string `json:"seconds"`
		Note string `json:"note"`
	} `json:"uptime"`
	Memory struct {
		Status string `json:"status"`
		Total string `json:"mem_total_kb"`
		Available string `json:"mem_available_kb"`
	} `json:"memory"`
	Swap struct {
		Status string `json:"status"`
		Total string `json:"total_kb"`
		Free string `json:"free_kb"`
	} `json:"swap"`
}

var metricNumber = regexp.MustCompile(`^[0-9]{1,12}(?:\.[0-9]{1,4})?$`)
func metricStatus(s string) bool { return s == "PASS" || s == "UNKNOWN" || s == "N/A" || s == "INFO" }
func numericWhenObserved(status string, values ...string) bool {
	if !metricStatus(status) { return false }
	if status != "PASS" && status != "INFO" { return true }
	for _, value := range values { if !metricNumber.MatchString(value) { return false } }
	return true
}

func validateMetrics(m *systemMetrics) bool {
	if m == nil || m.Schema != "router-metrics/v1" || m.Tool != "kas-sys-metrics.sh" ||
		m.ToolVersion != "0.1.0" || m.ExitCode < 0 || m.ExitCode > 1 { return false }
	if !numericWhenObserved(m.Temperature.Status, m.Temperature.Celsius) ||
		!numericWhenObserved(m.Load.Status, m.Load.OneMin, m.Load.FiveMin, m.Load.FifteenMin) ||
		!numericWhenObserved(m.Uptime.Status, m.Uptime.Seconds) ||
		!numericWhenObserved(m.Memory.Status, m.Memory.Total, m.Memory.Available) ||
		!numericWhenObserved(m.Swap.Status, m.Swap.Total, m.Swap.Free) { return false }
	if m.Temperature.Status == "PASS" {
		t, err := strconv.ParseFloat(m.Temperature.Celsius, 64)
		if err != nil || t < 0 || t > 150 { return false }
		if len(m.Temperature.Zone) > 80 || len(m.Temperature.Type) > 80 || (m.Temperature.Source != "sysfs:thermal" && m.Temperature.Source != "sysfs:hwmon") { return false }
	}
	if m.Uptime.Status == "PASS" {
		u, err := strconv.ParseFloat(m.Uptime.Seconds, 64)
		if err != nil || u < 0 || u > 10000000000 { return false }
	}
	if m.Memory.Status == "PASS" {
		a, _ := strconv.ParseUint(m.Memory.Available, 10, 64)
		t, _ := strconv.ParseUint(m.Memory.Total, 10, 64)
		if a > t || t > 1000000000 { return false }
	}
	if m.Swap.Status == "INFO" {
		a, _ := strconv.ParseUint(m.Swap.Free, 10, 64)
		t, _ := strconv.ParseUint(m.Swap.Total, 10, 64)
		if a > t || t > 1000000000 { return false }
	}
	return true
}

func runMetricsCollector(ctx context.Context, script []byte, sysRoot, procRoot string) (*systemMetrics, error) {
	return runMetricsCollectorWithShell(ctx, "/bin/sh", script, sysRoot, procRoot)
}

// Keenetic BusyBox ash does not support "sh -s". Write our trusted embedded
// script to a private temporary file and pass it as a positional script name.
// Shell path injection is reserved for testing the BusyBox-incompatible case.
func runMetricsCollectorWithShell(ctx context.Context, shell string, script []byte, sysRoot, procRoot string) (*systemMetrics, error) {
	if len(script) == 0 || len(script) > 32768 {
		return nil, errors.New("metrics collector unavailable")
	}
	dir, err := os.MkdirTemp("", "kas-metrics-")
	if err != nil { return nil, err }
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "result.json")
	scriptPath := filepath.Join(dir, "collector.sh")
	if err := os.WriteFile(scriptPath, script, 0600); err != nil {
		return nil, errors.New("metrics collector unavailable")
	}
	cmd := exec.CommandContext(ctx, shell, scriptPath, "--json", path)
	cmd.Env = []string{"PATH=/opt/bin:/usr/bin:/bin", "NO_COLOR=1", "TERM=dumb", "LC_ALL=C",
		"KAS_SYSFS_ROOT="+sysRoot, "KAS_PROC_ROOT="+procRoot}
	// Collector prints a verbose report; do not persist or expose it.
	err = cmd.Run()
	var exitErr *exec.ExitError
	if err != nil && (!errors.As(err, &exitErr) || exitErr.ExitCode() != 1) { return nil, errors.New("metrics collector failed") }
	if ctx.Err() != nil { return nil, ctx.Err() }
	f, err := os.Open(path)
	if err != nil { return nil, errors.New("metrics JSON unavailable") }
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || st.Size() > 8192 || st.Size() == 0 {
		return nil, errors.New("metrics JSON invalid")
	}
	raw, err := io.ReadAll(io.LimitReader(f, 8193))
	if err != nil || len(raw) > 8192 { return nil, errors.New("metrics JSON oversized") }
	var m systemMetrics
	if json.Unmarshal(raw, &m) != nil || !validateMetrics(&m) {
		return nil, errors.New("invalid metrics contract")
	}
	if err != nil { return nil, err }
	return &m, nil
}

func (a *app) handleMetrics(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost { filterError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED"); return }
	if !a.requestOriginAllowed(r) || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-KAS-Confirm") != "metrics" {
		filterError(w, http.StatusForbidden, "REQUEST_BLOCKED"); return
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		filterError(w, http.StatusForbidden, "REQUEST_BLOCKED"); return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 32)
	var body map[string]any
	decoder := json.NewDecoder(r.Body)
	if decoder.Decode(&body) != nil || len(body) != 0 {
		filterError(w, http.StatusBadRequest, "INVALID_BODY"); return
	}
	var extra any
	if !errors.Is(decoder.Decode(&extra), io.EOF) {
		filterError(w, http.StatusBadRequest, "INVALID_BODY"); return
	}
	a.mu.Lock()
	blocked := a.panelUpdateBusy() || a.running || a.importRunning || a.shuttingDown
	a.mu.Unlock()
	if blocked { filterError(w, http.StatusConflict, "BUSY"); return }
	ctx, cancel := context.WithTimeout(r.Context(), 12*time.Second)
	defer cancel()
	m, err := runMetricsCollector(ctx, a.metrics, "/sys", "/proc")
	if err != nil {
		filterError(w, http.StatusServiceUnavailable, "METRICS_UNAVAILABLE")
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	writeFilterJSON(w, http.StatusOK, m)
}
