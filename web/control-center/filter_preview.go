package main

// Read-only Stage 1.5 of the filter editor. Never expose raw YAML to browsers.
// All actual writes must eventually be performed by canonical config-import.sh.
import (
 "context"
 "crypto/sha256"
 "encoding/hex"
 "encoding/json"
 "errors"
 "io"
 "net/http"
 "os"
 "strings"
 "time"
)
const filterConfigPath="/opt/etc/mihomo/config.yaml"
type filterEditRequest struct {
 Provider string `json:"provider"`
 Names []string `json:"names"`
 Clear bool `json:"clear"`
 SourceSHA string `json:"source_sha"`
}
type filterPreviewResponse struct{
 Provider string `json:"provider"`
 Existing string `json:"existing_filter"`
 Proposed string `json:"proposed_filter"`
 SourceSHA string `json:"source_sha"`
 CandidateSHA string `json:"candidate_sha"`
 SelectedCount int `json:"selected_count"`
 Applied bool `json:"applied"`
}
func readLocalFilterConfig()([]byte,error){
 st,err:=os.Lstat(filterConfigPath)
 if err!=nil||!st.Mode().IsRegular()||st.Size()<1||st.Size()>maxYAMLBytes{return nil,errFilterUnsupported}
 data,err:=os.ReadFile(filterConfigPath)
 if err!=nil{return nil,errFilterUnsupported}
 if len(data)==0||len(data)>maxYAMLBytes{return nil,errFilterUnsupported}
 return data,nil
}
func(a *app)filterConfig()([]byte,error){
 if a.filterConfigReader!=nil{return a.filterConfigReader()}
 return readLocalFilterConfig()
}
func writeFilterJSON(w http.ResponseWriter,code int,v any){
 w.Header().Set("Content-Type","application/json; charset=utf-8")
 w.Header().Set("Cache-Control","no-store")
 w.Header().Set("X-Content-Type-Options","nosniff")
 w.WriteHeader(code)
 _=json.NewEncoder(w).Encode(v)
}
func filterError(w http.ResponseWriter,code int,label string){
 writeFilterJSON(w,code,map[string]string{"error_code":label})
}
func(a *app)handleFilterInspect(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodGet{filterError(w,405,"METHOD_NOT_ALLOWED");return}
 if a.providers==nil{filterError(w,404,"EDITOR_DISABLED");return}
 content,err:=a.filterConfig()
 if err!=nil{filterError(w,503,"CONFIG_UNAVAILABLE");return}
 providers,err:=listFilterProviders(content)
 if err!=nil{filterError(w,422,"UNSUPPORTED_PROVIDER_YAML");return}
 writeFilterJSON(w,200,struct{
  SourceSHA string `json:"source_sha"`
  Providers []filterProvider `json:"providers"`
 }{filterSourceDigest(content),providers})
}
func(a *app)handleFilterPreview(w http.ResponseWriter,r *http.Request){
 if r.Method!=http.MethodPost{filterError(w,405,"METHOD_NOT_ALLOWED");return}
 if a.providers==nil{filterError(w,404,"EDITOR_DISABLED");return}
 if r.Host!=a.host && r.Host!=a.proxyHost{filterError(w,403,"REQUEST_BLOCKED");return}
 if r.Header.Get("Origin")!=a.expectedOrigin(r.Host)||
    r.Header.Get("Content-Type")!="application/json"||
    r.Header.Get("X-KAS-Confirm")!="preview"{
  filterError(w,403,"REQUEST_BLOCKED");return
 }
 if site:=r.Header.Get("Sec-Fetch-Site");site!=""&&site!="same-origin"{filterError(w,403,"REQUEST_BLOCKED");return}
 r.Body=http.MaxBytesReader(w,r.Body,256*1024)
 decoder:=json.NewDecoder(r.Body);decoder.DisallowUnknownFields()
 var request filterEditRequest
 if err:=decoder.Decode(&request);err!=nil{filterError(w,400,"INVALID_REQUEST");return}
 var extra any
 if err:=decoder.Decode(&extra);!errors.Is(err,io.EOF){filterError(w,400,"INVALID_REQUEST");return}
 if request.Provider==""||len(request.Provider)>256||len(request.SourceSHA)!=64||
   strings.Trim(request.SourceSHA,"0123456789abcdef")!="" {
  filterError(w,400,"INVALID_REQUEST");return
 }
 data,err:=a.filterConfig()
 if err!=nil{filterError(w,503,"CONFIG_UNAVAILABLE");return}
 digest:=filterSourceDigest(data)
 if digest!=request.SourceSHA{filterError(w,409,"CONFIG_CHANGED");return}
 if !request.Clear {
  // Do not accept node names invented by a browser or harvested from a
  // different provider: check the actual Mihomo runtime snapshot.
  ctx,cancel:=context.WithTimeout(r.Context(),7*time.Second);defer cancel()
  snapshot,err:=a.providers.snapshot(ctx)
  if err!=nil{filterError(w,502,"MIHOMO_UNAVAILABLE");return}
  var parsed struct{Providers map[string]struct{Proxies []struct{Name string `json:"name"`} `json:"proxies"`} `json:"providers"`}
  if json.Unmarshal(snapshot,&parsed)!=nil{filterError(w,502,"MIHOMO_RESPONSE_INVALID");return}
  entry,ok:=parsed.Providers[request.Provider]
  if !ok{filterError(w,422,"PROVIDER_NOT_LOADED");return}
  available:=map[string]bool{}
  for _,node:=range entry.Proxies{available[node.Name]=true}
  for _,name:=range request.Names{if !available[name]{filterError(w,422,"NODE_NOT_LOADED");return}}
 }
 candidate,existing,proposed,err:=patchProviderFilter(data,request.Provider,request.Names,request.Clear)
 if err!=nil{filterError(w,422,"UNSUPPORTED_OR_INVALID_FILTER");return}
 // Candidate YAML remains server-side and is immediately discarded here.
 sum:=sha256.Sum256(candidate)
 writeFilterJSON(w,200,filterPreviewResponse{
  Provider:request.Provider,Existing:existing,Proposed:proposed,
  SourceSHA:digest,CandidateSHA:hex.EncodeToString(sum[:]),
  SelectedCount:len(request.Names),Applied:false,
 })
}
