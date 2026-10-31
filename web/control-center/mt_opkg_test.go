package main

// Actual Entware opkg, local HTTP feed and disposable filesystem. Package
// hooks/process observations are fixtures; no firmware or MT ABI claim.
import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

func mtTar(files map[string]string) []byte {
	var b bytes.Buffer
	gz := gzip.NewWriter(&b)
	tw := tar.NewWriter(gz)
	paths := []string{}
	for p := range files {
		paths = append(paths, p)
	}
	sort.Strings(paths)
	dirs := map[string]bool{}
	for _, p := range paths {
		s := files[p]
		parts := strings.Split(strings.TrimPrefix(p, "./"), "/")
		for i := 1; i < len(parts); i++ {
			dir := "./" + strings.Join(parts[:i], "/") + "/"
			if !dirs[dir] {
				_ = tw.WriteHeader(&tar.Header{Name: dir, Mode: 0755, Typeflag: tar.TypeDir})
				dirs[dir] = true
			}
		}
		_ = tw.WriteHeader(&tar.Header{Name: p, Mode: 0755, Size: int64(len(s))})
		_, _ = tw.Write([]byte(s))
	}
	_ = tw.Close()
	_ = gz.Close()
	return b.Bytes()
}
func mtIPK(version string) []byte {
	control := mtTar(map[string]string{"./control": "Package: magitrickle\nVersion: " + version + "\nArchitecture: all\nDescription: isolated MT transaction fixture\n", "./conffiles": "/opt/var/lib/magitrickle/config.yaml\n/opt/etc/config/magitrickle.conf\n", "./postinst": "#!/bin/sh\nROOT=${IPKG_INSTROOT:-${PKG_ROOT:-}}\n[ -n \"$ROOT\" ] || exit 98\nprintf running > \"$ROOT/running\"\n"})
	payload := mtTar(map[string]string{"./opt/bin/magitrickled": "fixture " + version, "./opt/var/lib/magitrickle/config.yaml": "defaults " + version, "./opt/etc/config/magitrickle.conf": "defaults " + version})
	return mtTar(map[string]string{"./debian-binary": "2.0\n", "./control.tar.gz": string(control), "./data.tar.gz": string(payload)})
}
func TestMTRealOPKGConffilesAndVersionSelection(t *testing.T) {
	binary := os.Getenv("KAS_TEST_OPKG")
	if binary == "" {
		t.Skip("actual Entware opkg fixture runs in panel IPK CI with KAS_TEST_OPKG")
	}
	lab := t.TempDir()
	root := filepath.Join(lab, "root")
	repo := filepath.Join(lab, "repo")
	os.MkdirAll(filepath.Join(root, "opt/tmp"), 0700)
	os.Mkdir(repo, 0700)
	server := httptest.NewServer(http.FileServer(http.Dir(repo)))
	defer server.Close()
	conf := filepath.Join(lab, "opkg.conf")
	os.WriteFile(conf, []byte("dest root /\narch all 1\nsrc/gz fixture "+server.URL+"\n"), 0600)
	run := func(ctx context.Context, args ...string) (string, error) {
		all := append([]string{"-f", conf, "--offline-root", root, "--force-postinstall", "--tmp-dir", filepath.Join(root, "opt/tmp")}, args...)
		b, e := exec.CommandContext(ctx, binary, all...).CombinedOutput()
		t.Logf("fixture opkg %v: %s", args, b)
		return string(b), e
	}
	old := filepath.Join(lab, "old.ipk")
	os.WriteFile(old, mtIPK("0.8.2-1"), 0600)
	if _, e := run(context.Background(), "install", old); e != nil {
		t.Fatal(e)
	}
	userConfig := filepath.Join(root, "opt/var/lib/magitrickle/config.yaml")
	userOptions := filepath.Join(root, "opt/etc/config/magitrickle.conf")
	if e := os.WriteFile(userConfig, []byte("PRIVATE user routes\n"), 0600); e != nil {
		t.Fatal(e)
	}
	if e := os.WriteFile(userOptions, []byte("PRIVATE user options\n"), 0600); e != nil {
		t.Fatal(e)
	}
	candidate := mtIPK("0.8.2-2")
	name := "magitrickle_0.8.2-2_all.ipk"
	os.WriteFile(filepath.Join(repo, name), candidate, 0600)
	index := fmt.Sprintf("Package: magitrickle\nVersion: 0.8.2-2\nArchitecture: all\nDescription: isolated fixture\nFilename: %s\nSize: %d\nSHA256sum: %x\n\n", name, len(candidate), sha256.Sum256(candidate))
	var gz bytes.Buffer
	z := gzip.NewWriter(&gz)
	z.Write([]byte(index))
	z.Close()
	os.WriteFile(filepath.Join(repo, "Packages.gz"), gz.Bytes(), 0600)
	commands := []string{}
	m := &mtMaintenance{ready: func() bool { return true }, process: func() string {
		b, _ := os.ReadFile(filepath.Join(root, "running"))
		if string(b) == "running" {
			return "running"
		}
		return "stopped"
	}, config: func() string {
		a, _ := os.ReadFile(userConfig)
		b, _ := os.ReadFile(userOptions)
		return fmt.Sprintf("%x", sha256.Sum256(append(a, b...)))
	}}
	m.command = func(ctx context.Context, args ...string) (string, error) {
		commands = append(commands, strings.Join(args, " "))
		if len(args) == 1 && args[0] == "restart" {
			return "", os.WriteFile(filepath.Join(root, "running"), []byte("running"), 0600)
		}
		return run(ctx, args...)
	}
	outcome, e := m.apply()
	if e != nil || outcome != "CHANGED" {
		t.Fatal(outcome, e, commands)
	}
	for p, want := range map[string]string{userConfig: "PRIVATE user routes\n", userOptions: "PRIVATE user options\n"} {
		b, e := os.ReadFile(p)
		if e != nil || string(b) != want {
			t.Fatal("conffile overwritten", p, string(b), e)
		}
	}
	commands = nil
	outcome, e = m.apply()
	if e != nil || outcome != "UNCHANGED" {
		t.Fatal(outcome, e, commands)
	}
	for _, c := range commands {
		if c == "restart" || c == "install magitrickle" {
			t.Fatal("no-op mutated", commands)
		}
	}
}
