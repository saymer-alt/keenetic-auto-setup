package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

func mihomoUpdateOffered(relation string) bool {
	return relation == "newer" || relation == "newer_package" || relation == "unknown"
}

// Match the canonical updater's package-only provenance conditions. opkg metadata
// is displayed separately and never authorizes replacing a binary updated outside opkg.
// The legacy receipt binds version/arch/size, not a cryptographic binary digest.
func enrichMihomoCheck(root string, c updateCheck) updateCheck {
	if b, err := inventoryFile(root, "lib/opkg/info/mihomo.control", 65536, false); err == nil {
		c.InstalledPackageVersion = parsePackageVersion(string(b), "mihomo")
	}
	if c.Relation != "same_runtime" {
		return c
	}
	b, err := inventoryFile(root, "etc/keenetic-auto-setup-mihomo.state", 4096, false)
	if os.IsNotExist(err) {
		return c
	}
	c.Relation = "invalid_state"
	if err != nil {
		return c
	}
	values := map[string]string{}
	seen := map[string]bool{}
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		p := strings.Split(line, "=")
		if len(p) != 2 || seen[p[0]] {
			return c
		}
		values[p[0]] = p[1]
		seen[p[0]] = true
	}
	release, e := strconv.Atoi(values["package_release"])
	if e != nil || release < 1 || release > 999999999 || strconv.Itoa(release) != values["package_release"] || values["state_format"] != "1" || values["source"] != "entware-go-binary-updater" || values["runtime_version"] != c.CurrentVersion || values["asset"] != "mihomo_"+c.CurrentVersion+"-"+strconv.Itoa(release)+"_"+c.Architecture+".ipk" {
		return c
	}
	size, e := strconv.ParseInt(values["binary_size_bytes"], 10, 64)
	if e != nil || size <= 0 || size > 128*1024*1024 {
		return c
	}
	found := 0
	for _, name := range []string{"bin/mihomo", "sbin/mihomo"} {
		path := filepath.Join(root, name)
		st, e := os.Lstat(path)
		if os.IsNotExist(e) {
			continue
		}
		if e != nil || !st.Mode().IsRegular() || !inventoryOwned(st) || st.Mode().Perm()&0022 != 0 || st.Size() != size {
			return c
		}
		parent, e := os.Lstat(filepath.Dir(path))
		if e != nil || !parent.IsDir() || !inventoryOwned(parent) || parent.Mode().Perm()&0022 != 0 {
			return c
		}
		found++
	}
	if found != 1 {
		return c
	}
	c.RecordedPackageRelease = release
	c.Relation = "same_package"
	if c.PackageRelease > release {
		c.Relation = "newer_package"
	} else if c.PackageRelease < release {
		c.Relation = "older_package"
	}
	return c
}
