package main

import (
	"crypto/sha256"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const panelSettingsPath = "/opt/etc/kas-control-center.settings.json"

const legacyPortBackupSuffix = ".pre-beta7-8081.bak"

// The beta.4/5/6 settings format has no explicit default-port provenance.
// Only the exact legacy 8081 may migrate; all other saved ports stay fixed.
func legacyPanelPortEligible(c *panelConfig) bool {
	return c != nil && c.Version == 1 && c.Port == 8081 && !c.AutoPortFallback
}
func samePersistedPanelConfig(a, b *panelConfig) bool {
	return a != nil && b != nil && a.Version == b.Version && a.Port == b.Port &&
		a.AuthMode == b.AuthMode && a.PasswordHash == b.PasswordHash &&
		a.AutoPortFallback == b.AutoPortFallback
}

// Called only after successfully binding the candidate listener.
// The original private settings are backed up durably before atomic replacement.
// Existing mismatched backups or concurrent settings changes refuse startup.
func migrateLegacyPanelPort(path string, original *panelConfig, port int, fallback bool) error {
	if !legacyPanelPortEligible(original) || port < autoPanelStartPort || port > autoPanelLastPort ||
		fallback != (port != autoPanelStartPort) {
		return errors.New("unsafe legacy port migration")
	}
	current, err := readPanelConfig(path)
	if err != nil || !samePersistedPanelConfig(current, original) {
		return errors.New("legacy settings changed before migration")
	}
	backupPath := path + legacyPortBackupSuffix
	backup, err := readPanelConfig(backupPath)
	if err != nil {
		return errors.New("legacy settings backup unsafe")
	}
	if backup == nil {
		if err := saveInitialPanelConfig(backupPath, original); err != nil {
			return errors.New("legacy settings backup failed")
		}
	} else if !samePersistedPanelConfig(backup, original) {
		return errors.New("legacy settings backup differs")
	}
	current, err = readPanelConfig(path)
	if err != nil || !samePersistedPanelConfig(current, original) {
		return errors.New("legacy settings changed after backup")
	}
	next := &panelConfig{Version: original.Version, Port: port, AuthMode: original.AuthMode,
		PasswordHash: original.PasswordHash, AutoPortFallback: fallback}
	if err := savePanelConfig(path, next); err != nil {
		return errors.New("legacy settings migration failed")
	}
	return nil
}
func legacyPanelBackupMatches(path string, current *panelConfig) bool {
	if current == nil || current.Port < autoPanelStartPort || current.Port > autoPanelLastPort {
		return false
	}
	old, err := readPanelConfig(path + legacyPortBackupSuffix)
	return err == nil && legacyPanelPortEligible(old) &&
		old.AuthMode == current.AuthMode && old.PasswordHash == current.PasswordHash
}


type panelConfig struct {
	Version      int    `json:"version"`
	Port         int    `json:"port"`
	AuthMode     string `json:"auth_mode"`
	PasswordHash string `json:"password_hash,omitempty"`
	// Written only when first-launch auto fallback selected 8082..8090.
	// Absent in beta.4/5 settings; never infer provenance from port==8081.
	AutoPortFallback bool `json:"auto_port_fallback,omitempty"`
	verifyMu     sync.Mutex
	lastVerify   time.Time
	cached       [32]byte
	cachedOK     bool
}

func (c *panelConfig) login() string {
	if c.AuthMode == "entware" {
		return "root"
	}
	if c.AuthMode == "panel" || c.AuthMode == "legacy" {
		return "kas"
	}
	return ""
}
func (c *panelConfig) mode() string {
	if c.AuthMode == "legacy" {
		return "panel"
	}
	return c.AuthMode
}
func (c *panelConfig) valid() bool {
	if c.Version != 1 || c.Port < 1 || c.Port > 65535 {
		return false
	}
	if c.AutoPortFallback && (c.Port <= autoPanelStartPort || c.Port > autoPanelLastPort) {
		return false
	}
	switch c.AuthMode {
	case "none", "entware", "legacy":
		return c.PasswordHash == ""
	case "panel":
		return strings.HasPrefix(c.PasswordHash, panelPasswordPrefix+"$6$rounds=5000$") && validEntwareHash(strings.TrimPrefix(c.PasswordHash, panelPasswordPrefix))
	}
	return false
}
func privateFile(path string, max int64) ([]byte, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Mode().Perm()&0077 != 0 || st.Size() > max {
		return nil, errors.New("invalid private file")
	}
	return os.ReadFile(path)
}
func readPanelConfig(path string) (*panelConfig, error) {
	data, err := privateFile(path, 4096)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, errors.New("settings unavailable")
	}
	decoder := json.NewDecoder(strings.NewReader(string(data)))
	decoder.DisallowUnknownFields()
	var c panelConfig
	if decoder.Decode(&c) != nil || !c.valid() {
		return nil, errors.New("invalid panel settings")
	}
	var extra any
	if !errors.Is(decoder.Decode(&extra), io.EOF) {
		return nil, errors.New("invalid panel settings")
	}
	return &c, nil
}
func savePanelConfig(path string, c *panelConfig) error {
	if path == "" || !c.valid() {
		return errors.New("settings storage unavailable")
	}
	if _, err := readPanelConfig(path); err != nil {
		return err
	}
	// Refuse a redirected settings directory rather than write through it.
	if st, err := os.Lstat(filepath.Dir(path)); err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
		return errors.New("settings directory unavailable")
	}
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(filepath.Dir(path), ".kas-settings-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(data, '\n')); err != nil {
		f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	return os.Rename(f.Name(), path)
}
// Initial automatic port persistence is create-only: an administrator's
// settings must never be overwritten by an auto-port startup (including a
// concurrent write or a dangling symlink at the destination).
func saveInitialPanelConfig(path string, c *panelConfig) error {
	if path == "" || c == nil || !c.valid() {
		return errors.New("invalid initial panel settings")
	}
	if existing, err := readPanelConfig(path); err != nil {
		return err
	} else if existing != nil {
		return errors.New("panel settings already exist")
	}
	dir := filepath.Clean(filepath.Dir(path))
	// Reject symlinks in the entire directory chain, not just the leaf.
	for parent := dir; ; parent = filepath.Dir(parent) {
		st, err := os.Lstat(parent)
		if err != nil || !st.IsDir() || st.Mode()&os.ModeSymlink != 0 {
			return errors.New("unsafe panel settings directory")
		}
		if parent == dir && st.Mode().Perm()&0022 != 0 {
			return errors.New("writable panel settings directory")
		}
		if parent == filepath.Dir(parent) {
			break
		}
	}
	data, err := json.Marshal(c)
	if err != nil {
		return err
	}
	f, err := os.CreateTemp(dir, ".kas-settings-init-*")
	if err != nil {
		return err
	}
	defer os.Remove(f.Name())
	if _, err = f.Write(append(data, '\n')); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Sync(); err != nil {
		_ = f.Close()
		return err
	}
	if err = f.Close(); err != nil {
		return err
	}
	// A hard link provides O_EXCL-like create-only behavior, without a
	// replacement window. The temporary file is created 0600 in the same
	// directory/filesystem; any existing leaf makes this fail closed.
	if err = os.Link(f.Name(), path); err != nil {
		return err
	}
	d, err := os.Open(dir)
	if err != nil {
		return err
	}
	err = d.Sync()
	_ = d.Close()
	return err
}

func (a *app) currentHost() string {
	if host := a.liveHost.Load(); host != nil {
		return *host
	}
	return a.host
}

// Browsers omit the default HTTP port in Host/Origin even for a :80 URL.
func (a *app) directHost(host string) bool {
 current:=a.currentHost()
 if host==current{return true}
 listenIP,listenPort,err:=net.SplitHostPort(current)
 if err!=nil{return false}
 if a.lan==nil { return listenPort=="80" && host==listenIP }
 ip,port,err:=net.SplitHostPort(host)
 if err!=nil {
  if listenPort!="80"{return false}
  ip=host;port="80"
 }
 if port!=listenPort {return false}
 candidate:=net.ParseIP(ip)
 return candidate!=nil && candidate.To4()!=nil
}
func (a *app) currentPanel() *panelConfig {
	if a.lan == nil {
		return nil
	}
	if c := a.lan.panel.Load(); c != nil {
		return c
	}
	_, port, _ := net.SplitHostPort(a.host)
	n, _ := strconv.Atoi(port)
	mode := "none"
	if a.lan.passwordEnabled {
		mode = "legacy"
	}
	return &panelConfig{Version: 1, Port: n, AuthMode: mode}
}
func (p *homeLAN) credentialsValid(c *panelConfig, user, password string) bool {
	if c.AuthMode == "none" {
		return true
	}
	if user != c.login() || len(password) == 0 || len(password) > 128 {
		return false
	}
	if c.AuthMode == "legacy" {
		received := sha256.Sum256([]byte(password))
		return p.passwordEnabled && subtle.ConstantTimeCompare(received[:], p.passwordDigest[:]) == 1
	}
	hash := c.PasswordHash
	if c.AuthMode == "entware" {
		var err error
		hash, err = entwarePasswordHash(p.credentialRoot(), "root")
		if err != nil {
			return false
		}
	}
	// Include the current Entware hash so passwd immediately revokes cached checks.
	key := sha256.Sum256([]byte(user + "\x00" + password + "\x00" + hash))
	c.verifyMu.Lock()
	defer c.verifyMu.Unlock()
	if c.cachedOK && subtle.ConstantTimeCompare(c.cached[:], key[:]) == 1 {
		return true
	}
	// Bound uncached verification work; known successful credentials use the
	// constant-time cache above. State replacement and root hash changes revoke it.
	if !c.lastVerify.IsZero() && time.Since(c.lastVerify) < 200*time.Millisecond {
		return false
	}
	c.lastVerify = time.Now()
	ok := false
	if c.AuthMode == "panel" {
		ok = checkPanelPassword(password, hash)
	} else if c.AuthMode == "entware" {
		ok = checkEntwarePassword(p.credentialRoot(), user, password)
	}
	if ok {
		c.cached = key
		c.cachedOK = true
	}
	return ok
}
func (p *homeLAN) credentialRoot() string {
	if p.entwareRoot != "" {
		return p.entwareRoot
	}
	return "/opt"
}

type settingsResponse struct {
	Port             int    `json:"port"`
	AuthMode         string `json:"auth_mode"`
	Login            string `json:"login"`
	PasswordSet      bool   `json:"password_set"`
	URL              string `json:"url,omitempty"`
	AutoPortFallback bool   `json:"auto_port_fallback,omitempty"`
	LegacyPortMigrated bool `json:"legacy_port_migrated,omitempty"`
}

func panelResponse(c *panelConfig, url string) settingsResponse {
	return settingsResponse{
		Port: c.Port, AuthMode: c.mode(), Login: c.login(),
		PasswordSet: c.AuthMode != "none", URL: url,
		AutoPortFallback: c.AutoPortFallback,
	}
}
func (a *app) handleSettings(w http.ResponseWriter, r *http.Request) {
	if a.lan == nil {
		filterError(w, 404, "LAN_MODE_REQUIRED")
		return
	}
	if r.Method == http.MethodGet {
		// Only the actual direct IPv4 request Host can be advertised as an
		// HTTP link; never turn untrusted KeenDNS Host/forwarded headers
		// into a destination for the administrator.
		url := ""
		if a.directHost(r.Host) {
			url = "http://" + r.Host
			if !strings.HasSuffix(url, "/") {
				url += "/"
			}
		}
		response := panelResponse(a.currentPanel(), url)
		response.LegacyPortMigrated = legacyPanelBackupMatches(a.settingsPath, a.currentPanel())
		writeFilterJSON(w, 200, response)
		return
	}
	if r.Method != http.MethodPost {
		filterError(w, 405, "METHOD_NOT_ALLOWED")
		return
	}
	if !a.requestOriginAllowed(r) || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-KAS-Confirm") != "settings" {
		filterError(w, 403, "REQUEST_BLOCKED")
		return
	}
	if site := r.Header.Get("Sec-Fetch-Site"); site != "" && site != "same-origin" {
		filterError(w, 403, "REQUEST_BLOCKED")
		return
	}
	var req struct {
		Port            int    `json:"port"`
		AuthMode        string `json:"auth_mode"`
		Password        string `json:"password"`
		CurrentPassword string `json:"current_password"`
	}
	r.Body = http.MaxBytesReader(w, r.Body, 2048)
	decoder := json.NewDecoder(r.Body)
	decoder.DisallowUnknownFields()
	if decoder.Decode(&req) != nil {
		filterError(w, 400, "INVALID_SETTINGS")
		return
	}
	var extra any
	if !errors.Is(decoder.Decode(&extra), io.EOF) || req.Port < 1 || req.Port > 65535 || len(req.Password) > 128 || len(req.CurrentPassword) > 128 {
		filterError(w, 400, "INVALID_SETTINGS")
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.panelUpdateBusy() || a.importRunning || a.running || a.shuttingDown {
		filterError(w, 409, "BUSY")
		return
	}
	old := a.currentPanel()
	if old.AuthMode != "none" && !a.lan.credentialsValid(old, old.login(), req.CurrentPassword) {
		filterError(w, 403, "CURRENT_PASSWORD_REQUIRED")
		return
	}
	next := &panelConfig{Version: 1, Port: req.Port, AuthMode: req.AuthMode}
	switch req.AuthMode {
	case "none":
	case "entware":
		// Prove the target credentials before enabling the mode to avoid lockout.
		proof := req.Password
		if old.AuthMode == "entware" && proof == "" {
			proof = req.CurrentPassword
		}
		if !checkEntwarePassword(a.lan.credentialRoot(), "root", proof) {
			filterError(w, 400, "AUTH_CHECK_FAILED")
			return
		}
	case "panel":
		if req.Password == "" && (old.AuthMode == "panel" || old.AuthMode == "legacy") {
			next.AuthMode = old.AuthMode
			next.PasswordHash = old.PasswordHash
		} else {
			hash, err := newPanelPassword(req.Password)
			if err != nil {
				filterError(w, 400, "INVALID_SETTINGS")
				return
			}
			next.PasswordHash = hash
		}
	default:
		filterError(w, 400, "INVALID_SETTINGS")
		return
	}
	var reserved net.Listener
	host, _, err := net.SplitHostPort(a.currentHost())
	if err != nil {
		filterError(w, 503, "SETTINGS_SAVE_FAILED")
		return
	}
	address := net.JoinHostPort(host, strconv.Itoa(next.Port))
	if next.Port != old.Port {
		if a.listeners == nil {
			filterError(w, 503, "PORT_CHANGE_UNAVAILABLE")
			return
		}
		reserved, err = net.Listen("tcp", address)
		if err != nil {
			filterError(w, 409, "PORT_IN_USE")
			return
		}
		defer func() {
			if reserved != nil {
				reserved.Close()
			}
		}()
	}
	if err := savePanelConfig(a.settingsPath, next); err != nil {
		filterError(w, 503, "SETTINGS_SAVE_FAILED")
		return
	}
	a.lan.panel.Store(next)
	if reserved != nil {
		a.listeners.replace(reserved)
		reserved = nil
	}
	// Return a usable URL after a port change, not the wildcard listen IP.
	displayAddress:=address
	if a.directHost(r.Host) {
		if clientIP,_,err:=net.SplitHostPort(r.Host);err==nil && net.ParseIP(clientIP)!=nil{
			displayAddress=net.JoinHostPort(clientIP,strconv.Itoa(next.Port))
		}
	}
	writeFilterJSON(w, 200, panelResponse(next, "http://"+displayAddress))
}
