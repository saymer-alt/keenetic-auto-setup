//go:build !linux

package main

import "os"

// Router inventory is supported on Linux; other development hosts fail closed.
func inventoryOwned(info os.FileInfo) bool { return false }
