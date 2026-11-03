package main

// Full canonical updater driven through the HTTP adapter. Only filesystem roots,
// network acquisition and kernel/service observations are fixture seams. The
// production transaction, extraction, probes, rename, recovery and locks run.
// This is not firmware/ABI/native PID acceptance: lifecycle/process fixtures are
// synthetic, as in tests/rollback-regression.py. Nothing touches host /opt.
import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func transactionArchive(name string, data []byte) []byte {
	var raw bytes.Buffer
	gz := gzip.NewWriter(&raw)
	tw := tar.NewWriter(gz)
	_ = tw.WriteHeader(&tar.Header{Name: name, Mode: 0755, Size: int64(len(data))})
	_, _ = tw.Write(data)
	_ = tw.Close()
	_ = gz.Close()
	return raw.Bytes()
}
func TestPanelFullCanonicalUpdaterTransaction(t *testing.T) {
	for _, scenario := range []string{"changed", "unchanged", "start-fail"} {
		t.Run(scenario, func(t *testing.T) {
			lab := t.TempDir()
			write := func(name, body string, mode os.FileMode) {
				path := filepath.Join(lab, name)
				if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(path, []byte(body), mode); err != nil {
					t.Fatal(err)
				}
			}
			// The stand-in executable refuses *any* probe beside the service marker.
			binary := func(version, generation string) string {
				return fmt.Sprintf(`#!/bin/sh
if [ -f '%s/running' ]; then echo SECOND-PROBE >> '%s/events';exit 99;fi
printf 'Mihomo Meta %s\n'
exit 0
# %s
`, lab, lab, version, generation)
			}
			old := binary("1.19.33", "old")
			candidate := binary("1.19.34", "new")
			available := "1.19.34"
			if scenario == "unchanged" {
				available = "1.19.32"
				candidate = binary(available, "new")
			}
			write("opt/bin/mihomo", old, 0755)
			write("opt/etc/mihomo/config.yaml", "mixed-port: 7890\n# PRIVATE fixture\n", 0600)
			write("running", "yes", 0600)
			init := fmt.Sprintf(`#!/bin/sh
case "$1" in
 stop) echo stop >> '%s/events';rm -f '%s/running';;
 start|restart) echo start >> '%s/events';
  if [ '%s' = start-fail ] && grep -q '# new' '%s/opt/bin/mihomo';then exit 1;fi
  touch '%s/running';;
esac
`, lab, lab, lab, scenario, lab, lab)
			init = strings.ReplaceAll(init, "echo start >>", "echo \"start:$(tail -1 '"+lab+"/opt/bin/mihomo')\" >>")
			write("opt/etc/init.d/S99mihomo", init, 0755)
			payload := transactionArchive("opt/bin/mihomo", []byte(candidate))
			packageBytes := transactionArchive("data.tar.gz", payload)
			if err := os.WriteFile(filepath.Join(lab, "package.ipk"), packageBytes, 0600); err != nil {
				t.Fatal(err)
			}
			write("release.json", string(releaseFixture("mihomo_"+available+"-1_mipsel-3.4.ipk")), 0600)
			os.Mkdir(filepath.Join(lab, "tmp"), 0700)
			// Defined shell commands observe only this private fixture. A live production
			// updater is never passed altered dependencies or test flags by HTTP.
			prelude := fmt.Sprintf(`
sleep(){ :; }
opkg(){ case "$1" in print-architecture) echo 'arch mipsel-3.4 150';;list-installed) echo 'mihomo - 1.19.33-1';;esac; }
pidof(){ [ -f '%[1]s/running' ] || return 1;echo 4242; }
curl(){
 target='';output='';next=0
 for arg do if [ "$next" = 1 ];then output=$arg;next=0;continue;fi;case "$arg" in -o)next=1;;https://*)target=$arg;;esac;done
 case "$target" in *api.github.com*) cat '%[1]s/release.json';;*releases/download/latest/*) command cp '%[1]s/package.ipk' "$output";;*) return 0;;esac
}
wget(){ return 1; }
test(){ if [ "$2" = -ef ] && [ "$3" = /proc/4242/exe ];then [ -f '%[1]s/running' ];return;fi;command test "$@"; }
`, lab)
			script, err := os.ReadFile("../../update-mihomo.sh")
			if err != nil {
				t.Fatal(err)
			}
			sourceText := strings.ReplaceAll(string(script), "$_wd/opt/", "$_wd/__archive_opt__/")
			text := strings.NewReplacer("/opt/", lab+"/opt/", "/tmp/", lab+"/tmp/", `TMP_DIR="/tmp"`, `TMP_DIR="`+lab+`/tmp"`).Replace(sourceText)
			text = strings.ReplaceAll(text, "$_wd/__archive_opt__/", "$_wd/opt/")
			// Lock ownership is local to the synthetic process model. Native identity is
			// tested independently by existing lifecycle CI, never claimed by this case.
			marker := "\nacquire_lock\n"
			if strings.Count(text, marker) != 1 {
				t.Fatal("canonical lock seam moved")
			}
			text = strings.Replace(text, marker, "\nml_starttime(){ echo 12345; }\n"+marker, 1)
			a := newApp("127.0.0.1:18081", nil)
			a.updater = []byte("exec > '" + lab + "/output' 2>&1\n" + prelude + "\n" + text)
			a.lastUpdateCheck = updateCheck{State: "AVAILABLE", Relation: "unknown", Time: now()}
			a.updateDigest = func() string { return mihomoBinaryDigest(filepath.Join(lab, "opt")) }
			a.runUpdate = updateCommand
			w := updateRequest(a, "/api/updates/mihomo", "http://127.0.0.1:18081", "update-mihomo", "{}")
			if w.Code != 202 {
				t.Fatal(w.Code, w.Body.String())
			}
			deadline := time.Now().Add(15 * time.Second)
			var result updateOperation
			done := false
			for time.Now().Before(deadline) {
				a.mu.Lock()
				done = !a.importRunning
				result = a.updateResult
				a.mu.Unlock()
				if done {
					break
				}
				time.Sleep(time.Millisecond * 5)
			}
			if !done {
				t.Fatal("canonical updater timed out")
			}
			actual, _ := os.ReadFile(filepath.Join(lab, "opt/bin/mihomo"))
			config, _ := os.ReadFile(filepath.Join(lab, "opt/etc/mihomo/config.yaml"))
			events, _ := os.ReadFile(filepath.Join(lab, "events"))
			if string(config) != "mixed-port: 7890\n# PRIVATE fixture\n" || strings.Contains(string(events), "SECOND-PROBE") {
				t.Fatal("config changed or second probe", string(events))
			}
			if _, err := os.Stat(filepath.Join(lab, "running")); err != nil {
				t.Fatal("previously running service not restored", result, string(events), func() string { b, _ := os.ReadFile(filepath.Join(lab, "output")); return string(b) }())
			}
			if scenario == "changed" {
				if result.State != "OK" || string(actual) != candidate {
					t.Fatal("update did not apply", result, string(events), func() string { b, _ := os.ReadFile(filepath.Join(lab, "output")); return string(b) }())
				}
			}
			if scenario == "unchanged" {
				if result.State != "OK" || string(actual) != old {
					t.Fatal("no-op changed binary", result, string(events), func() string { b, _ := os.ReadFile(filepath.Join(lab, "output")); return string(b) }())
				}
			}
			if scenario == "start-fail" {
				if result.State != "FAIL" || string(actual) != old || !strings.Contains(string(events), "start:# new") || !strings.Contains(string(events), "start:# old") {
					t.Fatal("rollback did not restore binary", result, string(events), func() string { b, _ := os.ReadFile(filepath.Join(lab, "output")); return string(b) }())
				}
			}
			if scenario != "changed" {
				if _, err := os.Stat(filepath.Join(lab, "opt/etc/keenetic-auto-setup-mihomo.state")); !os.IsNotExist(err) {
					t.Fatal("metadata not restored", err)
				}
			}
			if _, err := os.Stat(filepath.Join(lab, "tmp/mihomo-lifecycle.lock.d")); !os.IsNotExist(err) {
				t.Fatal("lifecycle lock leaked", err)
			}
		})
	}
}
