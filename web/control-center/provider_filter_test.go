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
 cases:=[]string{"proxy-providers:\n  P: {type: http}\n","proxy-providers:\n  P: &alias\n    type: http\n","proxy-providers:\n  P:\n    type: http\n    exclude-filter: |\n      hello\n","proxy-providers:\n  P:\n    type: http\n    exclude-filter: x\n    exclude-filter: y\n","proxy-providers:\n  P:\n    <<: *common\n    type: http\n","proxy-providers:\n  P:\n    type: file\n"}
 for i,s:=range cases{if _,_,_,err:=patchProviderFilter([]byte(s),"P",[]string{"X"},false);err==nil{t.Fatalf("accepted case %d",i)}}
 for _,names:=range [][]string{nil,{},{"dup","dup"},{""}}{if _,_,_,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-One",names,false);err==nil{t.Fatalf("bad names %v",names)}}
}
func TestFilterNoOpsAndSourceDigest(t *testing.T){
 got,_,_,err:=patchProviderFilter([]byte(inputFilterFixture),"Provider-One",nil,true)
 if err!=nil||!bytes.Equal(got,[]byte(inputFilterFixture)){t.Fatal("unexpected clear mutation",err)}
 if filterSourceDigest([]byte("a"))==filterSourceDigest([]byte("b")){t.Fatal("hash collision")}
}
