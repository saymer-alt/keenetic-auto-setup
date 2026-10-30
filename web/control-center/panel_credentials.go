package main

import (
	"crypto/rand"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	md5crypt "github.com/GehirnInc/crypt/md5_crypt"
	sha256crypt "github.com/GehirnInc/crypt/sha256_crypt"
	sha512crypt "github.com/GehirnInc/crypt/sha512_crypt"
)

const (
	panelPasswordMinBytes      = 12
	credentialMaxPasswordBytes = 128
	credentialMaxFileBytes     = 64 * 1024
	// Fixed, memory-light SHA512crypt cost for low-memory Entware routers.
	// This intentionally trades offline resistance for router compatibility;
	// callers must also bound concurrent authentication and login attempts.
	panelPasswordRounds   = 5000
	entwareMaxCryptRounds = 100000
	panelPasswordPrefix   = "$kas-panel$1"
	cryptAlphabet         = "./0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
)

var errCredentialUnavailable = errors.New("credentials unavailable")
var errPanelPasswordInvalid = errors.New("panel password must contain 12 to 128 bytes")

// newPanelPassword creates an independently salted, versioned password hash.
// Entware credentials are never changed or persisted by these helpers.
func newPanelPassword(password string) (string, error) {
	if len(password) < panelPasswordMinBytes || len(password) > credentialMaxPasswordBytes {
		return "", errPanelPasswordInvalid
	}
	salt := make([]byte, 16)
	if _, err := rand.Read(salt); err != nil {
		return "", errCredentialUnavailable
	}
	for i := range salt {
		salt[i] = cryptAlphabet[int(salt[i])&63]
	}
	hash, err := sha512crypt.New().Generate([]byte(password), []byte("$6$rounds=5000$"+string(salt)+"$"))
	if err != nil {
		return "", errCredentialUnavailable
	}
	return panelPasswordPrefix + hash, nil
}

func checkPanelPassword(password, hash string) bool {
	if len(password) < panelPasswordMinBytes || len(password) > credentialMaxPasswordBytes || len(hash) > 160 || !strings.HasPrefix(hash, panelPasswordPrefix+"$6$rounds=5000$") {
		return false
	}
	hash = strings.TrimPrefix(hash, panelPasswordPrefix)
	return validEntwareHash(hash) && sha512crypt.New().Verify(hash, []byte(password)) == nil
}

// entwarePasswordHash reads current root credentials on every call. Shadow is
// authoritative whenever present: locked, unreadable or malformed shadow never
// falls back to a possibly stale passwd hash. Only absent shadow uses passwd.
// root is the Entware installation root (/opt in production), not a client path.
func entwarePasswordHash(root, login string) (string, error) {
	if login != "root" {
		return "", errCredentialUnavailable
	}
	data, err := readCredentialFile(filepath.Join(root, "etc", "shadow"))
	passwd := false
	if errors.Is(err, os.ErrNotExist) {
		data, err = readCredentialFile(filepath.Join(root, "etc", "passwd"))
		passwd = true
	}
	if err != nil {
		return "", errCredentialUnavailable
	}
	found := ""
	count := 0
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Split(line, ":")
		if fields[0] != "root" {
			continue
		}
		count++
		if len(fields) < 2 {
			return "", errCredentialUnavailable
		}
		if passwd && (len(fields) != 7 || fields[2] != "0") {
			return "", errCredentialUnavailable
		}
		if !passwd && len(fields) != 9 {
			return "", errCredentialUnavailable
		}
		found = fields[1]
	}
	if count != 1 || !validEntwareHash(found) {
		return "", errCredentialUnavailable
	}
	return found, nil
}

func readCredentialFile(path string) ([]byte, error) {
	st, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() > credentialMaxFileBytes {
		return nil, errCredentialUnavailable
	}
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err = f.Stat()
	if err != nil || !st.Mode().IsRegular() {
		return nil, errCredentialUnavailable
	}
	data, err := io.ReadAll(io.LimitReader(f, credentialMaxFileBytes+1))
	if err != nil || len(data) > credentialMaxFileBytes {
		return nil, errCredentialUnavailable
	}
	return data, nil
}

// Validate syntax and cost before invoking a KDF. No generic crypt dispatch:
// unsupported/locked hashes fail closed, and hostile rounds cannot consume an
// unbounded amount of CPU. Legacy MD5 is verification-only for Entware.
func validEntwareHash(hash string) bool {
	if len(hash) > 128 {
		return false
	}
	parts := strings.Split(hash, "$")
	if len(parts) < 4 || parts[0] != "" {
		return false
	}
	id := parts[1]
	saltIndex := 2
	saltMax, sumLen := 16, 0
	switch id {
	case "1":
		saltMax, sumLen = 8, 22
	case "5":
		sumLen = 43
	case "6":
		sumLen = 86
	default:
		return false
	}
	if id != "1" && strings.HasPrefix(parts[2], "rounds=") {
		text := strings.TrimPrefix(parts[2], "rounds=")
		rounds, err := strconv.ParseUint(text, 10, 32)
		if err != nil || rounds < 1000 || rounds > entwareMaxCryptRounds || strconv.FormatUint(rounds, 10) != text {
			return false
		}
		saltIndex = 3
	}
	if len(parts) != saltIndex+2 {
		return false
	}
	salt, sum := parts[saltIndex], parts[saltIndex+1]
	if len(salt) < 1 || len(salt) > saltMax || len(sum) != sumLen {
		return false
	}
	for _, s := range []string{salt, sum} {
		for i := 0; i < len(s); i++ {
			if !strings.ContainsRune(cryptAlphabet, rune(s[i])) {
				return false
			}
		}
	}
	return true
}

func checkEntwarePassword(root, login, password string) bool {
	if len(password) == 0 || len(password) > credentialMaxPasswordBytes {
		return false
	}
	hash, err := entwarePasswordHash(root, login)
	if err != nil {
		return false
	}
	switch hash[1] {
	case '1':
		return md5crypt.New().Verify(hash, []byte(password)) == nil
	case '5':
		return sha256crypt.New().Verify(hash, []byte(password)) == nil
	case '6':
		return sha512crypt.New().Verify(hash, []byte(password)) == nil
	}
	return false
}
