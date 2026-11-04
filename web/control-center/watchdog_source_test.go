package main

import (
	"crypto/sha256"
	"encoding/hex"
	"strings"
	"testing"
)

func TestWatchdogSourceSnapshotOnlyWithExactBytesAndBuildSHA(t *testing.T) {
	orig := panelBuildSHA
	defer func(){panelBuildSHA=orig}()
	source,err:=assets.ReadFile("scripts/mihomo-watchdog.sh")
	if err!=nil{t.Fatal(err)}
	sum:=sha256.Sum256(source)
	digest:=hex.EncodeToString(sum[:])
	panelBuildSHA=strings.Repeat("a",40)
	if got:=matchedWatchdogSourceSnapshot(digest);got!=panelBuildSHA{
		t.Fatal("exact source snapshot not shown",got)
	}
	for _,bad:=range []string{"",strings.Repeat("0",64),"invalid"}{
		if matchedWatchdogSourceSnapshot(bad)!=""{t.Fatal("unverified watchdog attributed",bad)}
	}
	panelBuildSHA=""
	if matchedWatchdogSourceSnapshot(digest)!=""{t.Fatal("development build assigned false source revision")}
}
