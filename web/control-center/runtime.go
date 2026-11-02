package main

// Fixed, read-only observations. Never execute service/init binaries.
import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type doctorSummary struct {
	Verdict string `json:"verdict"`
	OK      int    `json:"ok"`
	Warn    int    `json:"warn"`
	Fail    int    `json:"fail"`
	Info    int    `json:"info"`
}

var ansiSequence = regexp.MustCompile(`\x1b\[[0-9;]*m`)
var doctorFooter = regexp.MustCompile(`\A=== Mihomo Doctor Summary ===\nOK: +([0-9]{1,6})\nWARN: ([0-9]{1,6})\nFAIL: ([0-9]{1,6})\nINFO: ([0-9]{1,6})\n\n\[(OK|WARN|FAIL)\] Overall status: (OK|WARN|FAIL)\n?\z`)

func parseDoctorSummary(output string, exit int) *doctorSummary {
	output = strings.ReplaceAll(ansiSequence.ReplaceAllString(output, ""), "\r\n", "\n")
	const marker = "=== Mihomo Doctor Summary ==="
	if strings.Count(output, marker) != 1 {
		return nil
	}
	i := strings.Index(output, marker)
	if i < 0 || i > 0 && output[i-1] != '\n' {
		return nil
	}
	m := doctorFooter.FindStringSubmatch(output[i:])
	if m == nil || m[5] != m[6] {
		return nil
	}
	counts := make([]int, 4)
	for i := range counts {
		counts[i], _ = strconv.Atoi(m[i+1])
	}
	verdict, code := "OK", 0
	if counts[2] > 0 {
		verdict, code = "FAIL", 2
	} else if counts[1] > 0 {
		verdict, code = "WARN", 1
	}
	if m[5] != verdict || exit != code {
		return nil
	}
	return &doctorSummary{verdict, counts[0], counts[1], counts[2], counts[3]}
}

type serviceObservation struct {
	State         string `json:"state"`
	Version       string `json:"version,omitempty"`
	VersionSource string `json:"version_source,omitempty"`
}
type runtimeObservation struct {
	Mihomo      serviceObservation `json:"mihomo"`
	MagiTrickle serviceObservation `json:"magitrickle"`
}

func readSmall(path string, limit int64) ([]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	b, err := io.ReadAll(io.LimitReader(f, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, io.ErrShortBuffer
	}
	return b, nil
}
func processEvidence(proc string, binaries []string) string {
	var candidates []os.FileInfo
	for _, path := range binaries {
		if st, err := os.Stat(path); err == nil && st.Mode().IsRegular() {
			candidates = append(candidates, st)
		}
	}
	if len(candidates) == 0 {
		return "absent"
	}
	f, err := os.Open(proc)
	if err != nil {
		return "unknown"
	}
	defer f.Close()
	entries, err := f.Readdirnames(4097)
	if err != nil && err != io.EOF || len(entries) > 4096 {
		return "unknown"
	}
	uncertain := false
	for _, pid := range entries {
		if _, err := strconv.ParseUint(pid, 10, 32); err != nil {
			continue
		}
		dir := filepath.Join(proc, pid)
		st, err := os.Stat(filepath.Join(dir, "exe"))
		if err != nil {
			if os.IsPermission(err) {
				uncertain = true
			}
			continue
		}
		matched := false
		for _, candidate := range candidates {
			if os.SameFile(candidate, st) {
				matched = true
				break
			}
		}
		if !matched {
			continue
		}
		stat, err := readSmall(filepath.Join(dir, "stat"), 4096)
		if err != nil {
			uncertain = true
			continue
		}
		index := strings.LastIndex(string(stat), ") ")
		if index < 0 {
			uncertain = true
			continue
		}
		fields := strings.Fields(string(stat)[index+2:])
		if len(fields) < 20 {
			uncertain = true
			continue
		}
		if fields[0] == "Z" || fields[0] == "X" {
			continue
		}
		if !strings.Contains("RSDTtIWPK", fields[0]) || len(fields[0]) != 1 {
			uncertain = true
			continue
		}
		again, err := os.Stat(filepath.Join(dir, "exe"))
		if err != nil || !os.SameFile(st, again) {
			uncertain = true
			continue
		}
		return "running"
	}
	if uncertain {
		return "unknown"
	}
	// An incomplete/restricted proc view cannot prove process absence.
	self, err := readSmall(filepath.Join(proc, "self/stat"), 4096)
	if err != nil || len(self) == 0 {
		return "unknown"
	}
	init, err := os.Stat(filepath.Join(proc, "1"))
	if err != nil || !init.IsDir() {
		return "unknown"
	}
	mounts, err := readSmall(filepath.Join(proc, "mounts"), 262144)
	if err != nil {
		return "unknown"
	}
	for _, field := range strings.Fields(string(mounts)) {
		for _, option := range strings.Split(field, ",") {
			if strings.HasPrefix(option, "hidepid=") && option != "hidepid=0" {
				return "unknown"
			}
		}
	}
	return "stopped"
}
func parsePackageVersion(data, expected string) string {
	name, version := "", ""
	n, v := 0, 0
	for _, line := range strings.Split(data, "\n") {
		if strings.HasPrefix(line, "Package:") {
			n++
			name = strings.TrimSpace(strings.TrimPrefix(line, "Package:"))
		}
		if strings.HasPrefix(line, "Version:") {
			v++
			version = strings.TrimSpace(strings.TrimPrefix(line, "Version:"))
		}
	}
	if n != 1 || v != 1 || name != expected || !componentVersionPattern.MatchString(version) {
		return ""
	}
	return version
}
func readMihomoVersion(ctx context.Context, client *http.Client, target, secret string) string {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		return ""
	}
	if secret != "" {
		req.Header.Set("Authorization", "Bearer "+secret)
	}
	response, err := client.Do(req)
	if err != nil {
		return ""
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return ""
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, 4097))
	if err != nil || len(raw) > 4096 {
		return ""
	}
	var body struct {
		Meta    bool   `json:"meta"`
		Version string `json:"version"`
	}
	if json.Unmarshal(raw, &body) != nil || !body.Meta || !componentVersionPattern.MatchString(body.Version) {
		return ""
	}
	return body.Version
}
func (a *app) runtimeStatus(ctx context.Context) runtimeObservation {
	observation := runtimeObservation{
		Mihomo:      serviceObservation{State: processEvidence("/proc", []string{"/opt/bin/mihomo", "/opt/sbin/mihomo"})},
		MagiTrickle: serviceObservation{State: processEvidence("/proc", []string{"/opt/bin/magitrickled", "/opt/bin/magitrickle"})},
	}
	// Always loopback, no proxy/redirect or configurable target. Export opt-in is
	// unrelated to this version-only endpoint; never read YAML to find credentials.
	client := &http.Client{Timeout: time.Second, Transport: &http.Transport{Proxy: nil, DialContext: (&net.Dialer{Timeout: time.Second}).DialContext, DisableKeepAlives: true}, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	secret := ""
	if a.providers != nil {
		secret = a.providers.secret
	}
	if version := readMihomoVersion(ctx, client, "http://127.0.0.1:9090/version", secret); version != "" {
		observation.Mihomo.Version = version
		observation.Mihomo.VersionSource = "api"
	}
	if data, err := inventoryFile("/opt", "lib/opkg/info/magitrickle.control", 65536, false); err == nil {
		if version := parsePackageVersion(string(data), "magitrickle"); version != "" {
			observation.MagiTrickle.Version = version
			observation.MagiTrickle.VersionSource = "package"
		}
	}
	return observation
}
