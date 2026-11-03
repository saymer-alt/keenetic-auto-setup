package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Generated independently with OpenSSL passwd -1/-5/-6 -salt saltsalt.
var entwareVectors = []string{
	"$1$saltsalt$VnSI6X3Ulc5bn6YFatfUW0",
	"$5$saltsalt$aqbqOTENxQxvg3WG5y2GSgzzDdePPx6DNJ62LX0/QzD",
	"$6$saltsalt$62yB5ThboPKIynD0rklPtaSK6o8vfyzPbifv6nVTIsf/6IrXa/El/Mv/SMNl2rvDklKI1/y2mOsLiriFCQeqh1",
}

func credentialFixture(t *testing.T, root, name, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, "etc"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "etc", name), []byte(value), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestEntwareIndependentCryptVectors(t *testing.T) {
	for _, hash := range entwareVectors {
		t.Run(hash[1:2], func(t *testing.T) {
			root := t.TempDir()
			credentialFixture(t, root, "passwd", "root:x:0:0:root:/root:/bin/sh\n")
			credentialFixture(t, root, "shadow", "root:"+hash+":19000:0:99999:7:::\n")
			got, err := entwarePasswordHash(root, "root")
			if err != nil || got != hash {
				t.Fatal("root hash unavailable")
			}
			if !checkEntwarePassword(root, "root", "router-password") {
				t.Fatal("independent vector rejected")
			}
			if checkEntwarePassword(root, "root", "wrong") || checkEntwarePassword(root, "root", "") {
				t.Fatal("bad password accepted")
			}
			credentialFixture(t, root, "shadow", "root:!"+hash+":19000:0:99999:7:::\n")
			if checkEntwarePassword(root, "root", "router-password") {
				t.Fatal("locked account accepted")
			}
		})
	}
}

func TestEntwareFallbackAndFreshState(t *testing.T) {
	root := t.TempDir()
	credentialFixture(t, root, "passwd", "root:"+entwareVectors[0]+":0:0:root:/root:/bin/sh\n")
	if !checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("passwd fallback rejected")
	}
	credentialFixture(t, root, "shadow", "root:*:19000:0:99999:7:::\n")
	if checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("shadow lock bypassed via passwd")
	}
	credentialFixture(t, root, "shadow", "other:"+entwareVectors[0]+":19000:0:99999:7:::\n")
	if checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("missing shadow root bypassed")
	}
	credentialFixture(t, root, "shadow", "root:"+entwareVectors[0]+":19000:0:99999:7:::\n")
	if !checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("changed state not reread")
	}
	credentialFixture(t, root, "shadow", "root:"+entwareVectors[1]+":19000:0:99999:7:::\n")
	if !checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("replacement hash not reread")
	}
	credentialFixture(t, root, "shadow", "root:$6$saltsalt$fgyuzd4Foc9A1TL2VKaoaj/qZ9DC0MN1O4tFnao9SF3p1L/yLS3C6N3aZIWygll6mYSOcssFnyEVVTyh/B1lM0:19000:0:99999:7:::\n")
	if checkEntwarePassword(root, "root", "router-password") || !checkEntwarePassword(root, "root", "changed-password") {
		t.Fatal("password change not respected")
	}
}

func TestEntwareLongIndependentVectors(t *testing.T) {
	// OpenSSL vectors above also generated with a 128-byte password. This
	// catches length-handling faults that short crypt test vectors miss.
	for _, hash := range []string{
		"$5$saltsalt$tkkQKovHTk0xathHdSQcjAvdRnJs.gwPYYQDQs5f9VB",
		"$6$saltsalt$gMgmpB5vJeEcZwoAK.oBWemFhmunx1texmUNGdSUf7Zh2wFqvTSYmVFxR2ScPvzAbcm2xRvGYjMzS0Ao8.Pqo0",
	} {
		root := t.TempDir()
		credentialFixture(t, root, "shadow", "root:"+hash+":19000:0:99999:7:::\n")
		if !checkEntwarePassword(root, "root", strings.Repeat("x", 128)) {
			t.Fatal("long independent vector rejected")
		}
	}
}

func TestEntwareUnsafeFilesFailClosed(t *testing.T) {
	root := t.TempDir()
	credentialFixture(t, root, "passwd", "root:"+entwareVectors[0]+":0:0:root:/root:/bin/sh\n")
	credentialFixture(t, root, "shadow", strings.Repeat("x", 65537))
	if _, err := entwarePasswordHash(root, "root"); err == nil || err.Error() != "credentials unavailable" {
		t.Fatal("oversize file not rejected generically")
	}
	if err := os.Remove(filepath.Join(root, "etc", "shadow")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "etc", "passwd"), filepath.Join(root, "etc", "shadow")); err != nil {
		t.Fatal(err)
	}
	if checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("unsafe shadow fell back to passwd")
	}
}

func TestEntwareRejectsUnsafeCredentials(t *testing.T) {
	for _, hash := range []string{"", "x", "!", "*", "!!", "!" + entwareVectors[0], "$2b$10$invalid", "$6$rounds=999999999$salt$bad", "$5$rounds=100001$salt$bad", strings.Repeat("x", 300), "$6$salt$bad"} {
		root := t.TempDir()
		credentialFixture(t, root, "shadow", "root:"+hash+":19000:0:99999:7:::\n")
		if checkEntwarePassword(root, "root", "router-password") {
			t.Fatal("unsafe hash accepted")
		}
		if _, err := entwarePasswordHash(root, "root"); err == nil {
			t.Fatal("unsafe hash returned")
		}
	}
	root := t.TempDir()
	credentialFixture(t, root, "shadow", "admin:"+entwareVectors[0]+":19000:0:99999:7:::\nroot:"+entwareVectors[0]+":19000:0:99999:7:::\n")
	for _, login := range []string{"admin", "", "root\n", "../root"} {
		if checkEntwarePassword(root, login, "router-password") {
			t.Fatal("non-root accepted")
		}
	}
	if checkEntwarePassword(root, "root", strings.Repeat("x", 129)) {
		t.Fatal("oversize accepted")
	}
	credentialFixture(t, root, "shadow", "root:"+entwareVectors[0]+":1:0:99999:7:::\nroot:"+entwareVectors[1]+":1:0:99999:7:::\n")
	if checkEntwarePassword(root, "root", "router-password") {
		t.Fatal("ambiguous account accepted")
	}
}

func TestPanelPasswordHashRoundTripAndLimits(t *testing.T) {
	password := "correct panel password"
	first, err := newPanelPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	second, err := newPanelPassword(password)
	if err != nil {
		t.Fatal(err)
	}
	if first == second || strings.Contains(first, password) {
		t.Fatal("password hash is not independently salted")
	}
	if !checkPanelPassword(password, first) || checkPanelPassword("wrong", first) {
		t.Fatal("password verification failed")
	}
	for _, password := range []string{"", strings.Repeat("x", 11), strings.Repeat("x", 129)} {
		if _, err := newPanelPassword(password); err == nil {
			t.Fatal("invalid password length accepted")
		}
	}
	for _, password := range []string{strings.Repeat("x", 12), strings.Repeat("x", 128)} {
		hash, err := newPanelPassword(password)
		if err != nil || !checkPanelPassword(password, hash) {
			t.Fatal("valid boundary rejected")
		}
	}
	for _, hash := range []string{"", entwareVectors[0], entwareVectors[2], "$kas-panel$1$$6$rounds=999999999$salt$bad", first + "x"} {
		if checkPanelPassword(password, hash) {
			t.Fatal("invalid panel hash accepted")
		}
	}
}
