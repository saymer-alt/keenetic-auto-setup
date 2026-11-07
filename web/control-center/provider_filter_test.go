package main
import("bytes";"strings";"testing")
const inputFilterFixture=`mixed-port: 7890
secret: "SENSITIVE_NOT_TO_LEAK"
proxy-providers:
  Provider-One:
    type: http
    url: "https://private.invalid/sub?token=SECRET"
    interval: 3600
  Provider-Two:
    type: http
    exclude-filter: "(?i)russia"
    url: https://private.invalid/second
proxy-groups:
  - name: MAIN
    type: select
    proxies: [DIRECT]
`
func TestFilterPatchIsTargetedAndReversible(t *testing.T){
 got,old,newValue,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-One",[]string{"🇷🇺 Moscow","DE+Berlin"},false)
 if err!=nil{t.Fatal(err)}
 if old!=""||newValue!=`^(?:🇷🇺 Moscow|DE\+Berlin)$`{t.Fatalf("old %q new %q",old,newValue)}
 if !bytes.Contains(got,[]byte(`exclude-filter: "^(?:🇷🇺 Moscow|DE\\+Berlin)$"`)){t.Fatal(string(got))}
 if !strings.Contains(string(got),"SENSITIVE_NOT_TO_LEAK")||!strings.Contains(string(got),`exclude-filter: "(?i)russia"`){t.Fatal("unrelated data changed")}
 clear,_,_,err:=patchProviderFilter(got,"Provider-One",nil,true)
 if err!=nil{t.Fatal(err)}
 if !bytes.Equal(clear,[]byte(inputFilterFixture)){t.Fatal("not byte-for-byte restored")}
}
func TestFilterReplaceExistingAndUnrelatedUnchanged(t *testing.T){
 got,old,_,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-Two",[]string{"Node A"},false)
 if err!=nil{t.Fatal(err)}
 if old!=`"(?i)russia"`{t.Fatal(old)}
 if !strings.Contains(string(got),`url: "https://private.invalid/sub?token=SECRET"`){t.Fatal("other provider lost")}
 if !strings.Contains(string(got),`exclude-filter: "^(?:Node A)$"`){t.Fatal("replacement missing")}
}
func TestFilterFailClosedComplexAndInvalid(t *testing.T){
 cases:=[]string{"proxy-providers:\n  P: {type: http}\n","proxy-providers:\n  P: &alias\n    type: http\n","proxy-providers:\n  P:\n    type: http\n    exclude-filter: |\n      hello\n","proxy-providers:\n  P:\n    type: http\n    exclude-filter: x\n    exclude-filter: y\n","proxy-providers:\n  P:\n    <<: *common\n    type: http\n","proxy-providers:\n  P:\n    << : *common\n    type: http\n","proxy-providers:\n  P:\n    type: file\n"}
 for i,s:=range cases{if _,_,_,err:=patchProviderFilter([]byte(s),"P",[]string{"X"},false);err==nil{t.Fatalf("accepted case %d",i)}}
 // FIELD #428: valid-looking but ambiguous or dangerous plain key shapes
 // must keep failing closed at discovery, before any patch is possible.
 unsupported:=[]string{
  "proxy-providers:\n  RZ Gist:\n    type: http\n  RZ Gist:\n    type: http\n",
  "proxy-providers:\n  RZ Gist:\n    type: http\n  RZ Gist :\n    type: http\n",
  "proxy-providers:\n  &a RZ Gist:\n    type: http\n",
  "proxy-providers:\n  *alias:\n    type: http\n",
  "proxy-providers:\n  !!str RZ Gist:\n    type: http\n",
  "proxy-providers:\n  RZ #Gist:\n    type: http\n",
  "proxy-providers:\n  RZ:Gist:\n    type: http\n",
  "proxy-providers:\n  RZ Gist: &a\n    type: http\n",
  "proxy-providers:\n  {RZ Gist}:\n    type: http\n",
  "proxy-providers:\n  [RZ Gist]:\n    type: http\n",
  "proxy-providers:\n  - RZ Gist:\n    type: http\n",
  "proxy-providers:\n  RZ Gist:\n    type: http\n   RZ Two:\n    type: http\n",
  "proxy-providers:\n  RZ\tGist:\n    type: http\n"}
 for i,s:=range unsupported{if _,err:=listFilterProviders([]byte(s));err==nil{t.Fatalf("accepted unsupported case %d: %q",i,s)}}
 if _,_,_,err:=patchProviderFilter([]byte("proxy-providers:\n  RZ Gist:\n      type: http\n"),"RZ Gist",[]string{"X"},false);err==nil{t.Fatal("accepted unknown attribute indentation")}
 for _,names:=range [][]string{nil,{},{"dup","dup"},{""}}{if _,_,_,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-One",names,false);err==nil{t.Fatalf("bad names %v",names)}}
}
func TestFilterNoOpsAndSourceDigest(t *testing.T){
 got,_,_,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-One",nil,true)
 if err!=nil||!bytes.Equal(got,[]byte(inputFilterFixture)){t.Fatal("unexpected clear mutation",err)}
 if filterSourceDigest([]byte("a"))==filterSourceDigest([]byte("b")){t.Fatal("hash collision")}
}
// FIELD #428: plain YAML mapping keys with internal spaces (RZ Gist,
// Geodema RZ) are valid and must be discovered and patched without renaming.
const plainKeysFilterFixture=`mixed-port: 7890
secret: "SENSITIVE_NOT_TO_LEAK"
proxy-providers:
  RZ Gist:
    type: http
    url: "https://private.invalid/sub?token=SECRET"
  Geodema RZ:
    type: http
    exclude-filter: "(?i)russia"
proxy-groups:
  - name: MAIN
    type: select
    use:
      - RZ Gist
      - Geodema RZ
`
func TestFilterPlainKeysWithSpaces(t *testing.T){
 providers,err:=listFilterProviders([]byte(plainKeysFilterFixture))
 if err!=nil{t.Fatalf("plain YAML keys rejected: %v",err)}
 if len(providers)!=2||providers[0].Name!="RZ Gist"||providers[1].Name!="Geodema RZ"||!providers[0].HTTP||!providers[1].HTTP||providers[0].HasFilter||!providers[1].HasFilter{t.Fatalf("%+v",providers)}
 got,old,_,err:=patchProviderFilter([]byte(plainKeysFilterFixture),"RZ Gist",[]string{"Node A"},false)
 if err!=nil{t.Fatal(err)}
 if old!=""{t.Fatal(old)}
 lines:=strings.Split(plainKeysFilterFixture,"\n")
 want:=append(append([]string{},lines[:4]...),"    exclude-filter: \"^(?:Node A)$\"")
 want=append(want,lines[4:]...)
 if !bytes.Equal(got,[]byte(strings.Join(want,"\n"))){t.Fatal("insertion not byte-for-byte targeted: "+string(got))}
 if !strings.Contains(string(got),"      - RZ Gist")||!strings.Contains(string(got),"      - Geodema RZ"){t.Fatal("proxy-groups use refs changed")}
 clear,_,_,err:=patchProviderFilter(got,"RZ Gist",nil,true)
 if err!=nil||!bytes.Equal(clear,[]byte(plainKeysFilterFixture)){t.Fatal("not byte-for-byte restored",err)}
 got2,old2,_,err:=patchProviderFilter([]byte(plainKeysFilterFixture),"Geodema RZ",[]string{"Node B"},false)
 if err!=nil||old2!=`"(?i)russia"`{t.Fatalf("%v %q",err,old2)}
 want2:=append(append([]string{},lines[:8]...),"    exclude-filter: \"^(?:Node B)$\"")
 want2=append(want2,lines[9:]...)
 if !bytes.Equal(got2,[]byte(strings.Join(want2,"\n"))){t.Fatal("replacement not byte-for-byte targeted: "+string(got2))}
 if !strings.Contains(string(got2),`url: "https://private.invalid/sub?token=SECRET"`){t.Fatal("other provider changed")}
}
func TestFilterPlainUnicodeKey(t *testing.T){
 const unicodeFilterFixture="proxy-providers:\n  Провайдер Сети:\n    type: http\n"
 ps,err:=listFilterProviders([]byte(unicodeFilterFixture))
 if err!=nil||len(ps)!=1||ps[0].Name!="Провайдер Сети"||!ps[0].HTTP{t.Fatalf("%+v %v",ps,err)}
 got,_,_,err:=patchProviderFilter([]byte(unicodeFilterFixture),"Провайдер Сети",[]string{"Node"},false)
 if err!=nil{t.Fatal(err)}
 if want:="proxy-providers:\n  Провайдер Сети:\n    exclude-filter: \"^(?:Node)$\"\n    type: http\n";!bytes.Equal(got,[]byte(want)){t.Fatalf("got %q",string(got))}
 clear,_,_,err:=patchProviderFilter(got,"Провайдер Сети",nil,true)
 if err!=nil||!bytes.Equal(clear,[]byte(unicodeFilterFixture)){t.Fatal("not byte-for-byte restored",err)}
}
