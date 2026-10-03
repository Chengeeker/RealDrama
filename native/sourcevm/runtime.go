package sourcevm

import (
 "crypto/md5"
 "crypto/sha256"
 "encoding/base64"
 "encoding/hex"
 "encoding/json"
 "errors"
 "sync"
 "time"

 "github.com/dop251/goja"
)

type request struct {
 Command string `json:"command"`
 ID string `json:"id"`
 Program string `json:"program"`
 Action string `json:"action"`
 Payload json.RawMessage `json:"payload"`
 State json.RawMessage `json:"state"`
 Response json.RawMessage `json:"response"`
}
type session struct { vm *goja.Runtime; iterator *goja.Object; next goja.Callable; updated time.Time; mu sync.Mutex }
var sessions = struct { sync.Mutex; values map[string]*session }{values: map[string]*session{}}
var programs = struct { sync.Mutex; values map[string]*goja.Program }{values: map[string]*goja.Program{}}

func Request(raw string) (result string) {
 defer func() { if recover()!=nil { result=`{"ok":false,"error":"站源脚本执行失败"}` } }()
 if len(raw)>12<<20 { return failure() }
 var input request
 if json.Unmarshal([]byte(raw), &input)!=nil || len(input.ID)>160 || input.ID=="" { return failure() }
 sessions.Lock()
 for id, item := range sessions.values { if time.Since(item.updated)>45*time.Second { item.vm.Interrupt("expired"); delete(sessions.values,id) } }
 item:=sessions.values[input.ID]
 if input.Command=="cancel" { if item!=nil { item.vm.Interrupt("cancelled"); delete(sessions.values,input.ID) }; sessions.Unlock(); return `{"ok":true,"data":{}}` }
 if input.Command=="start" {
  if item!=nil || len(sessions.values)>=4 || len(input.Program)>2<<20 { sessions.Unlock(); return failure() }
  item=&session{vm:goja.New(),updated:time.Now()}; item.vm.SetMaxCallStackSize(96)
  sessions.values[input.ID]=item
 }
 sessions.Unlock()
 if item==nil { return failure() }
 item.mu.Lock(); defer item.mu.Unlock()
 timer:=time.AfterFunc(250*time.Millisecond,func(){item.vm.Interrupt("execution limit")}); defer timer.Stop()
 vm:=item.vm
 var value goja.Value
 var err error
 if input.Command=="start" {
  vm.Set("md5",func(value string) string { sum:=md5.Sum([]byte(value)); return hex.EncodeToString(sum[:]) })
  vm.Set("base64decode",func(value string) string { bytes,err:=base64.StdEncoding.DecodeString(value); if err!=nil || len(bytes)>1<<20 { panic(vm.NewTypeError("base64 invalid")) }; return string(bytes) })
  vm.Set("base64encode",func(value string) string { if len(value)>1<<20 { panic(vm.NewTypeError("base64 limit")) }; return base64.StdEncoding.EncodeToString([]byte(value)) })
  sum:=sha256.Sum256([]byte(input.Program)); key:=hex.EncodeToString(sum[:])
  programs.Lock(); program:=programs.values[key]; programs.Unlock()
  if program==nil { program,err=goja.Compile("source.js",input.Program,true); if err==nil { programs.Lock(); if len(programs.values)>=8 { programs.values=map[string]*goja.Program{} }; programs.values[key]=program; programs.Unlock() } }
  if err==nil { _,err=vm.RunProgram(program) }
  if err==nil { execute,ok:=goja.AssertFunction(vm.Get("execute")); if !ok { err=errors.New("missing execute") } else { var payload,state any; json.Unmarshal(input.Payload,&payload); json.Unmarshal(input.State,&state); value,err=execute(goja.Undefined(),vm.ToValue(input.Action),vm.ToValue(payload),vm.ToValue(state)); if err==nil { item.iterator=value.ToObject(vm); item.next,ok=goja.AssertFunction(item.iterator.Get("next")); if !ok { err=errors.New("not generator") } } } }
 }
 if err==nil && item.next!=nil {
  var response any; json.Unmarshal(input.Response,&response)
  value,err=item.next(item.iterator,vm.ToValue(response))
 }
 if err!=nil || value==nil { remove(input.ID); return failure() }
 object:=value.ToObject(vm); done:=object.Get("done").ToBoolean()
 data:=object.Get("value").Export()
 body,err:=json.Marshal(map[string]any{"ok":true,"data":map[string]any{"done":done,"value":data}})
 if done { remove(input.ID) }
 sessions.Lock(); item.updated=time.Now(); sessions.Unlock()
 if err!=nil || len(body)>8<<20 { remove(input.ID); return failure() }
 return string(body)
}
func remove(id string) { sessions.Lock(); delete(sessions.values,id); sessions.Unlock() }
func failure() string { return `{"ok":false,"error":"站源脚本无效、超出执行限制或已取消，请更新站源后重试"}` }
