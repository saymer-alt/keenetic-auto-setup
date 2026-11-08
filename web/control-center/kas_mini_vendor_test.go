package main

import (
	"bytes"
	"encoding/json"
	"os"
	"regexp"
	"testing"
)

// Stage B1 (issue saymer-alt/keenetic-auto-setup#425): the vendored kas-mini bundle must
// be part of the embedded panel assets (served by the existing static handler), define
// the Variant A integration global, stay free of external endpoints, and match the
// pinned provenance. Reproducibility itself is proven by build-vendor.mjs --verify in CI.
func TestEmbeddedKasMiniVendor(t *testing.T) {
	b, err := assets.ReadFile("web/kas-mini.js")
	if err != nil {
		t.Fatalf("vendored kas-mini.js is not embedded in panel assets: %v", err)
	}
	if len(b) < 1024 {
		t.Fatalf("vendored bundle suspiciously small: %d bytes", len(b))
	}
	if !bytes.HasPrefix(b, []byte("var KasMini=")) {
		t.Fatal("bundle must define the KasMini global (Variant A boundary, docs/35 §4.1)")
	}
	for _, banned := range []string{"fetch(", "web2core", "workers.dev", "localStorage"} {
		if bytes.Contains(b, []byte(banned)) {
			t.Errorf("vendored bundle contains %q: kas-mini must have no network/storage capability", banned)
		}
	}

	provRaw, err := os.ReadFile("kas-mini-vendor/PROVENANCE.json")
	if err != nil {
		t.Fatalf("read vendor provenance: %v", err)
	}
	var prov struct {
		SourceSha string `json:"sourceSha"`
		Files     map[string]struct {
			Sha256 string `json:"sha256"`
			Bytes  int    `json:"bytes"`
		} `json:"files"`
	}
	if err := json.Unmarshal(provRaw, &prov); err != nil {
		t.Fatalf("parse vendor provenance: %v", err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(prov.SourceSha) {
		t.Fatalf("provenance sourceSha is not a pinned 40-hex SHA: %q", prov.SourceSha)
	}
	entry, ok := prov.Files["kas-mini.js"]
	if !ok || len(entry.Sha256) != 64 {
		t.Fatal("provenance must record a sha256 for kas-mini.js")
	}
	if entry.Bytes != len(b) {
		t.Fatalf("committed bundle size %d does not match provenance %d", len(b), entry.Bytes)
	}
}
