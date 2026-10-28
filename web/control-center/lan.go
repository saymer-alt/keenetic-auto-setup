package main

// Ordinary HTTP on one Home bridge address. No built-in TLS or mandatory login.
import (
 "crypto/sha256"
 "crypto/subtle"
 "errors"
 "fmt"
 "net"
 "net/http"
 "net/netip"
 "net/url"
 "os"
 "strings"
 "sync/atomic"
)

type homeLAN struct {
 address string
 clients netip.Prefix
 homeOnly atomic.Bool
 accessPath string
 passwordDigest [32]byte
 passwordEnabled bool
}

func homeIPv4(iface string)(netip.Addr,netip.Prefix,error){
 if iface!="br0" {return netip.Addr{},netip.Prefix{},errors.New("automatic Home LAN requires br0")}
 n,err:=net.InterfaceByName(iface)
 if err!=nil {return netip.Addr{},netip.Prefix{},errors.New("home bridge unavailable")}
 if n.Flags&net.FlagUp==0 {return netip.Addr{},netip.Prefix{},errors.New("home bridge down")}
 addrs,err:=n.Addrs()
 if err!=nil {return netip.Addr{},netip.Prefix{},errors.New("cannot inspect Home addresses")}
 var ip netip.Addr
 var prefix netip.Prefix
 for _,a:=range addrs{
  v,ok:=a.(*net.IPNet)
  if !ok||v.IP.To4()==nil{continue}
  addr,ok:=netip.AddrFromSlice(v.IP.To4())
  if !ok||!addr.IsPrivate()||addr.IsLoopback(){continue}
  ones,bits:=v.Mask.Size()
  if bits!=32||ones<8||ones>30{continue}
  if ip.IsValid(){return netip.Addr{},netip.Prefix{},errors.New("ambiguous Home IPv4")}
  ip=addr
  prefix=netip.PrefixFrom(addr,ones).Masked()
 }
 if !ip.IsValid(){return netip.Addr{},netip.Prefix{},errors.New("no private Home IPv4 on br0")}
 return ip,prefix,nil
}

func newHomeLAN(bind,iface,passwordFile string)(*homeLAN,error){
 ip,prefix,err:=homeIPv4(iface)
 if err!=nil{return nil,err}
 address:=net.JoinHostPort(ip.String(),"18081")
 if bind!=""&&bind!="auto"{
  host,port,e:=net.SplitHostPort(bind)
  if e!=nil||port==""||port=="0"||host!=ip.String(){
   return nil,errors.New("LAN listener must match actual Home bridge IPv4")
  }
  address=bind
 }
 p:=&homeLAN{address:address,clients:prefix}
 if err:=p.loadOptionalPassword(passwordFile);err!=nil{return nil,err}
 return p,nil
}

func (p *homeLAN)loadOptionalPassword(passwordFile string)error{
 if passwordFile=="" {return nil}
 st,e:=os.Lstat(passwordFile)
 if e!=nil{return errors.New("password file unavailable")}
 if !st.Mode().IsRegular()||st.Mode().Perm()&0077!=0||st.Size()<1||st.Size()>256{
  return errors.New("password file must be private regular file")
 }
 raw,e:=os.ReadFile(passwordFile)
 if e!=nil{return e}
 password:=strings.TrimSpace(string(raw))
 if len(password)<12||len(password)>128||strings.ContainsAny(password,"\r\n:"){
  return errors.New("password must have 12-128 characters, no colon or newline")
 }
 p.passwordDigest=sha256.Sum256([]byte(password))
 p.passwordEnabled=true
 return nil
}

func (p *homeLAN) allowed(w http.ResponseWriter,r *http.Request,proxyHost string)bool{
 host,_,err:=net.SplitHostPort(r.RemoteAddr)
 if err!=nil{http.Error(w,"forbidden",http.StatusForbidden);return false}
 client,err:=netip.ParseAddr(host)
 if err!=nil{http.Error(w,"forbidden",http.StatusForbidden);return false}
 client=client.Unmap()
 // KeenDNS authentication happens in the ROUTER, before forwarding.
 // Accept this trust boundary only from an explicitly configured proxy Host
 // and a router-local TCP peer (loopback or the router's own Home IPv4).
 // A Home client can forge Host/Origin, but not the TCP peer's source IP.
 ownHost,_,ownErr:=net.SplitHostPort(p.address)
 ownIP,ipErr:=netip.ParseAddr(ownHost)
 routerProxy:=(proxyHost!="" && r.Host==proxyHost &&
     (client.IsLoopback() || (ownErr==nil && ipErr==nil && client==ownIP)))
 if p.homeOnly.Load() && !p.clients.Contains(client) && !routerProxy{
  http.Error(w,"forbidden",http.StatusForbidden);return false
 }
 // Password option covers direct LAN clients only; do not require a SECOND
 // account after the router has already authenticated a KeenDNS client.
 if p.passwordEnabled && !routerProxy{
  name,password,ok:=r.BasicAuth()
  received:=sha256.Sum256([]byte(password))
  if !ok||name!="kas"||subtle.ConstantTimeCompare(received[:],p.passwordDigest[:])!=1{
   w.Header().Set("WWW-Authenticate",`Basic realm="KAS Control Center"`)
   w.Header().Set("Cache-Control","no-store")
   http.Error(w,"authentication required",http.StatusUnauthorized)
   return false
  }
 }
 return true
}
func (p *homeLAN) describe()string{
 if p.passwordEnabled{return fmt.Sprintf("Home LAN HTTP %s; optional password enabled",p.address)}
 return fmt.Sprintf("Home-address HTTP %s; Home-only restriction=%t; no app password",p.address,p.homeOnly.Load())
}

func validateProxyOrigin(value string)(string,error){
 u,err:=url.Parse(value)
 if err!=nil||u.Scheme!="https"||u.Host==""||u.Hostname()==""||
   u.User!=nil||u.Path!=""||u.RawQuery!=""||u.Fragment!=""{
  return "",errors.New("proxy-origin must be a complete HTTPS origin without path, userinfo or query")
 }
 if strings.HasSuffix(u.Hostname(),".") || strings.Contains(u.Host,"@"){
  return "",errors.New("invalid proxy-origin hostname")
 }
 return u.Host,nil
}
