package main

// LAN mode is strictly opt-in and requires HTTPS, a 256-bit random secret,
// an explicit interface, RFC1918 client CIDR and SO_BINDTODEVICE (Linux).
import (
 "context"
 "crypto/sha256"
 "crypto/subtle"
 "errors"
 "fmt"
 "net"
 "net/http"
 "net/netip"
 "os"
 "strings"
 "syscall"
)

type lanPolicy struct {
 interfaceName string
 clients netip.Prefix
 tokenDigest [32]byte
}

func privatePrefix(p netip.Prefix) bool {
 if !p.IsValid() || !p.Addr().Is4() {return false}
 p=p.Masked()
 for _,s:=range []string{"10.0.0.0/8","172.16.0.0/12","192.168.0.0/16"} {
  block:=netip.MustParsePrefix(s)
  if block.Contains(p.Addr()) && p.Bits()>=block.Bits(){return true}
 }
 return false
}

func checkLANAddress(address,iface,clients string) (netip.Prefix,error) {
 host,port,err:=net.SplitHostPort(address)
 if err!=nil || port=="" || port=="0" {return netip.Prefix{},errors.New("explicit LAN IPv4 and port required")}
 ip,err:=netip.ParseAddr(host)
 if err!=nil || !ip.Is4() || !ip.IsPrivate() {return netip.Prefix{},errors.New("LAN listener must be a private IPv4 literal")}
 if strings.TrimSpace(iface)=="" || strings.TrimSpace(clients)=="" {
  return netip.Prefix{},errors.New("LAN device and trusted client CIDR are required")
 }
 p,err:=netip.ParsePrefix(clients)
 if err!=nil || !privatePrefix(p) || !p.Contains(ip) {
  return netip.Prefix{},errors.New("trusted client subnet must contain LAN address and stay RFC1918")
 }
 n,err:=net.InterfaceByName(iface)
 if err!=nil || n.Flags&net.FlagUp==0 {return netip.Prefix{},errors.New("named LAN interface is not up")}
 addrs,err:=n.Addrs()
 if err!=nil {return netip.Prefix{},errors.New("cannot inspect LAN interface addresses")}
 found:=false
 for _,a:=range addrs {
  var raw net.IP
  switch v:=a.(type) {case *net.IPNet:raw=v.IP;case *net.IPAddr:raw=v.IP}
  if raw!=nil && raw.Equal(net.IP(ip.AsSlice())) {found=true;break}
 }
 if !found {return netip.Prefix{},errors.New("requested LAN IPv4 is not assigned to selected device")}
 return p.Masked(),nil
}

func checkedPrivateFile(path string, requireSecret bool)([]byte,error) {
 if path=="" {return nil,errors.New("missing private file")}
 st,err:=os.Lstat(path)
 if err!=nil {return nil,err}
 if !st.Mode().IsRegular() || st.Mode().Perm()&0077!=0 {
  return nil,errors.New("private file must be regular and inaccessible to group/others")
 }
 if raw,ok:=st.Sys().(*syscall.Stat_t);ok && raw.Uid!=uint32(os.Geteuid()){
  return nil,errors.New("private file must be owned by service user")
 }
 if requireSecret && st.Size()>128 {return nil,errors.New("auth secret file too large")}
 return os.ReadFile(path)
}

func loadLANPolicy(address,iface,clients,secretFile,certFile,keyFile string)(*lanPolicy,error) {
 p,err:=checkLANAddress(address,iface,clients)
 if err!=nil{return nil,err}
 value,err:=checkedPrivateFile(secretFile,true)
 if err!=nil{return nil,fmt.Errorf("LAN auth file: %w",err)}
 secret:=strings.TrimSpace(string(value))
 if len(secret)!=43 {return nil,errors.New("LAN secret must be 32-byte base64url token")}
 for _,ch:=range secret{
  if !(ch>='a'&&ch<='z'||ch>='A'&&ch<='Z'||ch>='0'&&ch<='9'||ch=='_'||ch=='-'){
   return nil,errors.New("invalid LAN secret encoding")
  }
 }
 if _,err=checkedPrivateFile(keyFile,false);err!=nil{return nil,fmt.Errorf("TLS key: %w",err)}
 certInfo,err:=os.Lstat(certFile)
 if err!=nil || !certInfo.Mode().IsRegular(){return nil,errors.New("TLS cert missing or unsafe")}
 return &lanPolicy{interfaceName:iface,clients:p,tokenDigest:sha256.Sum256([]byte(secret))},nil
}

func (p *lanPolicy) allowed(w http.ResponseWriter,r *http.Request)bool {
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("Referrer-Policy","no-referrer")
 if r.TLS==nil {http.Error(w,"HTTPS required",http.StatusForbidden);return false}
 host,_,err:=net.SplitHostPort(r.RemoteAddr)
 if err!=nil {http.Error(w,"client not allowed",http.StatusForbidden);return false}
 ip,err:=netip.ParseAddr(host)
 if err!=nil || !p.clients.Contains(ip.Unmap()) {
  http.Error(w,"client not allowed",http.StatusForbidden);return false
 }
 user,secret,ok:=r.BasicAuth()
 received:=sha256.Sum256([]byte(secret))
 if !ok || user!="kas" || subtle.ConstantTimeCompare(received[:],p.tokenDigest[:])!=1{
  w.Header().Set("WWW-Authenticate","Basic realm=\"KAS Control Center\"")
  http.Error(w,"authentication required",http.StatusUnauthorized)
  return false
 }
 return true
}

func listenLAN(address string,p *lanPolicy)(net.Listener,error) {
 // Linux device binding must succeed. Never silently fall back to LAN socket
 // that can accept packets entering through a private-address WAN.
 conf:=net.ListenConfig{Control:func(_, _ string, raw syscall.RawConn)error{
  var sockerr error
  err:=raw.Control(func(fd uintptr) {
   sockerr=syscall.SetsockoptString(int(fd),syscall.SOL_SOCKET,syscall.SO_BINDTODEVICE,p.interfaceName)
  })
  if err!=nil{return err}
  return sockerr
 }}
 return conf.Listen(context.Background(),"tcp4",address)
}
