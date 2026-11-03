package main

// The router owns WAN firewall and KeenDNS authentication policy. The Web
// process accepts IP-literal direct origins on its selected port and recognizes
// the router's local HTTP reverse proxy without per-domain configuration.
import (
 "net"
 "net/http"
 "net/url"
 "strings"
)

func (a *app) routerLocalPeer(r *http.Request) bool {
 if a.lan==nil { return false }
 host,_,err:=net.SplitHostPort(r.RemoteAddr)
 if err!=nil { return false }
 ip:=net.ParseIP(host)
 if ip==nil { return false }
 if ip.IsLoopback(){ return true }
 if a.lan.homeIP.IsValid() && ip.String()==a.lan.homeIP.String(){ return true }
 homeHost,_,err:=net.SplitHostPort(a.lan.address)
 return err==nil && ip.String()==homeHost
}

func validProxyDomain(host string) bool {
 if len(host)<3||len(host)>253||!strings.Contains(host,".")||strings.HasSuffix(host,"."){return false}
 for _,label:=range strings.Split(host,"."){
  if len(label)<1||len(label)>63||label[0]=='-'||label[len(label)-1]=='-' { return false }
  for i:=0;i<len(label);i++ {
   c:=label[i]
   if !(c>='a'&&c<='z'||c>='A'&&c<='Z'||c>='0'&&c<='9'||c=='-'){return false}
  }
 }
 return true
}

func (a *app) automaticProxyHost(r *http.Request) bool {
 if !a.routerLocalPeer(r){return false}
 // KeenDNS forwards the public hostname, or rewrites it to the local upstream.
 // The latter is already allowed through directHost (127.0.0.1:port).
 return validProxyDomain(r.Host)
}

func (a *app) requestOriginAllowed(r *http.Request) bool {
 origin:=r.Header.Get("Origin")
 if origin!="" && origin==a.expectedOrigin(r.Host){return true}
 // A router-local KeenDNS reverse proxy can forward, rewrite, or omit Origin.
 // External clients must always send the exact direct origin. Mutating API
 // handlers still demand non-simple X-KAS-Confirm headers and check Fetch-Site.
 if !a.routerLocalPeer(r){return false}
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{return false}
 if origin=="" {return true}
 u,err:=url.Parse(origin)
 if err!=nil||u.Scheme!="https"||u.Host==""||u.User!=nil||u.Path!=""||u.RawQuery!=""||u.Fragment!=""||!validProxyDomain(u.Hostname()){return false}
 if a.automaticProxyHost(r) && strings.EqualFold(r.Host,u.Host){return true}
 // Standard KeenDNS rules use the loopback upstream, and may rewrite Host.
 if a.directHost(r.Host){
  host,_,err:=net.SplitHostPort(r.Host)
  if err==nil {
   ip:=net.ParseIP(host)
   if ip!=nil&&(ip.IsLoopback()||a.lan.homeIP.IsValid()&&ip.String()==a.lan.homeIP.String()){return true}
  }
 }
 return false
}
