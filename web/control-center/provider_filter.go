package main

// Restricted, lossless YAML editor: unsupported provider shapes fail closed.
// Everything outside the requested exclude-filter line stays byte-for-byte.
import (
 "crypto/sha256"
 "encoding/hex"
 "encoding/json"
 "errors"
 "regexp"
 "strconv"
 "strings"
 "unicode/utf8"
)
var errFilterUnsupported=errors.New("UNSUPPORTED_PROVIDER_YAML")
var errFilterInvalid=errors.New("INVALID_FILTER_SELECTION")
var keyPattern=regexp.MustCompile(`^[A-Za-z0-9_.-]+$`)

type filterProvider struct{
 Name string `json:"name"`
 Existing string `json:"existing_filter"`
 HasFilter bool `json:"has_filter"`
 HTTP bool `json:"http"`
 begin int
 end int
 filterLine int
}
func filterKey(raw string)(string,bool){
 if keyPattern.MatchString(raw){return raw,true}
 if len(raw)>2 && raw[0]=='\'' && raw[len(raw)-1]=='\''{
  v:=strings.ReplaceAll(raw[1:len(raw)-1],"''","'")
  return v,v!=""
 }
 if len(raw)>2 && raw[0]=='"' && raw[len(raw)-1]=='"'{
  v,err:=strconv.Unquote(raw)
  return v,err==nil&&v!=""
 }
 return "",false
}
// Reject flow mappings, anchors/merge keys on edited providers, duplicated
// keys, multiline exclude-filter scalars and unknown indentation.
func scanFilterProviders(input []byte)([]string,[]filterProvider,error){
 if len(input)==0||len(input)>maxYAMLBytes||!utf8.Valid(input)||strings.ContainsAny(string(input),"\r\x00"){
  return nil,nil,errFilterUnsupported
 }
 lines:=strings.Split(string(input),"\n")
 sectionStart,sectionEnd:=-1,len(lines)
 for i,line:=range lines{
  if strings.HasPrefix(line,"\t"){return nil,nil,errFilterUnsupported}
  if strings.TrimSpace(line)==""||strings.HasPrefix(strings.TrimLeft(line," "),"#"){continue}
  if line=="proxy-providers:"||strings.HasPrefix(line,"proxy-providers: #"){
   if sectionStart>=0{return nil,nil,errFilterUnsupported}
   sectionStart=i
   continue
  }
  if sectionStart>=0&&sectionEnd==len(lines)&&i>sectionStart&&line[0]!=' '{sectionEnd=i}
 }
 if sectionStart<0||sectionEnd==sectionStart+1{return nil,nil,errFilterUnsupported}
 providers:=[]filterProvider{}
 names:=map[string]bool{}
 for i:=sectionStart+1;i<sectionEnd;i++{
  l:=lines[i];trimmed:=strings.TrimSpace(l)
  if trimmed==""||strings.HasPrefix(trimmed,"#"){continue}
  if strings.Contains(l,"\t"){return nil,nil,errFilterUnsupported}
  if strings.HasPrefix(l,"  ")&&!strings.HasPrefix(l,"   "){
   colon:=strings.Index(l,":")
   if colon<3{return nil,nil,errFilterUnsupported}
   rawName:=l[2:colon];rest:=strings.TrimSpace(l[colon+1:])
   if rest!=""&&!strings.HasPrefix(rest,"#"){return nil,nil,errFilterUnsupported}
   name,ok:=filterKey(rawName)
   if !ok||names[name]{return nil,nil,errFilterUnsupported}
   names[name]=true
   if len(providers)>0{providers[len(providers)-1].end=i}
   providers=append(providers,filterProvider{Name:name,begin:i,end:sectionEnd,filterLine:-1})
   continue
  }
  if len(providers)==0||!strings.HasPrefix(l,"    "){return nil,nil,errFilterUnsupported}
  p:=&providers[len(providers)-1]
  if strings.HasPrefix(l,"    <<:"){return nil,nil,errFilterUnsupported}
  if strings.HasPrefix(l,"    type:")&&!strings.HasPrefix(l,"     "){
   typ:=strings.TrimSpace(strings.TrimPrefix(l,"    type:"))
   if strings.HasPrefix(typ,"http #"){typ="http"}
   if typ=="http"||typ=="'http'"||typ==`"http"`{p.HTTP=true}
  }
  if strings.HasPrefix(l,"    exclude-filter:")&&!strings.HasPrefix(l,"     "){
   if p.filterLine>=0{return nil,nil,errFilterUnsupported}
   value:=strings.TrimSpace(strings.TrimPrefix(l,"    exclude-filter:"))
   if value=="|"||value==">"||strings.HasPrefix(value,"|")||strings.HasPrefix(value,">")||strings.HasPrefix(value,"*")||strings.HasPrefix(value,"!")||strings.HasPrefix(value,"&"){return nil,nil,errFilterUnsupported}
   p.filterLine=i;p.HasFilter=true;p.Existing=value
  }
 }
 if len(providers)==0{return nil,nil,errFilterUnsupported}
 return lines,providers,nil
}
func listFilterProviders(input []byte)([]filterProvider,error){
 _,data,err:=scanFilterProviders(input)
 return data,err
}
// One provider, exact matching names, never modify another field.
// The return value contains the full YAML for the canonical importer ONLY;
// callers must not return or log it through HTTP.
func patchProviderFilter(input []byte,provider string,selected []string,clear bool)([]byte,string,string,error){
 lines,ps,err:=scanFilterProviders(input)
 if err!=nil{return nil,"","",err}
 var p *filterProvider
 for i:=range ps{if ps[i].Name==provider{p=&ps[i];break}}
 if p==nil||!p.HTTP{return nil,"","",errFilterUnsupported}
 replacement:=""
 if !clear{
  if len(selected)==0||len(selected)>512{return nil,"","",errFilterInvalid}
  seen:=map[string]bool{};escaped:=make([]string,0,len(selected))
  for _,name:=range selected{
   if name==""||strings.TrimSpace(name)==""||len(name)>256||!utf8.ValidString(name)||seen[name]{return nil,"","",errFilterInvalid}
   seen[name]=true;escaped=append(escaped,regexp.QuoteMeta(name))
  }
  replacement="^(?:"+strings.Join(escaped,"|")+")$"
  if len(replacement)>8192{return nil,"","",errFilterInvalid}
  if _,err:=regexp.Compile(replacement);err!=nil{return nil,"","",errFilterInvalid}
 }
 old:=p.Existing
 if p.filterLine>=0{
  if clear{lines=append(lines[:p.filterLine],lines[p.filterLine+1:]...)}
  else{
   encoded,err:=json.Marshal(replacement)
   if err!=nil{return nil,"","",errFilterInvalid}
   lines[p.filterLine]="    exclude-filter: "+string(encoded)
  }
 }else if !clear{
  encoded,err:=json.Marshal(replacement)
  if err!=nil{return nil,"","",errFilterInvalid}
  i:=p.begin+1
  lines=append(lines[:i],append([]string{"    exclude-filter: "+string(encoded)},lines[i:]...)...)
 }
 output:=[]byte(strings.Join(lines,"\n"))
 if len(output)>maxYAMLBytes{return nil,"","",errFilterInvalid}
 return output,old,replacement,nil
}
func filterSourceDigest(data []byte)string{s:=sha256.Sum256(data);return hex.EncodeToString(s[:])}
