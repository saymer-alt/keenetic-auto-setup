package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func panelFixture(t *testing.T) (panelCandidate, []byte) {
	t.Helper()
	binary := make([]byte, 128)
	copy(binary, []byte{0x7f, 'E', 'L', 'F', 1, 1, 1})
	binary[18] = 8
	source := strings.Repeat("a", 40)
	info := fmt.Sprintf("Version=0.0.1~test16.aaaaaaaaaaaa-1\nKAS_SOURCE_SHA=%s\nArchitecture=mipsel-3.4\nChannel=experimental\nCGO_ENABLED=0\nGOARCH=mipsle\nGOMIPS=softfloat\nBinary_SHA256=%x\n", source, sha256.Sum256(binary))
	payload := mtTar(map[string]string{"opt/bin/kas-control-center": string(binary), "opt/etc/init.d/S98kas-control-center": "#!/bin/sh\n# KAS-CONTROL-CENTER-IPK-v1\n", "opt/share/kas-control-center/BUILD_INFO": info, "opt/share/kas-control-center/THIRD_PARTY_NOTICES": "notice"})
	control := mtTar(map[string]string{"control": fmt.Sprintf("Package: kas-control-center\nVersion: 0.0.1~test16.aaaaaaaaaaaa-1\nArchitecture: mipsel-3.4\nSource: %s\n", source), "preinst": "#!/bin/sh\n", "postinst": "#!/bin/sh\n", "prerm": "#!/bin/sh\n"})
	ipk := mtTar(map[string]string{"./debian-binary": "2.0\n", "./control.tar.gz": string(control), "./data.tar.gz": string(payload)})
	c := panelCandidate{Channel: "experimental", Version: "0.0.1~test16.aaaaaaaaaaaa-1", SourceSHA: source, Architecture: "mipsel-3.4", Name: "kas-control-center_0.0.1.test16.aaaaaaaaaaaa-1_mipsel-3.4.ipk", Size: int64(len(ipk)), SHA256: fmt.Sprintf("%x", sha256.Sum256(ipk)), BinarySHA256: fmt.Sprintf("%x", sha256.Sum256(binary)), UnpackedSize: int64(len(binary) + len(info) + len("#!/bin/sh\n# KAS-CONTROL-CENTER-IPK-v1\n") + len("notice"))}
	return c, ipk
}
func TestPanelIndexRejectsAmbiguityAndWrongChannel(t *testing.T) {
	c, _ := panelFixture(t)
	index := panelIndex{Schema: 1, Channel: "experimental", Tag: "kas-web-ipk-aaaaaaa", Packages: []panelCandidate{c}}
	raw, _ := json.Marshal(index)
	got, e := parsePanelIndex(raw, "experimental", "mipsel-3.4")
	if e != nil || got.Version != c.Version {
		t.Fatalf("valid: %v %#v", e, got)
	}
	for _, raw := range [][]byte{[]byte(`{"schema":1,"schema":1}`), append(raw, []byte(`{}`)...)} {
		if _, e := parsePanelIndex(raw, "experimental", "mipsel-3.4"); e == nil {
			t.Fatal("ambiguous index accepted")
		}
	}
	if _, e := parsePanelIndex(raw, "stable", "mipsel-3.4"); e == nil {
		t.Fatal("wrong channel accepted")
	}
	index.Packages = append(index.Packages, c)
	raw, _ = json.Marshal(index)
	if _, e := parsePanelIndex(raw, "experimental", "mipsel-3.4"); e == nil {
		t.Fatal("duplicate ABI accepted")
	}
}
func TestPanelIPKInternalIdentityAndIntegrity(t *testing.T) {
	c, b := panelFixture(t)
	p := filepath.Join(t.TempDir(), "panel.ipk")
	os.WriteFile(p, b, 0600)
	if e := validatePanelIPK(p, c); e != nil {
		t.Fatal(e)
	}
	for _, change := range []func(*panelCandidate){func(x *panelCandidate) { x.Version = "0.1.0-1" }, func(x *panelCandidate) { x.Architecture = "aarch64-3.10" }, func(x *panelCandidate) { x.Size++ }, func(x *panelCandidate) { x.BinarySHA256 = strings.Repeat("b", 64) }, func(x *panelCandidate) { x.UnpackedSize-- }} {
		x := c
		change(&x)
		if e := validatePanelIPK(p, x); e == nil {
			t.Fatal("mismatching candidate accepted")
		}
	}
	b[len(b)/2] ^= 1
	os.WriteFile(p, b, 0600)
	if e := validatePanelIPK(p, c); e == nil {
		t.Fatal("changed IPK accepted")
	}
}
func TestPanelControlRefusesDependenciesAndDuplicateFields(t *testing.T) {
	c, _ := panelFixture(t)
	base := fmt.Sprintf("Package: kas-control-center\nVersion: %s\nArchitecture: %s\nSource: %s\n", c.Version, c.Architecture, c.SourceSHA)
	for _, extra := range []string{"Depends: curl\n", "Recommends: curl\n", "Suggests: curl\n", "Pre-Depends: sh\n", "Replaces: mihomo\n", "Conflicts: mihomo\n", "Provides: something\n", "Version: 9\n"} {
		if e := validatePanelControl([]byte(base+extra), c); e == nil {
			t.Fatalf("accepted %q", extra)
		}
	}
}
func TestPanelRealOPKGVersionComparison(t *testing.T) {
	opkg := os.Getenv("KAS_TEST_OPKG")
	if opkg == "" {
		t.Skip("requires verified official Entware opkg")
	}
	for _, tc := range []struct {
		old, new string
		want     bool
	}{{"0.0.1~test9.a-1", "0.0.1~test16.a-1", true}, {"0.0.1~test16.a-1", "0.0.1~test9.a-1", false}, {"0.0.1~test15.a-1", "0.0.1~test15.a-1", false}, {"0.0.1.test15.a-1", "0.0.1~test16.a-1", false}} {
		got, e := panelVersionNewer(context.Background(), opkg, tc.old, tc.new)
		if e != nil || got != tc.want {
			t.Fatalf("%s -> %s: %v %v", tc.old, tc.new, got, e)
		}
	}
}

func TestPanelIndexAcceptsActualBuilderTildeAssetName(t *testing.T) {
	c, _ := panelFixture(t)
	c.Name = "kas-control-center_" + c.Version + "_" + c.Architecture + ".ipk"
	raw, _ := json.Marshal(panelIndex{Schema: 1, Channel: "experimental", Tag: "kas-web-ipk-aaaaaaa", Packages: []panelCandidate{c}})
	if _, e := parsePanelIndex(raw, "experimental", "mipsel-3.4"); e != nil {
		t.Fatal("actual builder filename rejected", e)
	}
}

func TestPanelActualBuiltIPKMatchesGeneratedIndex(t *testing.T) {
	file := os.Getenv("KAS_TEST_PANEL_IPK")
	if file == "" {
		t.Skip("requires source-built IPK; crossbuild CI runs this check")
	}
	output, e := exec.Command("python3", "packaging/update-manifest.py", "--channel", "experimental", "--tag", "kas-web-ipk-aaaaaaa", file).Output()
	if e != nil {
		t.Fatal(e)
	}
	arch := os.Getenv("KAS_TEST_PANEL_ARCH")
	if arch == "" {
		arch = "mipsel-3.4"
	}
	c, e := parsePanelIndex(output, "experimental", arch)
	if e != nil {
		t.Fatal(e)
	}
	if e := validatePanelIPK(file, c); e != nil {
		t.Fatal(e)
	}
}
func TestPanelRealOPKGDoesNotRemoveWorkerStage(t *testing.T) {
	opkg := os.Getenv("KAS_TEST_OPKG")
	if opkg == "" {
		t.Skip("requires verified Entware opkg")
	}
	file := os.Getenv("KAS_TEST_PANEL_IPK")
	if file == "" {
		t.Skip("requires source-built IPK")
	}
	root := t.TempDir()
	stage := filepath.Join(root, "stage")
	os.MkdirAll(filepath.Join(root, "opt/tmp"), 0700)
	os.Mkdir(stage, 0700)
	os.WriteFile(filepath.Join(stage, "runner"), []byte("runner sentinel"), 0700)
	content, e := os.ReadFile(file)
	if e != nil {
		t.Fatal(e)
	}
	candidate := filepath.Join(stage, "candidate.ipk")
	os.WriteFile(candidate, content, 0600)
	conf := filepath.Join(root, "opkg.conf")
	os.WriteFile(conf, []byte("dest root /\narch mipsel-3.4 10\n"), 0600)
	// Offline hooks use the real package. They never execute host services.
	out, e := exec.Command(opkg, "-f", conf, "--offline-root", root, "--force-postinstall", "--tmp-dir", stage, "install", candidate).CombinedOutput()
	if e != nil {
		t.Fatalf("%v: %s", e, out)
	}
	for _, name := range []string{"runner", "candidate.ipk"} {
		if _, e := os.Stat(filepath.Join(stage, name)); e != nil {
			t.Fatalf("opkg removed stage %s: %v", name, e)
		}
	}
	installed, e := os.ReadFile(filepath.Join(root, "opt/share/kas-control-center/BUILD_INFO"))
	if e != nil || !strings.Contains(string(installed), "Channel=experimental") {
		t.Fatal("installed package identity missing", e)
	}
}

func TestPanelTarRejectsTraversalLinksTruncationAndOversize(t *testing.T) {
	read := func(_ string, r io.Reader, _ int64) error { _, e := io.Copy(io.Discard, r); return e }
	for _, raw := range [][]byte{mtTar(map[string]string{"../escape": "bad"}), mtTar(map[string]string{"/file": "bad"}), mtTar(map[string]string{"file": strings.Repeat("x", 1024)})} {
		if e := panelTar(bytes.NewReader(raw), map[string]bool{"file": true}, 64, read); e == nil {
			t.Fatal("unsafe or oversized archive accepted")
		}
	}
	good := mtTar(map[string]string{"file": "ok"})
	if e := panelTar(bytes.NewReader(good[:len(good)-4]), map[string]bool{"file": true}, 64, read); e == nil {
		t.Fatal("truncated gzip accepted")
	}
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	tw.WriteHeader(&tar.Header{Name: "file", Typeflag: tar.TypeSymlink, Linkname: "/etc/passwd", Mode: 0755})
	tw.Close()
	gz.Close()
	if e := panelTar(bytes.NewReader(b.Bytes()), map[string]bool{"file": true}, 64, read); e == nil {
		t.Fatal("symlink accepted")
	}
}
