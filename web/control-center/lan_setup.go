package main

// One-time manual provisioning for experimental HTTPS LAN operation.
// The console displays the 256-bit secret once; files never overwrite.
import (
 "crypto/ed25519"
 "crypto/rand"
 "crypto/sha256"
 "crypto/x509"
 "crypto/x509/pkix"
 "encoding/base64"
 "encoding/hex"
 "encoding/pem"
 "errors"
 "fmt"
 "math/big"
 "net"
 "os"
 "path/filepath"
 "time"
)

func setupLANCredentials(ipText,dir string)(string,error) {
 ip:=net.ParseIP(ipText)
 if ip==nil || ip.To4()==nil || !ip.IsPrivate() {
  return "",errors.New("setup requires private IPv4 address")
 }
 if dir=="" {return "",errors.New("setup directory required")}
 // Require a new dedicated directory; never replace auth/certs from another
 // app or silently rotate a live Control Center password.
 if err:=os.Mkdir(dir,0700);err!=nil{return "",fmt.Errorf("cannot create private credentials directory: %w",err)}
 success:=false
 defer func(){if !success {
  for _,name:=range []string{"auth.token","server.crt","server.key"} {os.Remove(filepath.Join(dir,name))}
  os.Remove(dir)
 }}()
 token:=make([]byte,32)
 if _,err:=rand.Read(token);err!=nil{return "",err}
 login:=base64.RawURLEncoding.EncodeToString(token)
 public,private,err:=ed25519.GenerateKey(rand.Reader)
 if err!=nil{return "",err}
 serialBytes:=make([]byte,16)
 if _,err=rand.Read(serialBytes);err!=nil{return "",err}
 serial:=new(big.Int).SetBytes(serialBytes)
 template:=x509.Certificate{
  SerialNumber:serial,Subject:pkix.Name{CommonName:"KAS Control Center LAN"},
  NotBefore:time.Now().Add(-time.Hour),NotAfter:time.Now().AddDate(1,0,0),
  KeyUsage:x509.KeyUsageDigitalSignature,ExtKeyUsage:[]x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
  IPAddresses:[]net.IP{ip.To4()},
  BasicConstraintsValid:true,
 }
 certDER,err:=x509.CreateCertificate(rand.Reader,&template,&template,public,private)
 if err!=nil{return "",err}
 keyDER,err:=x509.MarshalPKCS8PrivateKey(private)
 if err!=nil{return "",err}
 files:=[]struct{name string;data []byte}{
  {"auth.token",[]byte(login+"\n")},
  {"server.crt",pem.EncodeToMemory(&pem.Block{Type:"CERTIFICATE",Bytes:certDER})},
  {"server.key",pem.EncodeToMemory(&pem.Block{Type:"PRIVATE KEY",Bytes:keyDER})},
 }
 for _,item:=range files{
  f,err:=os.OpenFile(filepath.Join(dir,item.name),os.O_WRONLY|os.O_CREATE|os.O_EXCL,0600)
  if err!=nil{return "",err}
  _,err=f.Write(item.data)
  if err==nil{err=f.Sync()}
  closeErr:=f.Close()
  if err!=nil{return "",err}
  if closeErr!=nil{return "",closeErr}
 }
 success=true
 fingerprint:=sha256.Sum256(certDER)
 return fmt.Sprintf("LAN credential directory created.\nUsername: kas\nOne-time password: %s\nCertificate SHA256 (DER): %s\nBrowser certificate requires independent trust verification.\n",
  login,hex.EncodeToString(fingerprint[:])),nil
}
