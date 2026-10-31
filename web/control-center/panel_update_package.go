package main

// Strict, bounded preflight. No archive member is extracted or executed.
import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

const panelMaxIPK int64 = 16 << 20
const panelMaxPayload int64 = 32 << 20

var panelPackageError = errors.New("PANEL_PACKAGE_INVALID")
var panelAssetNamePattern = regexp.MustCompile(`^[A-Za-z0-9_.+~-]{1,240}$`)
var panelTagPattern = regexp.MustCompile(`^kas-web-ipk-[a-f0-9]{7,40}$`)
var panelBetaTagPattern = regexp.MustCompile(`^(?:kas-web-)?v[0-9]+\.[0-9]+\.[0-9]+-beta\.[0-9]+$`)
var panelStableTagPattern = regexp.MustCompile(`^kas-web-v[0-9]+\.[0-9]+\.[0-9]+$`)

type panelCandidate struct {
	Version      string `json:"version"`
	SourceSHA    string `json:"source_sha"`
	Architecture string `json:"architecture"`
	Name         string `json:"name"`
	Size         int64  `json:"size"`
	SHA256       string `json:"sha256"`
	UnpackedSize int64  `json:"unpacked_size"`
	BinarySHA256 string `json:"binary_sha256"`
	Tag          string `json:"release_tag,omitempty"`
	Channel      string `json:"channel,omitempty"`
}
type panelIndex struct {
	Schema   int              `json:"schema"`
	Channel  string           `json:"channel"`
	Tag      string           `json:"tag"`
	Packages []panelCandidate `json:"packages"`
}

func panelArchValid(s string) bool {
	return s == "mipsel-3.4" || s == "mips-3.4" || s == "armv7-3.2" || s == "aarch64-3.10"
}
func panelChannelKnown(channel string) bool {
	return channel == "experimental" || channel == "stable"
}

// panelTagValid is the release-tag allowlist per channel index. experimental
// serves published beta prereleases: the legacy kas-web-ipk-<sha> alias that
// installed beta.1 panels still consume, plus the canonical v0.1.0-beta.N
// release used without a duplicate alias once no beta.1 panel needs it.
// stable keeps its dedicated kas-web-vX.Y.Z namespace; the two never mix.
func panelTagValid(channel, tag string) bool {
	switch channel {
	case "experimental":
		return panelTagPattern.MatchString(tag) || panelBetaTagPattern.MatchString(tag)
	case "stable":
		return panelStableTagPattern.MatchString(tag)
	}
	return false
}
func (c panelCandidate) valid() bool {
	return componentVersionPattern.MatchString(c.Version) && componentSourcePattern.MatchString(c.SourceSHA) && panelArchValid(c.Architecture) && panelAssetNamePattern.MatchString(c.Name) && strings.HasPrefix(c.Name, "kas-control-center_") && strings.HasSuffix(c.Name, "_"+c.Architecture+".ipk") && c.Size > 0 && c.Size <= panelMaxIPK && c.UnpackedSize > 0 && c.UnpackedSize <= panelMaxPayload && componentDigestPattern.MatchString(c.SHA256) && componentDigestPattern.MatchString(c.BinarySHA256)
}

// encoding/json accepts duplicate keys by default. Reject them at every depth.
func strictPanelJSON(raw []byte, v any) error {
	if len(raw) > 1<<20 {
		return panelPackageError
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var value func(int) error
	value = func(depth int) error {
		if depth > 16 {
			return panelPackageError
		}
		token, e := d.Token()
		if e != nil {
			return e
		}
		delim, ok := token.(json.Delim)
		if !ok {
			return nil
		}
		if delim != '{' && delim != '[' {
			return panelPackageError
		}
		keys := map[string]bool{}
		for d.More() {
			if delim == '{' {
				key, e := d.Token()
				if e != nil {
					return e
				}
				s, ok := key.(string)
				if !ok || keys[s] {
					return panelPackageError
				}
				keys[s] = true
			}
			if e := value(depth + 1); e != nil {
				return e
			}
		}
		_, e = d.Token()
		return e
	}
	if e := value(0); e != nil {
		return panelPackageError
	}
	if _, e := d.Token(); e != io.EOF {
		return panelPackageError
	}
	d = json.NewDecoder(bytes.NewReader(raw))
	d.DisallowUnknownFields()
	if e := d.Decode(v); e != nil {
		return panelPackageError
	}
	return nil
}
func parsePanelIndex(raw []byte, channel, arch string) (panelCandidate, error) {
	var index panelIndex
	if strictPanelJSON(raw, &index) != nil || index.Schema != 1 || index.Channel != channel || !panelArchValid(arch) || len(index.Packages) < 1 || len(index.Packages) > 4 {
		return panelCandidate{}, panelPackageError
	}
	if !panelTagValid(channel, index.Tag) {
		return panelCandidate{}, panelPackageError
	}
	seen := map[string]bool{}
	var result panelCandidate
	for _, c := range index.Packages {
		if !c.valid() || seen[c.Architecture] {
			return panelCandidate{}, panelPackageError
		}
		seen[c.Architecture] = true
		if c.Architecture == arch {
			c.Tag = index.Tag
			c.Channel = channel
			result = c
		}
	}
	if result.Name == "" {
		return result, panelPackageError
	}
	return result, nil
}
func panelVersionNewer(ctx context.Context, opkg, current, candidate string) (bool, error) {
	if !componentVersionPattern.MatchString(current) || !componentVersionPattern.MatchString(candidate) {
		return false, panelPackageError
	}
	dir, e := os.MkdirTemp("", "kas-panel-compare-")
	if e != nil {
		return false, e
	}
	defer os.RemoveAll(dir)
	if e := os.MkdirAll(filepath.Join(dir, "opt/tmp"), 0700); e != nil {
		return false, e
	}
	conf := filepath.Join(dir, "opkg.conf")
	if e := os.WriteFile(conf, []byte("dest root /\n"), 0600); e != nil {
		return false, e
	}
	cmd := exec.CommandContext(ctx, opkg, "-f", conf, "--offline-root", dir, "--tmp-dir", filepath.Join(dir, "opt/tmp"), "compare-versions", candidate, ">>", current)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	e = cmd.Run()
	if e == nil {
		return true, nil
	}
	var exit *exec.ExitError
	if errors.As(e, &exit) && exit.ExitCode() == 1 {
		return false, nil
	}
	return false, errors.New("PANEL_VERSION_UNVERIFIED")
}
func panelFields(raw []byte, sep string) (map[string]string, error) {
	result := map[string]string{}
	for _, line := range strings.Split(strings.TrimSuffix(string(raw), "\n"), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, sep, 2)
		if len(parts) != 2 || parts[0] == "" || strings.TrimSpace(parts[0]) != parts[0] {
			return nil, panelPackageError
		}
		if _, exists := result[parts[0]]; exists {
			return nil, panelPackageError
		}
		result[parts[0]] = strings.TrimSpace(parts[1])
	}
	return result, nil
}
func validatePanelControl(raw []byte, c panelCandidate) error {
	f, e := panelFields(raw, ":")
	if e != nil || f["Package"] != "kas-control-center" || f["Version"] != c.Version || f["Architecture"] != c.Architecture || f["Source"] != c.SourceSHA {
		return panelPackageError
	}
	allowed := map[string]bool{"Package": true, "Version": true, "Architecture": true, "Source": true, "Maintainer": true, "Section": true, "Priority": true, "Description": true, "Installed-Size": true}
	for key := range f {
		if !allowed[key] {
			return panelPackageError
		}
	}
	return nil
}
func panelTar(r io.Reader, expected map[string]bool, limit int64, member func(string, io.Reader, int64) error) error {
	gz, e := gzip.NewReader(r)
	if e != nil {
		return panelPackageError
	}
	defer gz.Close()
	// Includes file bytes, headers and bounded padding; no unbounded decompression.
	lr := &io.LimitedReader{R: gz, N: limit + (1 << 20)}
	tr := tar.NewReader(lr)
	seen := map[string]bool{}
	dirs := map[string]bool{}
	for name := range expected {
		for p := path.Dir(name); p != "."; p = path.Dir(p) {
			dirs[p] = true
		}
	}
	total := int64(0)
	for {
		h, e := tr.Next()
		if e == io.EOF {
			break
		}
		if e != nil {
			return panelPackageError
		}
		name := strings.TrimSuffix(strings.TrimPrefix(h.Name, "./"), "/")
		if name == "" || path.Clean(name) != name || strings.HasPrefix(name, "/") || strings.Contains(name, "\\") || seen[name] || h.Uid != 0 || h.Gid != 0 || h.Mode&06022 != 0 {
			return panelPackageError
		}
		seen[name] = true
		if h.Typeflag == tar.TypeDir {
			if !dirs[name] || h.Size != 0 {
				return panelPackageError
			}
			continue
		}
		if h.Typeflag != tar.TypeReg || !expected[name] || h.Size < 0 || h.Size > limit-total {
			return panelPackageError
		}
		total += h.Size
		if e := member(name, tr, h.Size); e != nil {
			return e
		}
	}
	// Finish gzip checksum; only zero tar padding may follow the end marker.
	tail := make([]byte, 4096)
	for {
		n, e := lr.Read(tail)
		for _, b := range tail[:n] {
			if b != 0 {
				return panelPackageError
			}
		}
		if e == io.EOF {
			break
		}
		if e != nil {
			return panelPackageError
		}
	}
	if lr.N == 0 {
		return panelPackageError
	}
	for n := range expected {
		if !seen[n] {
			return panelPackageError
		}
	}
	return nil
}
func validatePanelIPK(file string, c panelCandidate) error {
	if !c.valid() {
		return panelPackageError
	}
	f, e := os.Open(file)
	if e != nil {
		return e
	}
	defer f.Close()
	st, e := f.Stat()
	if e != nil || !st.Mode().IsRegular() || st.Size() != c.Size {
		return panelPackageError
	}
	hash := sha256.New()
	if n, e := io.Copy(hash, io.LimitReader(f, panelMaxIPK+1)); e != nil || n != c.Size || hex.EncodeToString(hash.Sum(nil)) != c.SHA256 {
		return panelPackageError
	}
	if _, e := f.Seek(0, 0); e != nil {
		return e
	}
	return panelTar(f, map[string]bool{"debian-binary": true, "control.tar.gz": true, "data.tar.gz": true}, panelMaxIPK, func(name string, r io.Reader, size int64) error {
		switch name {
		case "debian-binary":
			b, e := io.ReadAll(io.LimitReader(r, 16))
			if e != nil || string(b) != "2.0\n" {
				return panelPackageError
			}
		case "control.tar.gz":
			return panelTar(r, map[string]bool{"control": true, "preinst": true, "postinst": true, "prerm": true}, 256<<10, func(n string, r io.Reader, size int64) error {
				if size > 64<<10 {
					return panelPackageError
				}
				b, e := io.ReadAll(r)
				if e != nil {
					return e
				}
				if n == "control" {
					return validatePanelControl(b, c)
				}
				if !bytes.HasPrefix(b, []byte("#!/bin/sh\n")) {
					return panelPackageError
				}
				return nil
			})
		case "data.tar.gz":
			total := int64(0)
			var info []byte
			var binaryDigest string
			e := panelTar(r, map[string]bool{"opt/bin/kas-control-center": true, "opt/etc/init.d/S98kas-control-center": true, "opt/share/kas-control-center/BUILD_INFO": true, "opt/share/kas-control-center/THIRD_PARTY_NOTICES": true}, panelMaxPayload, func(n string, r io.Reader, size int64) error {
				total += size
				if n == "opt/bin/kas-control-center" {
					h := sha256.New()
					head := make([]byte, 64)
					if _, e := io.ReadFull(r, head); e != nil {
						return panelPackageError
					}
					if !panelELF(head, c.Architecture) {
						return panelPackageError
					}
					h.Write(head)
					if _, e := io.Copy(h, r); e != nil {
						return e
					}
					binaryDigest = fmt.Sprintf("%x", h.Sum(nil))
					return nil
				}
				if size > 128<<10 {
					return panelPackageError
				}
				b, e := io.ReadAll(r)
				if e != nil {
					return e
				}
				if strings.HasSuffix(n, "BUILD_INFO") {
					info = b
				}
				if strings.HasSuffix(n, "S98kas-control-center") && !bytes.HasPrefix(b, []byte("#!/bin/sh\n")) {
					return panelPackageError
				}
				return nil
			})
			if e != nil || total != c.UnpackedSize || binaryDigest != c.BinarySHA256 {
				return panelPackageError
			}
			fields, e := panelFields(info, "=")
			if e != nil || fields["Version"] != c.Version || fields["KAS_SOURCE_SHA"] != c.SourceSHA || fields["Architecture"] != c.Architecture || fields["Binary_SHA256"] != c.BinarySHA256 || fields["CGO_ENABLED"] != "0" || fields["Channel"] != c.Channel {
				return panelPackageError
			}
			arch := map[string]string{"mipsel-3.4": "mipsle", "mips-3.4": "mips", "armv7-3.2": "arm", "aarch64-3.10": "arm64"}[c.Architecture]
			if fields["GOARCH"] != arch || strings.HasPrefix(arch, "mips") && fields["GOMIPS"] != "softfloat" || arch == "arm" && fields["GOARM"] != "7" {
				return panelPackageError
			}
		}
		return nil
	})
}
func panelELF(b []byte, arch string) bool {
	if len(b) < 64 || !bytes.Equal(b[:4], []byte{127, 'E', 'L', 'F'}) || b[6] != 1 {
		return false
	}
	class, endian, machine := byte(1), byte(1), uint16(8)
	switch arch {
	case "mips-3.4":
		endian = 2
	case "armv7-3.2":
		machine = 40
	case "aarch64-3.10":
		class = 2
		machine = 183
	case "mipsel-3.4":
	default:
		return false
	}
	var order binary.ByteOrder = binary.LittleEndian
	if endian == 2 {
		order = binary.BigEndian
	}
	return b[4] == class && b[5] == endian && order.Uint16(b[18:20]) == machine
}
