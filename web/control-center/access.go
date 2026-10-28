package main

// Owner policy: source-subnet restriction is optional and off by default.
// The listener still binds only the router's Home IPv4. Routing/firewall and
// optional password remain independent of this source-address setting.
import (
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "os"
 "path/filepath"
)

const homeOnlyConfigPath="/opt/etc/kas-control-center.home-only"

func readHomeOnly(path string)(bool,error){
 st,err:=os.Lstat(path)
 if os.IsNotExist(err){return false,nil}
 if err!=nil{return false,err}
 if !st.Mode().IsRegular()||st.Mode().Perm()&0077!=0||st.Size()<1||st.Size()>2{return false,errors.New("invalid private Home-only flag")}
 data,err:=os.ReadFile(path)
 if err!=nil{return false,err}
 if string(data)!="1"&&string(data)!="1\n"{return false,errors.New("invalid Home-only flag contents")}
 return true,nil
}
func(p *homeLAN)loadAccessPolicy(path string)error{
 value,err:=readHomeOnly(path)
 if err!=nil{return err}
 p.accessPath=path
 p.homeOnly.Store(value)
 return nil
}
// Called under the app mutation mutex. Persist first; a failed filesystem
// operation must never change the live policy. Only this one fixed setting
// is written; no client-supplied paths, network rules or Mihomo changes.
func(p *homeLAN)saveAccessPolicy(value bool)error{
 if p.accessPath==""{return errors.New("access policy persistence unavailable")}
 if _,err:=readHomeOnly(p.accessPath);err!=nil{return err}
 if value{
  f,err:=os.CreateTemp(filepath.Dir(p.accessPath),".kas-home-only-*")
  if err!=nil{return err}
  defer os.Remove(f.Name())
  if _,err=f.WriteString("1\n");err!=nil{_ = f.Close();return err}
  if err=f.Close();err!=nil{return err}
  if err=os.Rename(f.Name(),p.accessPath);err!=nil{return err}
 }else{
  if err:=os.Remove(p.accessPath);err!=nil&&!os.IsNotExist(err){return err}
 }
 p.homeOnly.Store(value)
 return nil
}
func(a *app)handleAccess(w http.ResponseWriter,r *http.Request){
 if a.lan==nil{filterError(w,404,"LAN_MODE_REQUIRED");return}
 respond:=func(){writeFilterJSON(w,200,struct{HomeOnly bool `json:"home_only"`}{a.lan.homeOnly.Load()})}
 if r.Method==http.MethodGet{respond();return}
 if r.Method!=http.MethodPost{filterError(w,405,"METHOD_NOT_ALLOWED");return}
 if r.Header.Get("Origin")!=a.expectedOrigin(r.Host)||r.Header.Get("Content-Type")!="application/json"||r.Header.Get("X-KAS-Confirm")!="access"{
  filterError(w,403,"REQUEST_BLOCKED");return
 }
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{filterError(w,403,"REQUEST_BLOCKED");return}
 r.Body=http.MaxBytesReader(w,r.Body,64)
 decoder:=json.NewDecoder(r.Body);decoder.DisallowUnknownFields()
 var request struct{HomeOnly *bool `json:"home_only"`}
 if err:=decoder.Decode(&request);err!=nil||request.HomeOnly==nil{filterError(w,400,"INVALID_REQUEST");return}
 var extra any
 if err:=decoder.Decode(&extra);!errors.Is(err,io.EOF){filterError(w,400,"INVALID_REQUEST");return}
 a.mu.Lock()
 defer a.mu.Unlock()
 if a.running||a.importRunning||a.shuttingDown{filterError(w,409,"BUSY");return}
 if err:=a.lan.saveAccessPolicy(*request.HomeOnly);err!=nil{filterError(w,503,"ACCESS_SAVE_FAILED");return}
 respond()
}
