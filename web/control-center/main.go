// KAS Control Center: optional, loopback-only staged Status/Doctor/YAML prototype.
package main

import (
 "context"
 "embed"
 "encoding/json"
 "errors"
 "flag"
 "fmt"
 "io/fs"
 "log"
 "net"
 "net/http"
 "os"
 "os/exec"
 "os/signal"
 "regexp"
 "syscall"
 "strings"
 "sync"
 "time"
)

//go:generate sh -c "mkdir -p scripts && cp ../../mihomo-doctor.sh scripts/mihomo-doctor.sh && cp ../../config-import.sh scripts/config-import.sh"
//go:embed web/* scripts/mihomo-doctor.sh scripts/config-import.sh
var assets embed.FS

type apiResult struct {
 State string `json:"state"`
 Time string `json:"timestamp"`
 Source string `json:"source"`
 ExitCode *int `json:"exit_code,omitempty"`
 Details string `json:"details,omitempty"`
 ErrorCode string `json:"error_code,omitempty"`
 MihomoBinary bool `json:"mihomo_binary,omitempty"`
 MTBinary bool `json:"magitrickle_binary,omitempty"`
}
type app struct {
 host string
 proxyHost string
 proxyOrigin string
 lan *homeLAN
 doctor []byte
 importer []byte
 mu sync.Mutex
 running bool
 importRunning bool
 shuttingDown bool
 importResult importStatus
 last time.Time
 runDoctor func(context.Context, []byte)(string,int,error)
 runImport func([]byte,string)(int,error)
}
func newApp(host string, doctor []byte)*app { return &app{host:host, doctor:doctor, runDoctor:doctorCommand,runImport:importCommand} }
func validateBind(address string) error {
 host,port,err:=net.SplitHostPort(address)
 if err!=nil{return err}
 ip:=net.ParseIP(host)
 if ip==nil||!ip.IsLoopback(){return errors.New("stage 1 permits only literal loopback IPs")}
 if port==""||port=="0"{return errors.New("choose an explicit nonzero port")}
 return nil
}
func (a *app) expectedOrigin(host string)string {
 if host==a.host{return "http://"+a.host}
 if host==a.proxyHost && a.proxyOrigin!=""{return a.proxyOrigin}
 return ""
}
func now()string{return time.Now().UTC().Format(time.RFC3339)}
func fileExists(path string)bool{st,err:=os.Stat(path);return err==nil&&!st.IsDir()}
func (a *app)handleStatus(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodGet{http.Error(w,"method not allowed",http.StatusMethodNotAllowed);return}
 writeJSON(w,http.StatusOK,apiResult{
  State:"UNKNOWN",Time:now(),Source:"KAS filesystem evidence only; network health not tested",
  MihomoBinary:fileExists("/opt/bin/mihomo"),MTBinary:fileExists("/opt/bin/magitrickle"),
 })
}
func (a *app)handleDoctor(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodPost{http.Error(w,"method not allowed",http.StatusMethodNotAllowed);return}
 origin:=r.Header.Get("Origin")
 if origin!=a.expectedOrigin(r.Host)||r.Header.Get("Content-Type")!="application/json"{
  writeJSON(w,http.StatusForbidden,apiResult{State:"UNKNOWN",Time:now(),ErrorCode:"REQUEST_BLOCKED"});return
 }
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{
  writeJSON(w,http.StatusForbidden,apiResult{State:"UNKNOWN",Time:now(),ErrorCode:"REQUEST_BLOCKED"});return
 }
 r.Body=http.MaxBytesReader(w,r.Body,32)
 var body map[string]any
 if err:=json.NewDecoder(r.Body).Decode(&body);err!=nil||len(body)!=0{
  writeJSON(w,http.StatusBadRequest,apiResult{State:"UNKNOWN",Time:now(),ErrorCode:"INVALID_BODY"});return
 }
 a.mu.Lock()
 if a.running||a.importRunning||a.shuttingDown||time.Since(a.last)<5*time.Second{
  a.mu.Unlock()
  writeJSON(w,http.StatusTooManyRequests,apiResult{State:"UNKNOWN",Time:now(),ErrorCode:"BUSY"});return
 }
 a.running=true;a.last=time.Now();a.mu.Unlock()
 defer func(){a.mu.Lock();a.running=false;a.mu.Unlock()}()
 if len(a.doctor)==0{
  writeJSON(w,http.StatusServiceUnavailable,apiResult{State:"UNKNOWN",Time:now(),ErrorCode:"DOCTOR_UNAVAILABLE"});return
 }
 ctx,cancel:=context.WithTimeout(r.Context(),90*time.Second);defer cancel()
 output,exit,err:=a.runDoctor(ctx,a.doctor)
 result:=apiResult{State:"UNKNOWN",Time:now(),Source:"bundled mihomo-doctor.sh",ExitCode:&exit,Details:redact(output)}
 if err!=nil{
  result.ErrorCode="DOCTOR_FAILED"
  if errors.Is(ctx.Err(),context.DeadlineExceeded){result.ErrorCode="TIMEOUT"}
  writeJSON(w,http.StatusOK,result);return
 }
 // Exit code 0 proves only script completion, not full client route health.
 // Doctor exit 0 alone is not a machine-readable diagnostic verdict.
 result.State="UNKNOWN";writeJSON(w,http.StatusOK,result)
}
var secretLine=regexp.MustCompile(`(?i)(password|passwd|secret|token|authorization|api.key|private.key|subscription|://[^\s/]+:[^\s/@]+@)`)
func redact(s string)string{
 lines:=strings.Split(s,"\n")
 for i,line:=range lines{if secretLine.MatchString(line){lines[i]="[REDACTED]"}}
 return strings.Join(lines,"\n")
}
type capWriter struct{data []byte;limit int}
func (c *capWriter)Write(p []byte)(int,error){
 if len(c.data)<c.limit{n:=c.limit-len(c.data);if n>len(p){n=len(p)};c.data=append(c.data,p[:n]...)}
 return len(p),nil
}
func doctorCommand(ctx context.Context,script []byte)(string,int,error){
 cmd:=exec.CommandContext(ctx,"sh","-s")
 cmd.Stdin=strings.NewReader(string(script))
 cmd.WaitDelay=2*time.Second
 w:=&capWriter{limit:128*1024};cmd.Stdout=w;cmd.Stderr=w
 err:=cmd.Run();exit:=0
 if err!=nil{exit=-1;var e *exec.ExitError;if errors.As(err,&e){exit=e.ExitCode()}}
 out:=string(w.data);if len(w.data)==w.limit{out+="\n[OUTPUT TRUNCATED]"}
 return out,exit,err
}
func writeJSON(w http.ResponseWriter,code int,v apiResult){
 w.Header().Set("Content-Type","application/json; charset=utf-8")
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("X-Content-Type-Options","nosniff")
 w.WriteHeader(code);_=json.NewEncoder(w).Encode(v)
}
func (a *app)handler()http.Handler{
 sub,err:=fs.Sub(assets,"web");if err!=nil{panic(err)}
 mux:=http.NewServeMux()
 mux.Handle("/",http.FileServer(http.FS(sub)))
 mux.HandleFunc("/api/status",a.handleStatus)
 mux.HandleFunc("/api/doctor",a.handleDoctor)
 mux.HandleFunc("/api/config/import",a.handleImport)
 mux.HandleFunc("/api/config/operation",a.handleImportStatus)
 return http.HandlerFunc(func(w http.ResponseWriter,r *http.Request){
  if r.Host!=a.host && (a.proxyHost==""||r.Host!=a.proxyHost){http.Error(w,"invalid host",http.StatusForbidden);return}
  if a.lan!=nil && !a.lan.allowed(w,r,a.proxyHost){return}
  w.Header().Set("X-Frame-Options","DENY")
  w.Header().Set("X-Content-Type-Options","nosniff")
  w.Header().Set("Content-Security-Policy","default-src 'self'; script-src 'self'; style-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
  mux.ServeHTTP(w,r)
 })
}
func main(){
 listen:=flag.String("listen","","IP:port; default loopback without -lan, Home br0 with -lan")
 lanMode:=flag.Bool("lan",false,"listen on private Home br0 IPv4, HTTP, no password by default")
 lanInterface:=flag.String("lan-interface","br0","Home LAN bridge (currently br0 only)")
 passwordFile:=flag.String("password-file","","optional private file with KAS panel password")
 proxyOrigin:=flag.String("proxy-origin","","optional existing KeenDNS HTTPS URL allowed via router reverse proxy")
 flag.Parse()
 var lan *homeLAN
 if *lanMode {
  var err error
  lan,err=newHomeLAN(*listen,*lanInterface,*passwordFile)
  if err!=nil{log.Fatal(err)}
  *listen=lan.address
 }else{
  if *passwordFile!=""||*proxyOrigin!=""{log.Fatal("password-file and proxy-origin require -lan")}
  if *listen==""{*listen="127.0.0.1:18081"}
  if err:=validateBind(*listen);err!=nil{log.Fatal(err)}
 }
 script,err:=assets.ReadFile("scripts/mihomo-doctor.sh");if err!=nil{log.Fatal(err)}
 importer,err:=assets.ReadFile("scripts/config-import.sh");if err!=nil{log.Fatal(err)}
 app:=newApp(*listen,script)
 app.importer=importer
 app.lan=lan
 if *proxyOrigin!=""{
  host,err:=validateProxyOrigin(*proxyOrigin)
  if err!=nil{log.Fatal(err)}
  app.proxyOrigin=*proxyOrigin
  app.proxyHost=host
 }
 srv:=&http.Server{Addr:*listen,Handler:app.handler(),ReadHeaderTimeout:5*time.Second,ReadTimeout:10*time.Second,WriteTimeout:100*time.Second,IdleTimeout:30*time.Second,MaxHeaderBytes:8192}
 if lan!=nil {fmt.Println(lan.describe())}else{fmt.Printf("KAS staged prototype (loopback only): http://%s\n",*listen)}
 runErrors:=make(chan error,1)
 go func(){runErrors<-srv.ListenAndServe()}()
 signals:=make(chan os.Signal,1)
 signal.Notify(signals,os.Interrupt,syscall.SIGTERM)
 select {
 case err:=<-runErrors:
  if err!=nil && !errors.Is(err,http.ErrServerClosed){log.Fatal(err)}
  return
 case <-signals:
 }
 // Never interrupt canonical config-import.sh halfway through its atomic
 // replace/rollback. Stop accepting NEW mutating requests and drain workers.
 app.mu.Lock();app.shuttingDown=true;app.mu.Unlock()
 for {
  app.mu.Lock();busy:=app.importRunning||app.running;app.mu.Unlock()
  if !busy{break}
  time.Sleep(250*time.Millisecond)
 }
 ctx,cancel:=context.WithTimeout(context.Background(),5*time.Second)
 defer cancel()
 if err:=srv.Shutdown(ctx);err!=nil{log.Printf("shutdown error: %v",err)}

}
