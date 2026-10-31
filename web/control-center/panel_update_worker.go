package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

func (p *panelUpdater) safeStage(j panelJob) error {
	st, e := os.Lstat(p.stage(j))
	if e != nil || !st.IsDir() || st.Mode().Perm() != 0700 || !inventoryOwned(st) {
		return errors.New("PANEL_STAGE_UNSAFE")
	}
	return nil
}
func (p *panelUpdater) prepareRunner(j panelJob) error {
	if !j.Candidate.valid() {
		return panelPackageError
	}
	st, e := os.Lstat(filepath.Join(p.root, "tmp"))
	if e != nil || !st.IsDir() || !inventoryOwned(st) {
		return errors.New("PANEL_STAGE_UNSAFE")
	}
	if e := p.checkSpace(j, 0); e != nil {
		return e
	}
	if e := os.Mkdir(p.stage(j), 0700); e != nil {
		return errors.New("PANEL_STAGE_UNSAFE")
	}
	// No retained old IPK or rollback. The private executable only runs this job.
	in, e := panelSafeOpen(p.root, "bin/kas-control-center", panelMaxPayload)
	if e != nil {
		return e
	}
	defer in.Close()
	out, e := os.OpenFile(filepath.Join(p.stage(j), "runner"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0700)
	if e != nil {
		return e
	}
	_, e = io.Copy(out, io.LimitReader(in, panelMaxPayload+1))
	if e == nil {
		e = out.Sync()
	}
	closeErr := out.Close()
	if e == nil {
		e = closeErr
	}
	return e
}
func (p *panelUpdater) launchWorker(j panelJob) error {
	if e := p.safeStage(j); e != nil {
		return e
	}
	cmd := exec.Command(filepath.Join(p.stage(j), "runner"), "-panel-update-worker")
	cmd.Dir = p.stage(j)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	null, e := os.OpenFile(os.DevNull, os.O_RDWR, 0)
	if e != nil {
		return e
	}
	defer null.Close()
	cmd.Stdin = null
	cmd.Stdout = null
	cmd.Stderr = null
	if e := cmd.Start(); e != nil {
		return errors.New("PANEL_WORKER_START_FAILED")
	}
	go func() { _ = cmd.Wait() }()
	return nil
}
func (p *panelUpdater) workerLock() (*os.File, error) {
	if e := p.prepareDir(); e != nil {
		return nil, e
	}
	target := filepath.Join(p.dir, "worker.lock")
	if st, e := os.Lstat(target); e == nil && (!st.Mode().IsRegular() || st.Mode().Perm() != 0600 || !inventoryOwned(st)) {
		return nil, errors.New("PANEL_STATE_UNSAFE")
	} else if e != nil && !os.IsNotExist(e) {
		return nil, e
	}
	f, e := os.OpenFile(target, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600)
	if e != nil {
		return nil, e
	}
	if e := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); e != nil {
		f.Close()
		return nil, errors.New("PANEL_WORKER_BUSY")
	}
	return f, nil
}
func panelFileDigest(root, relative string, max int64) (string, error) {
	// Parent/path safety is checked using the existing inventory contract.
	f, e := panelSafeOpen(root, relative, max)
	if e != nil {
		return "", e
	}
	defer f.Close()
	h := sha256.New()
	n, e := io.Copy(h, io.LimitReader(f, max+1))
	if e != nil || n > max {
		return "", errors.New("PANEL_FILE_UNVERIFIED")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// opkgInfoFile reads an opkg-owned info file as package-ownership evidence.
// The file mode belongs to opkg, not to this panel: the aarch64 Entware feed
// (opkg 2022) writes world-writable 0666 lists on real installations while
// the x64 2024 build honors the umask (0600); both were observed in the
// disposable service lab. Structural safety is still enforced: root-owned
// regular file, no symlinked component, bounded size, nofollow open and a
// stable identity between stat and read.
func opkgInfoFile(root, relative string, max int64) ([]byte, error) {
	target := filepath.Join(root, relative)
	for dir := filepath.Dir(target); ; dir = filepath.Dir(dir) {
		st, e := os.Lstat(dir)
		if e != nil || !st.IsDir() || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) {
			return nil, errors.New("PANEL_FILE_UNSAFE")
		}
		if dir == root {
			break
		}
		if filepath.Dir(dir) == dir {
			return nil, errors.New("PANEL_FILE_UNSAFE")
		}
	}
	st, e := os.Lstat(target)
	if e != nil || !st.Mode().IsRegular() || st.Size() > max || !inventoryOwned(st) {
		return nil, errors.New("PANEL_FILE_UNSAFE")
	}
	f, e := os.OpenFile(target, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	opened, e := f.Stat()
	if e != nil || !os.SameFile(st, opened) {
		f.Close()
		return nil, errors.New("PANEL_FILE_UNSAFE")
	}
	data, e := io.ReadAll(io.LimitReader(f, max+1))
	closeErr := f.Close()
	if e != nil || int64(len(data)) > max {
		return nil, errors.New("PANEL_FILE_UNSAFE")
	}
	if closeErr != nil {
		return nil, closeErr
	}
	return data, nil
}
func (p *panelUpdater) integrity() error {
	if _, _, e := p.installed(); e != nil {
		return e
	}
	b, e := inventoryFile(p.root, "share/kas-control-center/BUILD_INFO", 8192, false)
	if e != nil {
		return e
	}
	info, e := panelFields(b, "=")
	if e != nil {
		return e
	}
	digest, e := panelFileDigest(p.root, "bin/kas-control-center", panelMaxPayload)
	if e != nil || digest != info["Binary_SHA256"] {
		return errors.New("PANEL_IDENTITY_MISMATCH")
	}
	b, e = inventoryFile(p.root, "etc/init.d/S98kas-control-center", 128<<10, false)
	if e != nil || !strings.Contains(string(b), "# KAS-CONTROL-CENTER-IPK-v1") {
		return errors.New("PANEL_NOT_PACKAGE_OWNED")
	}
	b, e = opkgInfoFile(p.root, "lib/opkg/info/kas-control-center.list", 65536)
	if e != nil {
		return errors.New("PANEL_NOT_PACKAGE_OWNED")
	}
	for _, s := range []string{"/opt/bin/kas-control-center", "/opt/etc/init.d/S98kas-control-center", "/opt/share/kas-control-center/BUILD_INFO"} {
		if !strings.Contains("\n"+string(b)+"\n", "\n"+s+"\n") {
			return errors.New("PANEL_NOT_PACKAGE_OWNED")
		}
	}
	return nil
}
func (p *panelUpdater) configDigest() (string, error) {
	hash := sha256.New()
	for _, name := range []string{"etc/kas-control-center.settings.json", "etc/kas-control-center.password", "etc/kas-control-center.proxy-origin", "etc/kas-control-center.export-names", "etc/kas-control-center.mihomo-api-secret", "etc/kas-control-center.home-only", "etc/mihomo/config.yaml"} {
		b, e := inventoryFile(p.root, name, 4<<20, false)
		if e != nil && !os.IsNotExist(e) {
			return "", errors.New("PANEL_CONFIG_UNVERIFIED")
		}
		hash.Write([]byte(name + "\x00"))
		if os.IsNotExist(e) {
			hash.Write([]byte("absent\x00"))
		} else {
			hash.Write([]byte(fmt.Sprintf("%d\x00", len(b))))
			hash.Write(b)
		}
	}
	return fmt.Sprintf("%x", hash.Sum(nil)), nil
}

// Conservative peak: private IPK+runner, opkg compressed copies, unpacked staging,
// installed replacement and metadata slack. Existing files are already allocated.
func (p *panelUpdater) checkSpace(j panelJob, runner int64) error {
	required := 4*j.Candidate.Size + 3*j.Candidate.UnpackedSize + runner + (8 << 20)
	if required <= 0 || required > 256<<20 {
		return errors.New("PANEL_SPACE_UNVERIFIED")
	}
	for _, dir := range []string{p.root, filepath.Join(p.root, "tmp")} {
		var s syscall.Statfs_t
		if e := syscall.Statfs(dir, &s); e != nil {
			return errors.New("PANEL_SPACE_UNVERIFIED")
		}
		if s.Bsize <= 0 || uint64(s.Bavail) > ^uint64(0)/uint64(s.Bsize) || uint64(s.Bavail)*uint64(s.Bsize) < uint64(required) || s.Files > 0 && s.Ffree < 64 {
			return errors.New("PANEL_INSUFFICIENT_SPACE")
		}
	}
	return nil
}
func (p *panelUpdater) download(j panelJob) error {
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	req, e := http.NewRequestWithContext(ctx, "GET", panelAssetURL(j.Candidate.Tag, j.Candidate.Name), nil)
	if e != nil {
		return e
	}
	resp, e := panelAssetClient(p.root).Do(req)
	if e != nil {
		return errors.New("PANEL_DOWNLOAD_FAILED")
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 || resp.ContentLength > j.Candidate.Size {
		return errors.New("PANEL_DOWNLOAD_FAILED")
	}
	out, e := os.OpenFile(filepath.Join(p.stage(j), "candidate.ipk"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if e != nil {
		return e
	}
	n, e := io.Copy(out, io.LimitReader(resp.Body, j.Candidate.Size+1))
	if e == nil && n != j.Candidate.Size {
		e = errors.New("PANEL_DOWNLOAD_FAILED")
	}
	if e == nil {
		e = out.Sync()
	}
	closeErr := out.Close()
	if e == nil {
		e = closeErr
	}
	return e
}
func panelFixedCommand(path string, args ...string) error {
	cmd := exec.Command(path, args...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	return cmd.Run()
}

// panelJobChannelAllowed is the worker-side channel admission rule: the job
// channel must be known and its candidate tag must belong to that channel.
// Cross-channel jobs are admitted in both explicit opt-in directions
// (experimental→stable migration and stable→experimental beta opt-in); the
// candidate IPK must still carry the job channel in its BUILD_INFO and real
// opkg comparison still blocks every downgrade.
func panelJobChannelAllowed(build, job string, candidate panelCandidate) bool {
	return panelChannelKnown(job) && panelChannelKnown(build) && candidate.Channel == job && panelTagValid(job, candidate.Tag)
}
func (p *panelUpdater) runWorker() (result error) {
	lock, e := p.workerLock()
	if e != nil {
		return e
	}
	defer lock.Close()
	j, e := p.readJob()
	if e != nil {
		return e
	}
	if !p.gate() || j.State != "RUNNING" || j.Phase != "queued" {
		return errors.New("PANEL_RECOVERY_REQUIRED")
	}
	mutated := false
	defer func() {
		if result != nil {
			p.failJob(j, panelErrorCode(result), mutated)
		}
	}()
	if e := p.safeStage(j); e != nil {
		return e
	}
	// Channel contract: the job channel must be known and its candidate tag
	// must belong to that channel. Both explicit opt-in cross-channel moves
	// (experimental→stable migration, stable→experimental beta opt-in) pass
	// here; every package check below still applies and BUILD_INFO.Channel
	// must match the candidate channel. Downgrades stay blocked by real opkg
	// comparison regardless of channel.
	if !j.Candidate.valid() || !panelJobChannelAllowed(panelBuildChannel, j.Channel, j.Candidate) {
		return errors.New("PANEL_CHANNEL_UNKNOWN")
	}
	j.WorkerPID = os.Getpid()
	j.WorkerStart = panelProcessStart(os.Getpid())
	if j.WorkerStart == "" {
		return errors.New("PANEL_PROCESS_UNVERIFIED")
	}
	j.Phase = "download"
	if e := p.writeJob(j); e != nil {
		return e
	}
	if e := p.integrity(); e != nil {
		return e
	}
	version, _, e := p.installed()
	if e != nil || version != j.PreviousVersion {
		return errors.New("PANEL_IDENTITY_MISMATCH")
	}
	opkg := filepath.Join(p.root, "bin/opkg")
	if _, e := inventoryFile(p.root, "bin/opkg", 8<<20, false); e != nil {
		return errors.New("PANEL_OPKG_UNAVAILABLE")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	newer, e := panelVersionNewer(ctx, opkg, version, j.Candidate.Version)
	if e != nil || !newer {
		return errors.New("PANEL_VERSION_UNVERIFIED")
	}
	before, e := p.configDigest()
	if e != nil {
		return e
	}
	runner, e := os.Stat(filepath.Join(p.stage(j), "runner"))
	if e != nil {
		return e
	}
	if e := p.checkSpace(j, runner.Size()); e != nil {
		return e
	}
	if e := p.download(j); e != nil {
		return e
	}
	ipk := filepath.Join(p.stage(j), "candidate.ipk")
	if e := validatePanelIPK(ipk, j.Candidate); e != nil {
		return e
	}
	if e := p.checkSpace(j, runner.Size()); e != nil {
		return e
	}
	if e := p.integrity(); e != nil {
		return e
	}
	after, e := p.configDigest()
	if e != nil || after != before {
		return errors.New("PANEL_CONFIG_CHANGED")
	}
	// No wait on this external worker during daemon TERM; no request cancellation.
	j.Phase = "install"
	if e := p.writeJob(j); e != nil {
		return e
	}
	mutated = true
	if e := panelFixedCommand(opkg, "--tmp-dir", p.stage(j), "install", ipk); e != nil {
		return errors.New("PANEL_OPKG_FAILED")
	}
	version, sha, e := p.installed()
	if e != nil || version != j.Candidate.Version || sha != j.Candidate.SourceSHA {
		return errors.New("PANEL_IDENTITY_MISMATCH")
	}
	if e := p.integrity(); e != nil {
		return e
	}
	after, e = p.configDigest()
	if e != nil || after != before {
		return errors.New("PANEL_CONFIG_CHANGED")
	}
	j.Phase = "starting"
	if e := p.writeJob(j); e != nil {
		return e
	}
	if e := panelFixedCommand("/bin/sh", filepath.Join(p.root, "etc/init.d/S98kas-control-center"), "start"); e != nil {
		return errors.New("PANEL_START_FAILED")
	}
	for n := 0; n < 30; n++ {
		if p.receiptValid(j) {
			j.State = "OK"
			j.Phase = "complete"
			if e := p.writeJob(j); e != nil {
				return e
			}
			if e := os.Remove(filepath.Join(p.dir, "gate")); e != nil {
				return e
			}
			_ = syncPanelDir(p.dir)
			_ = os.RemoveAll(p.stage(j))
			return nil
		}
		time.Sleep(time.Second)
	}
	return errors.New("PANEL_RUNTIME_UNVERIFIED")
}

type panelRuntimeReceipt struct {
	ID        string `json:"id"`
	Version   string `json:"version"`
	SourceSHA string `json:"source_sha"`
	PID       int    `json:"pid"`
	Start     string `json:"start"`
}

func panelProcessStart(pid int) string {
	b, e := os.ReadFile(fmt.Sprintf("/proc/%d/stat", pid))
	if e != nil {
		return ""
	}
	i := strings.LastIndex(string(b), ") ")
	if i < 0 {
		return ""
	}
	fields := strings.Fields(string(b)[i+2:])
	if len(fields) < 20 {
		return ""
	}
	boot, e := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if e != nil || len(strings.TrimSpace(string(boot))) != 36 {
		return ""
	}
	return strings.TrimSpace(string(boot)) + ":" + fields[19]
}
func (p *panelUpdater) recordRuntime() error {
	if !p.gate() {
		return nil
	}
	j, e := p.readJob()
	if e != nil {
		return e
	}
	identity := compiledPanelIdentity()
	if j.Candidate.Version != identity.Version || j.Candidate.SourceSHA != identity.SourceSHA || j.State != "RUNNING" || j.Phase != "starting" {
		return nil
	}
	return p.writePrivate("runtime.json", panelRuntimeReceipt{j.ID, identity.Version, identity.SourceSHA, os.Getpid(), panelProcessStart(os.Getpid())})
}
func (p *panelUpdater) receiptValid(j panelJob) bool {
	b, e := inventoryFile(p.root, "etc/kas-control-center-update/runtime.json", 8192, true)
	if e != nil {
		return false
	}
	var receipt panelRuntimeReceipt
	if strictPanelJSON(b, &receipt) != nil || receipt.ID != j.ID || receipt.Version != j.Candidate.Version || receipt.SourceSHA != j.Candidate.SourceSHA || receipt.PID < 2 || receipt.Start == "" || panelProcessStart(receipt.PID) != receipt.Start {
		return false
	}
	running, e := os.Stat(fmt.Sprintf("/proc/%d/exe", receipt.PID))
	if e != nil {
		return false
	}
	installed, e := os.Stat(filepath.Join(p.root, "bin/kas-control-center"))
	return e == nil && os.SameFile(running, installed)
}
func (p *panelUpdater) recover() error {
	lock, e := p.workerLock()
	if e != nil {
		return e
	}
	defer lock.Close()
	j, e := p.readJob()
	if e != nil || !p.gate() {
		return errors.New("PANEL_RECOVERY_REQUIRED")
	}
	// An orphaned package process may still be mutating after its worker died.
	if processEvidence("/proc", []string{filepath.Join(p.root, "bin/opkg")}) != "stopped" {
		return errors.New("PANEL_OPKG_BUSY_OR_UNKNOWN")
	}
	if e := p.integrity(); e != nil {
		return e
	}
	version, sha, e := p.installed()
	if e != nil {
		return e
	}
	j.Candidate.Version = version
	j.Candidate.SourceSHA = sha
	j.Phase = "starting"
	j.State = "RUNNING"
	if e := p.writeJob(j); e != nil {
		return e
	}
	// Restart is explicit recovery only. Normal update uses start after opkg preinst.
	if e := panelFixedCommand("/bin/sh", filepath.Join(p.root, "etc/init.d/S98kas-control-center"), "restart"); e != nil {
		return errors.New("PANEL_START_FAILED")
	}
	for n := 0; n < 30; n++ {
		if p.receiptValid(j) {
			j.State = "FAIL"
			j.Phase = "recovered"
			j.ErrorCode = "PANEL_RECOVERED_CHECK_VERSION"
			if e := p.writeJob(j); e != nil {
				return e
			}
			if e := os.Remove(filepath.Join(p.dir, "gate")); e != nil {
				return e
			}
			_ = syncPanelDir(p.dir)
			_ = os.RemoveAll(p.stage(j))
			return nil
		}
		time.Sleep(time.Second)
	}
	return errors.New("PANEL_RUNTIME_UNVERIFIED")
}

func panelSafeOpen(root, relative string, max int64) (*os.File, error) {
	target := filepath.Join(root, relative)
	for dir := filepath.Dir(target); ; dir = filepath.Dir(dir) {
		st, e := os.Lstat(dir)
		if e != nil || !st.IsDir() || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) {
			return nil, errors.New("PANEL_FILE_UNSAFE")
		}
		if dir == root {
			break
		}
		if filepath.Dir(dir) == dir {
			return nil, errors.New("PANEL_FILE_UNSAFE")
		}
	}
	st, e := os.Lstat(target)
	if e != nil || !st.Mode().IsRegular() || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) || st.Size() > max {
		return nil, errors.New("PANEL_FILE_UNSAFE")
	}
	f, e := os.OpenFile(target, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if e != nil {
		return nil, e
	}
	opened, e := f.Stat()
	if e != nil || !os.SameFile(st, opened) {
		f.Close()
		return nil, errors.New("PANEL_FILE_UNSAFE")
	}
	return f, nil
}
