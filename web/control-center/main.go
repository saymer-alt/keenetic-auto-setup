// KAS Control Center: optional, loopback-only staged Status/Doctor/YAML prototype.
package main

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

//go:generate sh -c "mkdir -p scripts && cp ../../mihomo-doctor.sh scripts/mihomo-doctor.sh && cp ../../config-import.sh scripts/config-import.sh && cp ../../update-mihomo.sh scripts/update-mihomo.sh"
//go:embed web/* scripts/mihomo-doctor.sh scripts/config-import.sh scripts/update-mihomo.sh
var assets embed.FS

type apiResult struct {
	Runtime      *runtimeObservation `json:"runtime,omitempty"`
	Summary      *doctorSummary      `json:"summary,omitempty"`
	State        string              `json:"state"`
	Time         string              `json:"timestamp"`
	Source       string              `json:"source"`
	ExitCode     *int                `json:"exit_code,omitempty"`
	Details      string              `json:"details,omitempty"`
	ErrorCode    string              `json:"error_code,omitempty"`
	MihomoBinary bool                `json:"mihomo_binary,omitempty"`
	MTBinary     bool                `json:"magitrickle_binary,omitempty"`
}
type app struct {
	panelUpdate        *panelUpdater
	host               string
	liveHost           atomic.Pointer[string]
	settingsPath       string
	listeners          *panelListeners
	proxyHost          string
	proxyOrigin        string
	lan                *homeLAN
	doctor             []byte
	updater            []byte
	runUpdate          func([]byte) (int, error)
	updateDigest       func() string
	checkUpdates       func(context.Context) (updateCheck, error)
	lastUpdateCheck    updateCheck
	updateChecking     bool
	updateResult       updateOperation
	mt                 *mtMaintenance
	lastMTCheck        mtUpdateCheck
	importer           []byte
	mu                 sync.Mutex
	running            bool
	importRunning      bool
	shuttingDown       bool
	importResult       importStatus
	last               time.Time
	runDoctor          func(context.Context, []byte) (string, int, error)
	runImport          func([]byte, string, []string) (int, error)
	filterConfigReader func() ([]byte, error)
	providers          *providerNamesExporter
}

func newApp(host string, doctor []byte) *app {
	a := &app{panelUpdate: newPanelUpdater("/opt"), host: host, doctor: doctor, mt: newMTMaintenance(), runDoctor: doctorCommand, runImport: importCommand, runUpdate: updateCommand, updateDigest: func() string { return mihomoBinaryDigest("/opt") }}
	a.checkUpdates = a.fetchUpdateCheck
	return a
}
func validateBind(address string) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	ip := net.ParseIP(host)
	if ip == nil || !ip.IsLoopback() {
		return errors.New("stage 1 permits only literal loopback IPs")
	}
	if port == "" || port == "0" {
		return errors.New("choose an explicit nonzero port")
	}
	return nil
}
func (a *app) expectedOrigin(host string) string {
	if a.directHost(host) {
		return "http://" + strings.TrimSuffix(host, ":80")
	}
	if host == a.proxyHost && a.proxyOrigin != "" {
		return a.proxyOrigin
	}
	return ""
}
func now() string                 { return time.Now().UTC().Format(time.RFC3339) }
func fileExists(path string) bool { st, err := os.Stat(path); return err == nil && !st.IsDir() }

// Filesystem evidence only; these paths do not prove a running service.
func componentFiles(root string) (bool, bool) {
	mihomo := fileExists(filepath.Join(root, "bin", "mihomo")) || fileExists(filepath.Join(root, "sbin", "mihomo"))
	mt := fileExists(filepath.Join(root, "bin", "magitrickled")) || fileExists(filepath.Join(root, "bin", "magitrickle"))
	return mihomo, mt
}
func (a *app) handleStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	mihomo, mt := componentFiles("/opt")
	runtime := a.runtimeStatus(r.Context())
	writeJSON(w, http.StatusOK, apiResult{
		State: "UNKNOWN", Time: now(), Source: "KAS executable/process evidence and local version API; network health not tested",
		MihomoBinary: mihomo, MTBinary: mt, Runtime: &runtime,
	})
}
func (a *app) handleDoctor(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	origin := r.Header.Get("Origin")
	if origin != a.expectedOrigin(r.Host) || r.Header.Get("Content-Type") != "application/json" {
		writeJSON(w, http.StatusForbidden, apiResult{State: "UNKNOWN", Time: now(), ErrorCode: "REQUEST_BLOCKED"})
		return
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		writeJSON(w, http.StatusForbidden, apiResult{State: "UNKNOWN", Time: now(), ErrorCode: "REQUEST_BLOCKED"})
		return
	}
	r.Body = http.MaxBytesReader(w, r.Body, 32)
	var body map[string]any
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil || len(body) != 0 {
		writeJSON(w, http.StatusBadRequest, apiResult{State: "UNKNOWN", Time: now(), ErrorCode: "INVALID_BODY"})
		return
	}
	a.mu.Lock()
	if a.panelUpdateBusy() || a.running || a.importRunning || a.shuttingDown || time.Since(a.last) < 5*time.Second {
		a.mu.Unlock()
		writeJSON(w, http.StatusTooManyRequests, apiResult{State: "UNKNOWN", Time: now(), ErrorCode: "BUSY"})
		return
	}
	a.running = true
	a.last = time.Now()
	a.mu.Unlock()
	defer func() { a.mu.Lock(); a.running = false; a.mu.Unlock() }()
	if len(a.doctor) == 0 {
		writeJSON(w, http.StatusServiceUnavailable, apiResult{State: "UNKNOWN", Time: now(), ErrorCode: "DOCTOR_UNAVAILABLE"})
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 90*time.Second)
	defer cancel()
	output, exit, err := a.runDoctor(ctx, a.doctor)
	result := apiResult{State: "UNKNOWN", Time: now(), Source: "bundled mihomo-doctor.sh", ExitCode: &exit, Details: redact(output)}
	var commandExit *exec.ExitError
	if ctx.Err() == nil && (err == nil || errors.As(err, &commandExit) && commandExit.ExitCode() == exit) {
		result.Summary = parseDoctorSummary(output, exit)
	}
	if err != nil && result.Summary == nil {
		result.ErrorCode = "DOCTOR_FAILED"
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			result.ErrorCode = "TIMEOUT"
		}
		writeJSON(w, http.StatusOK, result)
		return
	}
	// Exit code 0 proves only script completion, not full client route health.
	// A parsed footer describes Doctor findings, not full client route health.
	result.State = "UNKNOWN"
	writeJSON(w, http.StatusOK, result)
}

var secretLine = regexp.MustCompile(`(?i)(password|passwd|secret|token|authorization|api.key|private.key|subscription|://[^\s/]+:[^\s/@]+@)`)

func redact(s string) string {
	lines := strings.Split(s, "\n")
	for i, line := range lines {
		if secretLine.MatchString(line) {
			lines[i] = "[REDACTED]"
		}
	}
	return strings.Join(lines, "\n")
}

type capWriter struct {
	data  []byte
	limit int
}

func (c *capWriter) Write(p []byte) (int, error) {
	if len(c.data) < c.limit {
		n := c.limit - len(c.data)
		if n > len(p) {
			n = len(p)
		}
		c.data = append(c.data, p[:n]...)
	}
	return len(p), nil
}
func doctorCommand(ctx context.Context, script []byte) (string, int, error) {
	cmd := exec.CommandContext(ctx, "sh", "-s")
	cmd.Stdin = strings.NewReader(string(script))
	cmd.WaitDelay = 2 * time.Second
	w := &capWriter{limit: 128 * 1024}
	cmd.Stdout = w
	cmd.Stderr = w
	err := cmd.Run()
	exit := 0
	if err != nil {
		exit = -1
		var e *exec.ExitError
		if errors.As(err, &e) {
			exit = e.ExitCode()
		}
	}
	out := string(w.data)
	if len(w.data) == w.limit {
		out += "\n[OUTPUT TRUNCATED]"
	}
	return out, exit, err
}
func writeJSON(w http.ResponseWriter, code int, v apiResult) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(v)
}

// noCacheStatic forces every browser request for the embedded panel UI to
// revalidate. Asset file names never change between releases (single binary,
// embedded FS), so any stored copy can be stale right after a self-update;
// without an explicit directive Chromium served pre-upgrade HTML/JS until a
// forced reload (issue #311). The files are small and served on LAN, so an
// unconditional revalidation costs nothing. CSP and other headers unchanged.
func noCacheStatic(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		next.ServeHTTP(w, r)
	})
}
func (a *app) handler() http.Handler {
	sub, err := fs.Sub(assets, "web")
	if err != nil {
		panic(err)
	}
	mux := http.NewServeMux()
	mux.Handle("/", noCacheStatic(http.FileServer(http.FS(sub))))
	mux.HandleFunc("/api/status", a.handleStatus)
	mux.HandleFunc("/api/components", a.handleComponents)
	mux.HandleFunc("/api/updates/check", a.handleUpdateCheck)
	mux.HandleFunc("/api/updates/panel/check", a.handlePanelCheck)
	mux.HandleFunc("/api/updates/panel/apply", a.handlePanelApply)
	mux.HandleFunc("/api/updates/panel/operation", a.handlePanelOperation)
	mux.HandleFunc("/api/updates/panel/channel", a.handlePanelChannel)
	mux.HandleFunc("/api/updates/mihomo", a.handleMihomoUpdate)
	mux.HandleFunc("/api/updates/operation", a.handleUpdateOperation)
	mux.HandleFunc("/api/updates/magitrickle/check", a.handleMTCheck)
	mux.HandleFunc("/api/updates/magitrickle", a.handleMTUpdate)
	mux.HandleFunc("/api/access", a.handleAccess)
	mux.HandleFunc("/api/settings", a.handleSettings)
	mux.HandleFunc("/api/doctor", a.handleDoctor)
	mux.HandleFunc("/api/config/import", a.handleImport)
	mux.HandleFunc("/api/config/operation", a.handleImportStatus)
	mux.HandleFunc("/api/providers/names", a.handleProviderNames)
	mux.HandleFunc("/api/filter/providers", a.handleFilterInspect)
	mux.HandleFunc("/api/filter/preview", a.handleFilterPreview)
	mux.HandleFunc("/api/filter/apply", a.handleFilterApply)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !a.directHost(r.Host) && (a.proxyHost == "" || r.Host != a.proxyHost) {
			http.Error(w, "invalid host", http.StatusForbidden)
			return
		}
		if a.lan != nil && !a.lan.allowed(w, r, a.proxyHost) {
			return
		}
		w.Header().Set("X-Frame-Options", "DENY")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
		if r.Method != http.MethodGet && r.Method != http.MethodHead && a.panelUpdate.gate() {
			updateJSON(w, 409, updateOperation{State: "UNKNOWN", ErrorCode: "PANEL_UPDATE_BUSY"})
			return
		}
		mux.ServeHTTP(w, r)
	})
}
func main() {
	workerOnly := flag.Bool("panel-update-worker", false, "internal fixed panel updater job")
	recoverUpdate := flag.Bool("recover-panel-update", false, "explicit recovery of interrupted panel update")
	versionOnly := flag.Bool("version", false, "print compiled panel version and source, then exit")
	listen := flag.String("listen", "", "IP:port; default loopback without -lan, Home br0 with -lan")
	lanMode := flag.Bool("lan", false, "listen on private Home br0 IPv4, HTTP, no password by default")
	lanInterface := flag.String("lan-interface", "br0", "Home LAN bridge (currently br0 only)")
	passwordFile := flag.String("password-file", "", "optional private file with KAS panel password")
	proxyOrigin := flag.String("proxy-origin", "", "optional existing KeenDNS HTTPS URL allowed via router reverse proxy")
	providerExport := flag.Bool("provider-names-export", false, "enable explicit read-only local Mihomo names export")
	providerSecretFile := flag.String("provider-secret-file", "", "optional 0600 file with local Mihomo API secret; requires export")
	settingsFile := flag.String("settings-file", panelSettingsPath, "private persistent panel settings")
	initialPort := flag.Int("initial-port", 8081, "default port when no settings exist")
	flag.Parse()
	if *workerOnly || *recoverUpdate {
		p := newPanelUpdater("/opt")
		var err error
		if *workerOnly {
			err = p.runWorker()
		} else {
			err = p.recover()
		}
		if err != nil {
			log.Fatal(panelErrorCode(err))
		}
		return
	}
	if *versionOnly {
		identity := compiledPanelIdentity()
		fmt.Printf("KAS Control Center %s", identity.Version)
		if identity.SourceSHA != "" {
			fmt.Printf(" (%s)", identity.SourceSHA)
		}
		fmt.Println()
		return
	}
	if *initialPort < 1 || *initialPort > 65535 {
		log.Fatal("invalid initial port")
	}
	var config *panelConfig
	if *lanMode {
		var err error
		config, err = readPanelConfig(*settingsFile)
		if err != nil {
			log.Fatal(err)
		}
	}
	var lan *homeLAN
	if *lanMode {
		var err error
		lan, err = newHomeLAN(*listen, *lanInterface, *passwordFile)
		if err != nil {
			log.Fatal(err)
		}
		if err := lan.loadAccessPolicy(homeOnlyConfigPath); err != nil {
			log.Fatal(err)
		}
		host, _, _ := net.SplitHostPort(lan.address)
		if *listen == "" || *listen == "auto" {
			port := *initialPort
			if config != nil {
				port = config.Port
			}
			lan.address = net.JoinHostPort(host, fmt.Sprint(port))
		} else if config != nil {
			_, port, _ := net.SplitHostPort(lan.address)
			if port != fmt.Sprint(config.Port) {
				log.Fatal("explicit listener conflicts with saved port")
			}
		}
		*listen = lan.address
		if config == nil {
			_, port, _ := net.SplitHostPort(*listen)
			n := 0
			fmt.Sscan(port, &n)
			mode := "none"
			if lan.passwordEnabled {
				mode = "legacy"
			}
			config = &panelConfig{Version: 1, Port: n, AuthMode: mode}
		}
		if config.AuthMode == "legacy" && !lan.passwordEnabled {
			log.Fatal("legacy password file required")
		}
		lan.panel.Store(config)
	} else {
		if *passwordFile != "" || *proxyOrigin != "" {
			log.Fatal("password-file and proxy-origin require -lan")
		}
		if *listen == "" {
			*listen = fmt.Sprintf("127.0.0.1:%d", *initialPort)
		}
		if err := validateBind(*listen); err != nil {
			log.Fatal(err)
		}
	}
	script, err := assets.ReadFile("scripts/mihomo-doctor.sh")
	if err != nil {
		log.Fatal(err)
	}
	importer, err := assets.ReadFile("scripts/config-import.sh")
	if err != nil {
		log.Fatal(err)
	}
	app := newApp(*listen, script)
	app.importer = importer
	updater, err := assets.ReadFile("scripts/update-mihomo.sh")
	if err != nil {
		log.Fatal(err)
	}
	app.updater = updater
	app.lan = lan
	app.settingsPath = *settingsFile
	if *providerSecretFile != "" && !*providerExport {
		log.Fatal("provider secret file requires provider names export")
	}
	if *providerExport {
		exporter, err := newProviderNamesExporter(*listen, *providerSecretFile)
		if err != nil {
			log.Fatal(err)
		}
		app.providers = exporter
	}
	if *proxyOrigin != "" {
		host, err := validateProxyOrigin(*proxyOrigin)
		if err != nil {
			log.Fatal(err)
		}
		app.proxyOrigin = *proxyOrigin
		app.proxyHost = host
	}
	listener, err := net.Listen("tcp", *listen)
	if err != nil {
		log.Fatalf("PORT_BIND_FAILED: panel address %s is unavailable; choose another panel port (other services unchanged)", *listen)
	}
	app.listeners = newPanelListeners(app)
	app.listeners.replace(listener)
	if err := app.panelUpdate.recordRuntime(); err != nil {
		log.Printf("PANEL_RECEIPT_FAILED")
	}
	if lan != nil {
		fmt.Println(lan.describe())
	} else {
		fmt.Printf("KAS staged prototype (loopback only): http://%s\n", *listen)
	}
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	select {
	case err := <-app.listeners.errors:
		if err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Fatal(err)
		}
		return
	case <-signals:
	}
	// Never interrupt canonical importer/updater halfway through its atomic
	// replace/rollback. Stop accepting NEW mutating requests and drain workers.
	app.mu.Lock()
	app.shuttingDown = true
	app.mu.Unlock()
	for {
		app.mu.Lock()
		busy := app.importRunning || app.running
		app.mu.Unlock()
		if !busy {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := app.listeners.shutdown(ctx); err != nil {
		log.Printf("shutdown error: %v", err)
	}

}
