package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
)

var panelBuildChannel = "unknown"

type panelJob struct {
	Schema          int            `json:"schema"`
	ID              string         `json:"id"`
	State           string         `json:"state"`
	Phase           string         `json:"phase"`
	Time            string         `json:"timestamp"`
	Channel         string         `json:"channel"`
	PreviousVersion string         `json:"previous_version,omitempty"`
	Candidate       panelCandidate `json:"candidate"`
	ErrorCode       string         `json:"error_code,omitempty"`
	WorkerPID       int            `json:"worker_pid,omitempty"`
	WorkerStart     string         `json:"worker_start,omitempty"`
}
type panelCheckResult struct {
	State     string `json:"state"`
	Channel   string `json:"channel,omitempty"`
	Installed string `json:"installed_version,omitempty"`
	Runtime   string `json:"runtime_version,omitempty"`
	Available string `json:"available_version,omitempty"`
	SourceSHA string `json:"source_sha,omitempty"`
	Relation  string `json:"relation,omitempty"`
	ErrorCode string `json:"error_code,omitempty"`
}
type panelUpdater struct {
	root, dir string
	mu        sync.Mutex
	checked   *panelCandidate
	checkedAt time.Time
}

func newPanelUpdater(root string) *panelUpdater {
	return &panelUpdater{root: root, dir: filepath.Join(root, "etc/kas-control-center-update")}
}
func (p *panelUpdater) gate() bool {
	_, e := os.Lstat(filepath.Join(p.dir, "gate"))
	return !os.IsNotExist(e)
}
func (p *panelUpdater) prepareDir() error {
	for _, d := range []string{p.root, filepath.Join(p.root, "etc")} {
		st, e := os.Lstat(d)
		if e != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) {
			return errors.New("PANEL_STATE_UNSAFE")
		}
	}
	if e := os.Mkdir(p.dir, 0700); e != nil && !os.IsExist(e) {
		return e
	}
	st, e := os.Lstat(p.dir)
	if e != nil || !st.IsDir() || st.Mode().Perm() != 0700 || !inventoryOwned(st) {
		return errors.New("PANEL_STATE_UNSAFE")
	}
	return nil
}
func (p *panelUpdater) acquireGate() error {
	if e := p.prepareDir(); e != nil {
		return e
	}
	if e := os.Mkdir(filepath.Join(p.dir, "gate"), 0700); e != nil {
		return errors.New("PANEL_UPDATE_BUSY")
	}
	return syncPanelDir(p.dir)
}
func syncPanelDir(dir string) error {
	f, e := os.Open(dir)
	if e != nil {
		return e
	}
	defer f.Close()
	return f.Sync()
}
func (p *panelUpdater) writePrivate(name string, v any) error {
	if e := p.prepareDir(); e != nil {
		return e
	}
	raw, e := json.Marshal(v)
	if e != nil {
		return e
	}
	f, e := os.CreateTemp(p.dir, ".state-")
	if e != nil {
		return e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if e = f.Chmod(0600); e == nil {
		_, e = f.Write(raw)
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e == nil {
		e = os.Rename(tmp, filepath.Join(p.dir, name))
	}
	if e == nil {
		e = syncPanelDir(p.dir)
	}
	return e
}
func (p *panelUpdater) writeJob(j panelJob) error {
	j.Time = now()
	return p.writePrivate("job.json", j)
}
func (p *panelUpdater) readJob() (panelJob, error) {
	var j panelJob
	b, e := inventoryFile(p.root, "etc/kas-control-center-update/job.json", 16384, true)
	if e != nil {
		return j, e
	}
	if strictPanelJSON(b, &j) != nil || j.Schema != 1 || len(j.ID) != 24 || !isHex(j.ID) {
		return j, errors.New("PANEL_STATE_UNSAFE")
	}
	return j, nil
}
func isHex(s string) bool { _, e := hex.DecodeString(s); return e == nil }

// The selected update channel lives in its own private file inside the update
// state directory, never in the panel settings JSON: an unknown settings field
// would be rejected by the strict parser of an older panel build, while this
// file is simply ignored by beta.1. An absent or unreadable file means the
// compiled build channel.
func (p *panelUpdater) selectedChannel() string {
	b, e := inventoryFile(p.root, "etc/kas-control-center-update/channel", 32, false)
	if e != nil {
		return ""
	}
	if s := string(b); s == "experimental\n" || s == "stable\n" {
		return s[:len(s)-1]
	}
	return ""
}
func (p *panelUpdater) effectiveChannel() string {
	if s := p.selectedChannel(); s != "" {
		return s
	}
	return panelBuildChannel
}

// panelChannelTargets lists the channels this installation may select. The
// compiled build channel is provenance, not a restriction: both channels are
// explicit user opt-in on any build, per the beta.2 contract. Version
// monotonicity (strictly newer via real opkg) still blocks downgrades, so a
// stable panel sees no experimental offer until a strictly newer beta exists.
func panelChannelTargets(build string) []string {
	if panelChannelKnown(build) {
		return []string{"experimental", "stable"}
	}
	return nil
}
func (p *panelUpdater) storeChannel(channel string) error {
	if !panelChannelKnown(channel) {
		return errors.New("PANEL_CHANNEL_UNKNOWN")
	}
	if e := p.prepareDir(); e != nil {
		return e
	}
	f, e := os.CreateTemp(p.dir, ".channel-")
	if e != nil {
		return e
	}
	tmp := f.Name()
	defer os.Remove(tmp)
	if e = f.Chmod(0600); e == nil {
		_, e = f.WriteString(channel + "\n")
	}
	if e == nil {
		e = f.Sync()
	}
	closeErr := f.Close()
	if e == nil {
		e = closeErr
	}
	if e == nil {
		e = os.Rename(tmp, filepath.Join(p.dir, "channel"))
	}
	if e == nil {
		e = syncPanelDir(p.dir)
	}
	if e == nil {
		// A candidate checked on the previous channel must never be applied.
		p.mu.Lock()
		p.checked = nil
		p.mu.Unlock()
	}
	return e
}

type panelChannelState struct {
	Channel      string   `json:"channel"`
	BuildChannel string   `json:"build_channel"`
	Allowed      []string `json:"allowed"`
	ErrorCode    string   `json:"error_code,omitempty"`
}

func (a *app) handlePanelChannel(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		updateJSON(w, 200, panelChannelState{Channel: a.panelUpdate.effectiveChannel(), BuildChannel: panelBuildChannel, Allowed: panelChannelTargets(panelBuildChannel)})
		return
	}
	if r.Method != http.MethodPost {
		updateJSON(w, 405, panelChannelState{ErrorCode: "METHOD_NOT_ALLOWED"})
		return
	}
	if r.Header.Get("Origin") != a.expectedOrigin(r.Host) || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-KAS-Confirm") != "set-panel-channel" {
		updateJSON(w, 403, panelChannelState{ErrorCode: "REQUEST_BLOCKED"})
		return
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		updateJSON(w, 403, panelChannelState{ErrorCode: "REQUEST_BLOCKED"})
		return
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 128))
	var req struct {
		Channel string `json:"channel"`
	}
	if err != nil || strictPanelJSON(raw, &req) != nil || req.Channel == "" {
		updateJSON(w, 400, panelChannelState{ErrorCode: "INVALID_BODY"})
		return
	}
	allowed := false
	for _, c := range panelChannelTargets(panelBuildChannel) {
		if c == req.Channel {
			allowed = true
		}
	}
	if !allowed {
		updateJSON(w, 400, panelChannelState{ErrorCode: "PANEL_CHANNEL_UNKNOWN"})
		return
	}
	// Selection only: switching the channel never starts a check or install.
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.panelUpdateBusy() || a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		updateJSON(w, 409, panelChannelState{ErrorCode: "BUSY"})
		return
	}
	if e := a.panelUpdate.storeChannel(req.Channel); e != nil {
		updateJSON(w, 503, panelChannelState{ErrorCode: panelErrorCode(e)})
		return
	}
	updateJSON(w, 200, panelChannelState{Channel: req.Channel, BuildChannel: panelBuildChannel, Allowed: panelChannelTargets(panelBuildChannel)})
}
func (p *panelUpdater) stage(j panelJob) string {
	return filepath.Join(p.root, "tmp/.kas-panel-update-"+j.ID)
}
func (p *panelUpdater) installed() (string, string, error) {
	b, e := inventoryFile(p.root, "lib/opkg/info/kas-control-center.control", 65536, false)
	if e != nil {
		return "", "", errors.New("PANEL_NOT_PACKAGE_OWNED")
	}
	c, e := panelFields(b, ":")
	if e != nil || c["Package"] != "kas-control-center" || !componentVersionPattern.MatchString(c["Version"]) {
		return "", "", errors.New("PANEL_NOT_PACKAGE_OWNED")
	}
	b, e = inventoryFile(p.root, "share/kas-control-center/BUILD_INFO", 8192, false)
	if e != nil {
		return "", "", errors.New("PANEL_IDENTITY_MISMATCH")
	}
	info, e := panelFields(b, "=")
	if e != nil || info["Version"] != c["Version"] || !componentSourcePattern.MatchString(info["KAS_SOURCE_SHA"]) {
		return "", "", errors.New("PANEL_IDENTITY_MISMATCH")
	}
	return c["Version"], info["KAS_SOURCE_SHA"], nil
}
func panelAssetURL(tag, name string) string {
	return "https://github.com/saymer-alt/keenetic-auto-setup/releases/download/" + tag + "/" + name
}
func panelAssetClient(root string) *http.Client {
	c := updateClientForRoot(root)
	c.Timeout = 180 * time.Second
	c.CheckRedirect = func(req *http.Request, via []*http.Request) error {
		h := req.URL.Hostname()
		if len(via) > 3 || req.URL.Scheme != "https" || req.URL.User != nil || req.URL.Port() != "" || !(h == "release-assets.githubusercontent.com" || h == "objects.githubusercontent.com" || h == "github.com") {
			return errors.New("PANEL_REDIRECT_BLOCKED")
		}
		return nil
	}
	return c
}
// An absent unpublished stable channel is not a transport failure. Only the
// exact channel-index 404 is treated as an unpublished release. All other HTTP
// failures remain errors; never mask broken beta releases or missing IPKs.
func panelAssetStatusError(tag, name string, status int) error {
	if status == http.StatusOK {
		return nil
	}
	if status == http.StatusNotFound && tag == "kas-web-channel-stable" && name == "panel-update.json" {
		return errors.New("PANEL_CHANNEL_UNPUBLISHED")
	}
	return errors.New("PANEL_DOWNLOAD_FAILED")
}
func readPanelAsset(ctx context.Context, root, tag, name string, max int64) ([]byte, error) {
	req, e := http.NewRequestWithContext(ctx, "GET", panelAssetURL(tag, name), nil)
	if e != nil {
		return nil, e
	}
	req.Header.Set("User-Agent", "KAS-Control-Center")
	resp, e := panelAssetClient(root).Do(req)
	if e != nil {
		return nil, errors.New("PANEL_DOWNLOAD_FAILED")
	}
	defer resp.Body.Close()
	if e := panelAssetStatusError(tag, name, resp.StatusCode); e != nil {
		return nil, e
	}
	b, e := io.ReadAll(io.LimitReader(resp.Body, max+1))
	if e != nil || int64(len(b)) > max {
		return nil, errors.New("PANEL_METADATA_INVALID")
	}
	return b, nil
}
func (p *panelUpdater) candidate(ctx context.Context, channel, arch string) (panelCandidate, error) {
	if channel != "experimental" && channel != "stable" {
		return panelCandidate{}, errors.New("PANEL_CHANNEL_UNKNOWN")
	}
	// Read a single explicit channel index, never scan unrelated releases.
	channelTag := "kas-web-channel-" + channel
	raw, e := readPanelAsset(ctx, p.root, channelTag, "panel-update.json", 1<<20)
	if e != nil {
		return panelCandidate{}, e
	}
	c, e := parsePanelIndex(raw, channel, arch)
	if e != nil {
		return c, e
	}
	raw, e = fetchUpdateMetadata(ctx, updateClientForRoot(p.root), "https://api.github.com/repos/saymer-alt/keenetic-auto-setup/releases/tags/"+url.PathEscape(c.Tag))
	if e != nil {
		return c, e
	}
	var release struct {
		Tag        string `json:"tag_name"`
		Draft      bool   `json:"draft"`
		Prerelease bool   `json:"prerelease"`
		Assets     []struct {
			Name   string `json:"name"`
			Size   int64  `json:"size"`
			Digest string `json:"digest"`
			URL    string `json:"browser_download_url"`
			State  string `json:"state"`
		} `json:"assets"`
	}
	if json.Unmarshal(raw, &release) != nil || release.Tag != c.Tag || release.Draft || release.Prerelease != (channel == "experimental") {
		return c, errors.New("PANEL_METADATA_INVALID")
	}
	matches := 0
	for _, asset := range release.Assets {
		if asset.Name == c.Name {
			if asset.Size != c.Size || asset.Digest != "sha256:"+c.SHA256 || asset.URL != panelAssetURL(c.Tag, c.Name) || asset.State != "uploaded" {
				return c, errors.New("PANEL_METADATA_INVALID")
			}
			matches++
		}
	}
	if matches != 1 {
		return c, errors.New("PANEL_METADATA_INVALID")
	}
	return c, nil
}
func (a *app) handlePanelCheck(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "check-panel") {
		return
	}
	a.mu.Lock()
	if a.panelUpdateBusy() || a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		a.mu.Unlock()
		updateJSON(w, 409, panelCheckResult{State: "UNKNOWN", ErrorCode: "BUSY"})
		return
	}
	a.importRunning = true
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.importRunning = false; a.mu.Unlock() }()
	p := a.panelUpdate
	p.mu.Lock()
	p.checked = nil
	p.mu.Unlock()
	channel := p.effectiveChannel()
	result := panelCheckResult{State: "UNKNOWN", Channel: channel, Runtime: compiledPanelIdentity().Version}
	version, sha, e := p.installed()
	result.Installed = version
	if e == nil && (version != compiledPanelIdentity().Version || sha != compiledPanelIdentity().SourceSHA) {
		e = errors.New("PANEL_IDENTITY_MISMATCH")
	}
	if e == nil {
		_, e = inventoryFile(p.root, "bin/opkg", 8<<20, false)
	}
	if e == nil {
		arch := map[string]string{"arm64": "aarch64-3.10", "arm": "armv7-3.2", "mipsle": "mipsel-3.4", "mips": "mips-3.4"}[runtime.GOARCH]
		ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
		defer cancel()
		var c panelCandidate
		c, e = p.candidate(ctx, channel, arch)
		if e == nil {
			var newer bool
			newer, e = panelVersionNewer(ctx, filepath.Join(p.root, "bin/opkg"), version, c.Version)
			if e == nil {
				result.State = "OK"
				result.Available = c.Version
				result.SourceSHA = c.SourceSHA
				result.Relation = "not_newer"
				if newer {
					result.Relation = "newer"
					p.mu.Lock()
					p.checked = &c
					p.checkedAt = time.Now()
					p.mu.Unlock()
				}
			}
		}
	}
	if e != nil {
		result.ErrorCode = panelErrorCode(e)
		if result.ErrorCode == "PANEL_CHANNEL_UNPUBLISHED" {
			// No stable channel index has been published yet. This is an
			// expected state, not a failed download or an update candidate.
			result.State = "UNPUBLISHED"
			result.Relation = "not_newer"
			result.ErrorCode = ""
			updateJSON(w, 200, result)
			return
		}
		updateJSON(w, 502, result)
		return
	}
	updateJSON(w, 200, result)
}
func panelErrorCode(e error) string {
	if e == nil {
		return ""
	}
	s := e.Error()
	if strings.HasPrefix(s, "PANEL_") && len(s) < 80 && !strings.ContainsAny(s, " /\\\n") {
		return s
	}
	return "PANEL_UPDATE_FAILED"
}
func (a *app) handlePanelOperation(w http.ResponseWriter, r *http.Request) {
	if r.Method != "GET" {
		updateJSON(w, 405, updateOperation{State: "UNKNOWN", ErrorCode: "METHOD_NOT_ALLOWED"})
		return
	}
	j, e := a.panelUpdate.readJob()
	if e != nil {
		code := "NO_OPERATION"
		if a.panelUpdate.gate() {
			code = "PANEL_RECOVERY_REQUIRED"
		}
		updateJSON(w, 200, updateOperation{State: "UNKNOWN", ErrorCode: code})
		return
	}
	if a.panelUpdate.gate() && (j.State == "RUNNING" || j.State == "OK") {
		started, e := time.Parse(time.RFC3339, j.Time)
		missing := (j.WorkerPID > 0 || j.State == "OK") && (j.WorkerPID < 2 || j.WorkerStart == "" || panelProcessStart(j.WorkerPID) != j.WorkerStart)
		if missing || (j.Phase == "queued" && (e != nil || time.Since(started) > 30*time.Second)) {
			j.State = "FAIL"
			j.ErrorCode = "PANEL_RECOVERY_REQUIRED"
		}
	}
	// Expose only public operation evidence, not paths/private job payload.
	updateJSON(w, 200, struct {
		ID, State, Phase, Version, SourceSHA, ErrorCode string
		Gate                                            bool
	}{j.ID, j.State, j.Phase, j.Candidate.Version, j.Candidate.SourceSHA, j.ErrorCode, a.panelUpdate.gate()})
}
func (a *app) handlePanelApply(w http.ResponseWriter, r *http.Request) {
	if !a.validUpdateRequest(w, r, "update-panel") {
		return
	}
	p := a.panelUpdate
	a.mu.Lock()
	if a.panelUpdateBusy() || a.importRunning || a.running || a.shuttingDown || a.updateChecking {
		a.mu.Unlock()
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", ErrorCode: "BUSY"})
		return
	}
	a.importRunning = true
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.importRunning = false; a.mu.Unlock() }()
	p.mu.Lock()
	candidate := p.checked
	valid := candidate != nil && time.Since(p.checkedAt) < 10*time.Minute
	p.checked = nil
	p.mu.Unlock()
	if !valid {
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", ErrorCode: "CHECK_REQUIRED"})
		return
	}
	if e := p.acquireGate(); e != nil {
		updateJSON(w, 409, updateOperation{State: "UNKNOWN", ErrorCode: panelErrorCode(e)})
		return
	}
	id := make([]byte, 12)
	_, e := rand.Read(id)
	// The job channel is the channel of the checked candidate, not a fresh
	// read of the selection: a channel switch invalidates p.checked, so this
	// is always the channel whose index produced the candidate.
	j := panelJob{Schema: 1, ID: hex.EncodeToString(id), State: "RUNNING", Phase: "queued", Channel: candidate.Channel, PreviousVersion: compiledPanelIdentity().Version, Candidate: *candidate}
	if e == nil {
		e = p.writeJob(j)
	}
	if e == nil {
		e = p.prepareRunner(j)
	}
	if e == nil {
		// opkg preinst may now TERM the server. This job is NOT importer drain.
		a.mu.Lock()
		a.importRunning = false
		a.mu.Unlock()
		e = p.launchWorker(j)
	}
	if e != nil {
		p.failJob(j, panelErrorCode(e), false)
		updateJSON(w, 503, updateOperation{State: "FAIL", ErrorCode: panelErrorCode(e)})
		return
	}
	updateJSON(w, 202, map[string]string{"id": j.ID, "state": "RUNNING"})
}
func (p *panelUpdater) failJob(j panelJob, code string, mutated bool) {
	j.State = "FAIL"
	j.ErrorCode = code
	if mutated {
		j.Phase = "recovery_required"
	}
	if p.writeJob(j) == nil && !mutated {
		_ = os.Remove(filepath.Join(p.dir, "gate"))
		_ = syncPanelDir(p.dir)
		_ = os.RemoveAll(p.stage(j))
	}
}

func (a *app) panelUpdateBusy() bool { return a.panelUpdate != nil && a.panelUpdate.gate() }
