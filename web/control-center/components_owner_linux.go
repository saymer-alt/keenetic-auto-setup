//go:build linux

package main

import (
	"os"
	"syscall"
)

func inventoryOwned(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return ok && stat.Uid == 0 && stat.Gid == 0
}
