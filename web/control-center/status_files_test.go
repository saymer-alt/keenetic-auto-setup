package main

import (
 "os"
 "path/filepath"
 "testing"
)

func TestComponentFilesDetectsInstalledMagiTrickled(t *testing.T){
 root:=t.TempDir()
 if err:=os.MkdirAll(filepath.Join(root,"bin"),0700);err!=nil{t.Fatal(err)}
 // Actual package path from the KN-1010 field transcript (opkg files).
 if err:=os.WriteFile(filepath.Join(root,"bin","magitrickled"),[]byte("fixture"),0600);err!=nil{t.Fatal(err)}
 mihomo,mt:=componentFiles(root)
 if mihomo||!mt{t.Fatal("installed magitrickled not detected",mihomo,mt)}
}
func TestComponentFilesSupportsMihomoSbinAndLegacyMT(t *testing.T){
 root:=t.TempDir()
 for _,dir:=range []string{"bin","sbin"}{if err:=os.MkdirAll(filepath.Join(root,dir),0700);err!=nil{t.Fatal(err)}}
 if err:=os.WriteFile(filepath.Join(root,"sbin","mihomo"),[]byte("fixture"),0600);err!=nil{t.Fatal(err)}
 if err:=os.WriteFile(filepath.Join(root,"bin","magitrickle"),[]byte("fixture"),0600);err!=nil{t.Fatal(err)}
 mihomo,mt:=componentFiles(root)
 if !mihomo||!mt{t.Fatal("existing compatible paths not detected",mihomo,mt)}
}
