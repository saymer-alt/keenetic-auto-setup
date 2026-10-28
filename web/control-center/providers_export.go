package main

// Explicit, bounded, read-only export of Mihomo provider/node names.
// The router is NOT an arbitrary HTTP proxy for a browser or a subscription URL.
import (
 "context"
 "encoding/json"
 "errors"
 "io"
 "net"
 "net/http"
 "net/netip"
 "os"
 "strings"
 "time"
)

var (
 errNamesUnavailable=errors.New("MIHOMO_UNAVAILABLE")
 errNamesAuth=errors.New("MIHOMO_AUTH_REQUIRED")
 errNamesResponse=errors.New("MIHOMO_RESPONSE_INVALID")
)

const maxNamesSourceBytes=4*1024*1024
const maxNamesOutputBytes=1024*1024

type providerNamesExporter struct {
 sources []string
 secret string
 client *http.Client
}

func newProviderNamesExporter(panelAddress,secretFile string)(*providerNamesExporter,error){
 host,_,err:=net.SplitHostPort(panelAddress)
 if err!=nil{return nil,errNamesResponse}
 ip,err:=netip.ParseAddr(host)
 if err!=nil || !(ip.IsPrivate()||ip.IsLoopback()) {return nil,errNamesResponse}
 sources:=[]string{"http://127.0.0.1:9090/providers/proxies"}
 if !ip.IsLoopback(){
  sources=append(sources,"http://"+net.JoinHostPort(ip.String(),"9090")+"/providers/proxies")
 }
 var secret string
 if secretFile!=""{
  st,err:=os.Lstat(secretFile)
  if err!=nil||!st.Mode().IsRegular()||st.Mode().Perm()&0077!=0||st.Size()<1||st.Size()>256{return nil,errors.New("Mihomo API secret must be a private regular file")}
  raw,err:=os.ReadFile(secretFile)
  if err!=nil{return nil,err}
  secret=strings.TrimSpace(string(raw))
  if secret==""||strings.ContainsAny(secret,"\r\n\x00") {return nil,errors.New("invalid Mihomo API secret file")}
 }
 client:=&http.Client{
  Timeout:5*time.Second,
  Transport:&http.Transport{
   Proxy:nil,
   DialContext:(&net.Dialer{Timeout:2*time.Second}).DialContext,
   DisableKeepAlives:true,
  },
  CheckRedirect:func(*http.Request,[]*http.Request)error{return http.ErrUseLastResponse},
 }
 return &providerNamesExporter{sources:sources,secret:secret,client:client},nil
}

func (p *providerNamesExporter)snapshot(ctx context.Context)([]byte,error){
 for _,target:=range p.sources{
  req,err:=http.NewRequestWithContext(ctx,http.MethodGet,target,nil)
  if err!=nil{return nil,errNamesResponse}
  if p.secret!=""{req.Header.Set("Authorization","Bearer "+p.secret)}
  resp,err:=p.client.Do(req)
  if err!=nil{continue} // Only try the other router-owned listener on transport failure.
  body,err:=io.ReadAll(io.LimitReader(resp.Body,maxNamesSourceBytes+1))
  _=resp.Body.Close()
  if err!=nil{return nil,errNamesUnavailable}
  if resp.StatusCode==http.StatusUnauthorized||resp.StatusCode==http.StatusForbidden{return nil,errNamesAuth}
  if resp.StatusCode!=http.StatusOK{return nil,errNamesUnavailable}
  if len(body)>maxNamesSourceBytes{return nil,errNamesResponse}
  return sanitizeProviderNames(body)
 }
 return nil,errNamesUnavailable
}

func sanitizeProviderNames(raw []byte)([]byte,error){
 var doc struct {
  Providers map[string]json.RawMessage `json:"providers"`
 }
 if err:=json.Unmarshal(raw,&doc);err!=nil || doc.Providers==nil ||len(doc.Providers)>256 {
  return nil,errNamesResponse
 }
 type safeNode struct{Name string `json:"name"`}
 type safeProvider struct{
  VehicleType string `json:"vehicleType,omitempty"`
  Proxies []safeNode `json:"proxies"`
 }
 out:=struct{
  Providers map[string]safeProvider `json:"providers"`
 }{Providers:make(map[string]safeProvider,len(doc.Providers))}
 total:=0
 for name,rawProvider:=range doc.Providers{
  if len(name)==0||len(name)>256||strings.TrimSpace(name)=="" {return nil,errNamesResponse}
  var provider struct{
   VehicleType string `json:"vehicleType"`
   Proxies []struct{Name string `json:"name"`} `json:"proxies"`
  }
  if err:=json.Unmarshal(rawProvider,&provider);err!=nil{return nil,errNamesResponse}
  if len(provider.VehicleType)>32{return nil,errNamesResponse}
  nodes:=make([]safeNode,0,len(provider.Proxies))
  for _,node:=range provider.Proxies{
   if len(node.Name)==0||len(node.Name)>256||strings.TrimSpace(node.Name)==""{continue}
   total++
   if total>10000{return nil,errNamesResponse}
   nodes=append(nodes,safeNode{Name:node.Name})
  }
  out.Providers[name]=safeProvider{VehicleType:provider.VehicleType,Proxies:nodes}
 }
 result,err:=json.Marshal(out)
 if err!=nil||len(result)>maxNamesOutputBytes{return nil,errNamesResponse}
 return result,nil
}

func(a *app)handleProviderNames(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodGet{http.Error(w,"method not allowed",http.StatusMethodNotAllowed);return}
 if a.providers==nil{writeJSON(w,http.StatusNotFound,apiResult{State:"UNKNOWN",ErrorCode:"EXPORT_DISABLED"});return}
 ctx,cancel:=context.WithTimeout(r.Context(),7*time.Second)
 defer cancel()
 body,err:=a.providers.snapshot(ctx)
 if err!=nil{
  code:=http.StatusBadGateway
  reason:="MIHOMO_UNAVAILABLE"
  if errors.Is(err,errNamesAuth){code=http.StatusBadGateway;reason="MIHOMO_AUTH_REQUIRED"}
  if errors.Is(err,errNamesResponse){reason="MIHOMO_RESPONSE_INVALID"}
  writeJSON(w,code,apiResult{State:"UNKNOWN",ErrorCode:reason});return
 }
 w.Header().Set("Content-Type","application/json; charset=utf-8")
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("X-Content-Type-Options","nosniff")
 w.Header().Set("Content-Disposition",`attachment; filename="mihomo-providers-names.json"`)
 w.WriteHeader(http.StatusOK)
 _,_=w.Write(body)
}
