package main
import("encoding/binary";"encoding/json";"fmt";"io";"net";"time";socks "github.com/armon/go-socks5")
func check(e error){if e!=nil{panic(e)}}
func main(){
 echo,e:=net.Listen("tcp","127.0.0.1:0");check(e);defer echo.Close()
 go func(){c,e:=echo.Accept();if e==nil{defer c.Close();io.Copy(c,c)}}()
 srv,e:=socks.New(&socks.Config{});check(e);ln,e:=net.Listen("tcp","127.0.0.1:0");check(e);defer ln.Close();go srv.Serve(ln)
 result:=map[string]any{"scope":"exact armon dependency; loopback TCP only; not VPN test"}
 for _,cmd:=range []byte{1,3}{
  c,e:=net.Dial("tcp",ln.Addr().String());check(e);c.SetDeadline(time.Now().Add(3*time.Second));c.Write([]byte{5,1,0});g:=make([]byte,2);_,e=io.ReadFull(c,g);check(e)
  port:=echo.Addr().(*net.TCPAddr).Port;b:=[]byte{5,cmd,0,1,127,0,0,1,0,0};binary.BigEndian.PutUint16(b[8:],uint16(port));c.Write(b);r:=make([]byte,10);_,e=io.ReadFull(c,r);check(e)
  if cmd==1{result["connect_reply"]=r[1];c.Write([]byte("lab-echo"));v:=make([]byte,8);_,e=io.ReadFull(c,v);check(e);result["tcp_equal"]=string(v)=="lab-echo"}else{result["udp_associate_reply"]=r[1]};c.Close()
 }
 out,_:=json.Marshal(result);fmt.Println(string(out))
}
