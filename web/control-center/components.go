package main

// Read-only build/package identity. No commands, network requests or config reads.
import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
)

var panelBuildVersion = "development"
var panelBuildSHA = ""
var componentVersionPattern = regexp.MustCompile(`^[0-9][A-Za-z0-9.+~-]{0,63}$`)
var componentSourcePattern = regexp.MustCompile(`^[a-f0-9]{40}$`)
var componentDigestPattern = regexp.MustCompile(`^[a-f0-9]{64}$`)

type buildIdentity struct {
	Version   string `json:"version"`
	SourceSHA string `json:"source_sha"`
}
type coreIdentity struct {
	State     string `json:"state"`
	Version   string `json:"version,omitempty"`
	SourceSHA string `json:"source_sha,omitempty"`
}
type watchdogIdentity struct {
	State           string `json:"state"`
	InstalledSHA    string `json:"installed_sha256,omitempty"`
	RecordedVersion string `json:"recorded_version,omitempty"`
}
type componentsResponse struct {
	Panel    buildIdentity    `json:"panel"`
	Core     coreIdentity     `json:"core"`
	Watchdog watchdogIdentity `json:"watchdog"`
}
type coreManifest struct {
	Schema    int    `json:"schema"`
	Version   string `json:"version"`
	SourceSHA string `json:"source_sha"`
	Scripts   []struct {
		Name string `json:"name"`
		SHA  string `json:"sha256"`
	} `json:"scripts"`
}
type watchdogReceipt struct {
	Schema    int    `json:"schema"`
	Component string `json:"component"`
	Version   string `json:"bundle_version"`
	SourceSHA string `json:"source_sha"`
	SHA       string `json:"watchdog_sha256"`
}

func compiledPanelIdentity() buildIdentity {
	version, source := panelBuildVersion, panelBuildSHA
	if version != "development" && !componentVersionPattern.MatchString(version) {
		version = "development"
	}
	if !componentSourcePattern.MatchString(source) {
		source = ""
	}
	return buildIdentity{version, source}
}
func inventoryFile(root, relative string, max int64, private bool) ([]byte, error) {
	path := filepath.Join(root, relative)
	// Refuse redirected parent directories as well as the final symlink.
	for directory := filepath.Dir(path); ; directory = filepath.Dir(directory) {
		st, err := os.Lstat(directory)
		if err != nil {
			return nil, err
		}
		if !st.IsDir() || st.Mode()&os.ModeSymlink != 0 || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) {
			return nil, errors.New("unsafe inventory directory")
		}
		if directory == filepath.Clean(root) {
			break
		}
		if directory == filepath.Dir(directory) {
			return nil, errors.New("inventory path outside root")
		}
	}
	st, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > max || st.Mode().Perm()&0022 != 0 || !inventoryOwned(st) {
		return nil, errors.New("unsafe inventory file")
	}
	if private && st.Mode().Perm() != 0600 {
		return nil, errors.New("receipt must be private")
	}
	if private {
		directory, err := os.Lstat(filepath.Dir(path))
		if err != nil || directory.Mode().Perm() != 0700 {
			return nil, errors.New("receipt directory must be private")
		}
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	current, err := f.Stat()
	if err != nil || !current.Mode().IsRegular() || !os.SameFile(st, current) {
		return nil, errors.New("inventory file changed")
	}
	data, err := io.ReadAll(io.LimitReader(f, max+1))
	if err != nil || int64(len(data)) > max {
		return nil, errors.New("inventory unavailable")
	}
	return data, nil
}
func inventoryDigest(root, relative string) string {
	data, err := inventoryFile(root, relative, 262144, false)
	if err != nil {
		return ""
	}
	digest := sha256.Sum256(data)
	return hex.EncodeToString(digest[:])
}
func componentInventory(root string) componentsResponse {
	result := componentsResponse{Panel: compiledPanelIdentity(), Core: coreIdentity{State: "absent"}, Watchdog: watchdogIdentity{State: "unrecorded"}}
	result.Watchdog.InstalledSHA = inventoryDigest(root, "bin/mihomo_watchdog.sh")
	data, err := inventoryFile(root, "share/kas-core/scripts.json", 65536, false)
	candidate := ""
	if err != nil {
		if !os.IsNotExist(err) {
			result.Core.State = "unavailable"
		}
	} else {
		var manifest coreManifest
		if json.Unmarshal(data, &manifest) != nil || manifest.Schema != 1 || !componentVersionPattern.MatchString(manifest.Version) || !componentSourcePattern.MatchString(manifest.SourceSHA) {
			result.Core.State = "unavailable"
		} else {
			result.Core = coreIdentity{State: "present", Version: manifest.Version, SourceSHA: manifest.SourceSHA}
			count := 0
			for _, script := range manifest.Scripts {
				if script.Name == "mihomo-watchdog.sh" {
					candidate = script.SHA
					count++
				}
			}
			if count != 1 || !componentDigestPattern.MatchString(candidate) {
				result.Core.State = "unavailable"
				candidate = ""
			} else if actual := inventoryDigest(root, "libexec/kas/mihomo-watchdog.sh"); actual == "" {
				result.Core.State = "unavailable"
			} else if actual != candidate {
				result.Core.State = "modified"
			}
		}
	}
	data, err = inventoryFile(root, "etc/kas-core/watchdog.json", 4096, true)
	if os.IsNotExist(err) {
		return result
	}
	var receipt watchdogReceipt
	if err != nil || json.Unmarshal(data, &receipt) != nil || receipt.Schema != 1 || receipt.Component != "watchdog" || !componentVersionPattern.MatchString(receipt.Version) || !componentSourcePattern.MatchString(receipt.SourceSHA) || !componentDigestPattern.MatchString(receipt.SHA) {
		result.Watchdog.State = "invalid_receipt"
		return result
	}
	result.Watchdog.RecordedVersion = receipt.Version
	switch {
	case result.Watchdog.InstalledSHA != receipt.SHA:
		result.Watchdog.State = "stale"
	case result.Core.State != "present":
		result.Watchdog.State = "unverified"
	case receipt.Version != result.Core.Version || receipt.SourceSHA != result.Core.SourceSHA:
		result.Watchdog.State = "bundle_changed"
	case receipt.SHA != candidate:
		result.Watchdog.State = "stale"
	default:
		result.Watchdog.State = "current"
	}
	return result
}
func (a *app) handleComponents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		filterError(w, http.StatusMethodNotAllowed, "METHOD_NOT_ALLOWED")
		return
	}
	writeFilterJSON(w, http.StatusOK, componentInventory("/opt"))
}
