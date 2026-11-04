package main

import (
	"crypto/sha256"
	"encoding/hex"
)

// A source snapshot is NOT a standalone Watchdog semver. We can only claim
// content equality with the script bundled into this verified Web build when
// its actual installed SHA256 matches the bundled canonical source bytes.
// An unrecognized, old or locally modified script retains SHA-only evidence.
func matchedWatchdogSourceSnapshot(installedSHA string) string {
	if !componentDigestPattern.MatchString(installedSHA) ||
		!componentSourcePattern.MatchString(panelBuildSHA) {
		return ""
	}
	source, err := assets.ReadFile("scripts/mihomo-watchdog.sh")
	if err != nil || len(source) == 0 || len(source) > 262144 {
		return ""
	}
	sum := sha256.Sum256(source)
	if hex.EncodeToString(sum[:]) != installedSHA {
		return ""
	}
	return panelBuildSHA
}
