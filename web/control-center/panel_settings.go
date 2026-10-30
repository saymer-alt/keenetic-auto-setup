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

type panelConfig struct {
	Version      int    `json:"version"`
	Port         int    `json:"port"`
	AuthMode     string `json:"auth_mode"`
	PasswordHash string `json:"password_hash,omitempty"`
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
func (a *app) currentHost() string {
	if host := a.liveHost.Load(); host != nil {
		return *host
	}
	return a.host
}

// Browsers omit the default HTTP port in Host/Origin even for a :80 URL.
func (a *app) directHost(host string) bool {
	current := a.currentHost()
	if host == current {
		return true
	}
	ip, port, err := net.SplitHostPort(current)
	return err == nil && port == "80" && host == ip
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
	Port        int    `json:"port"`
	AuthMode    string `json:"auth_mode"`
	Login       string `json:"login"`
	PasswordSet bool   `json:"password_set"`
	URL         string `json:"url,omitempty"`
}

func panelResponse(c *panelConfig, url string) settingsResponse {
	return settingsResponse{c.Port, c.mode(), c.login(), c.AuthMode != "none", url}
}
func (a *app) handleSettings(w http.ResponseWriter, r *http.Request) {
	if a.lan == nil {
		filterError(w, 404, "LAN_MODE_REQUIRED")
		return
	}
	if r.Method == http.MethodGet {
		writeFilterJSON(w, 200, panelResponse(a.currentPanel(), ""))
		return
	}
	if r.Method != http.MethodPost {
		filterError(w, 405, "METHOD_NOT_ALLOWED")
		return
	}
	if r.Header.Get("Origin") != a.expectedOrigin(r.Host) || r.Header.Get("Content-Type") != "application/json" || r.Header.Get("X-KAS-Confirm") != "settings" {
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
	writeFilterJSON(w, 200, panelResponse(next, "http://"+address))
}
