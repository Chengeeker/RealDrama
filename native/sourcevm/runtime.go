package sourcevm

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/andybalholm/cascadia"
	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

type request struct {
	Command  string          `json:"command"`
	ID       string          `json:"id"`
	Program  string          `json:"program"`
	Action   string          `json:"action"`
	Payload  json.RawMessage `json:"payload"`
	State    json.RawMessage `json:"state"`
	Response json.RawMessage `json:"response"`
}
type session struct {
	vm       *goja.Runtime
	iterator *goja.Object
	next     goja.Callable
	updated  time.Time
	cpuUsed  time.Duration
	mu       sync.Mutex
}

const (
	sourceStepTimeout    = 900 * time.Millisecond
	sourceSessionTimeout = 4 * time.Second
)

var sessions = struct {
	sync.Mutex
	values map[string]*session
}{values: map[string]*session{}}
var programs = struct {
	sync.Mutex
	values map[string]*goja.Program
}{values: map[string]*goja.Program{}}

func Request(raw string) (result string) {
	requestID := ""
	defer func() {
		if recover() != nil {
			if requestID != "" {
				remove(requestID)
			}
			result = failureWith("source_runtime", "站源运行环境异常，请重试")
		}
	}()
	if len(raw) > 12<<20 {
		return failureWith("source_request", "站源请求数据过大")
	}
	var input request
	if json.Unmarshal([]byte(raw), &input) != nil || len(input.ID) > 160 || input.ID == "" {
		return failureWith("source_request", "站源请求格式无效")
	}
	requestID = input.ID
	sessions.Lock()
	for id, item := range sessions.values {
		if time.Since(item.updated) > 45*time.Second {
			item.vm.Interrupt("expired")
			delete(sessions.values, id)
		}
	}
	item := sessions.values[input.ID]
	if input.Command == "cancel" {
		if item != nil {
			item.vm.Interrupt("cancelled")
			delete(sessions.values, input.ID)
		}
		sessions.Unlock()
		return `{"ok":true,"data":{}}`
	}
	if input.Command == "start" {

		if item != nil || len(sessions.values) >= 8 || len(input.Program) > 2<<20 {
			sessions.Unlock()
			if len(input.Program) > 2<<20 {
				return failureWith("source_limit", "站源程序体积超出限制")
			}
			return failureWith("source_session", "站源运行会话已满，请稍后重试")
		}
		item = &session{vm: goja.New(), updated: time.Now()}
		item.vm.SetMaxCallStackSize(512)
		sessions.values[input.ID] = item
	}
	sessions.Unlock()
	if item == nil {
		return failureWith("source_session", "站源运行会话已过期或已取消，请重试")
	}
	item.mu.Lock()
	defer item.mu.Unlock()
	executionStarted := time.Now()
	timer := time.AfterFunc(sourceStepTimeout, func() { item.vm.Interrupt("execution limit") })
	defer timer.Stop()
	vm := item.vm
	var value goja.Value
	var err error
	if input.Command == "start" {
		vm.Set("sha256hex", func(value string) string {
			data, err := hex.DecodeString(value)
			if err != nil || len(data) > 1<<20 {
				panic(vm.NewTypeError("digest input invalid"))
			}
			sum := sha256.Sum256(data)
			return hex.EncodeToString(sum[:])
		})
		vm.Set("base64hex", func(value string) string {
			data, err := decodeBase64(value)
			if err != nil || len(data) > 1<<20 {
				panic(vm.NewTypeError("base64 invalid"))
			}
			return hex.EncodeToString(data)
		})
		vm.Set("hexbase64", func(value string) string {
			data, err := hex.DecodeString(value)
			if err != nil || len(data) > 1<<20 {
				panic(vm.NewTypeError("hex invalid"))
			}
			return base64.StdEncoding.EncodeToString(data)
		})
		vm.Set("aescbcEncrypt", func(value, keyHex, ivHex string) string {
			if len(value) > 1<<20 {
				panic(vm.NewTypeError("cipher input invalid"))
			}
			key, err := hex.DecodeString(keyHex)
			iv, ivErr := hex.DecodeString(ivHex)
			if err != nil || ivErr != nil || len(iv) != aes.BlockSize {
				panic(vm.NewTypeError("cipher invalid"))
			}
			block, err := aes.NewCipher(key)
			if err != nil {
				panic(vm.NewTypeError("cipher invalid"))
			}
			data := []byte(value)
			padding := aes.BlockSize - len(data)%aes.BlockSize
			data = append(data, bytes.Repeat([]byte{byte(padding)}, padding)...)
			cipher.NewCBCEncrypter(block, iv).CryptBlocks(data, data)
			return base64.StdEncoding.EncodeToString(data)
		})
		vm.Set("jsonAssignment", func(body, pattern string) string {
			if len(body) > 8<<20 || len(pattern) > 512 {
				panic(vm.NewTypeError("JSON assignment limit"))
			}
			matcher, err := regexp.Compile(pattern)
			if err != nil {
				panic(vm.NewTypeError("JSON assignment pattern invalid"))
			}
			match := matcher.FindStringIndex(body)
			if match == nil {
				return "null"
			}
			var raw json.RawMessage
			if json.NewDecoder(strings.NewReader(body[match[1]:])).Decode(&raw) != nil {
				panic(vm.NewTypeError("JSON assignment invalid"))
			}
			return string(raw)
		})
		vm.Set("resolveURL", func(base, reference string) string {
			address, err := url.Parse(base)
			if err != nil {
				return ""
			}
			target, err := url.Parse(reference)
			if err != nil || target.User != nil {
				return ""
			}
			return address.ResolveReference(target).String()
		})
		var htmlBody string
		var htmlDocument *html.Node
		vm.Set("htmlSelect", func(body, selector string) []map[string]any {
			if len(body) > 4<<20 || len(selector) > 512 {
				panic(vm.NewTypeError("HTML limit"))
			}
			if htmlDocument == nil || htmlBody != body {
				var err error
				htmlDocument, err = html.Parse(bytes.NewBufferString(body))
				if err != nil {
					panic(vm.NewTypeError("HTML invalid"))
				}
				htmlBody = body
			}
			matcher, err := cascadia.Parse(selector)
			if err != nil {
				panic(vm.NewTypeError("selector invalid"))
			}
			matches := cascadia.QueryAll(htmlDocument, matcher)
			if len(matches) > 1000 {
				panic(vm.NewTypeError("selector limit"))
			}
			result := make([]map[string]any, 0, len(matches))
			total := 0
			var content func(*html.Node, *bytes.Buffer)
			content = func(node *html.Node, out *bytes.Buffer) {
				if out.Len() > 16384 {
					return
				}
				if node.Type == html.TextNode {
					out.WriteString(node.Data)
					out.WriteByte(' ')
				}
				for child := node.FirstChild; child != nil; child = child.NextSibling {
					content(child, out)
				}
			}
			for _, node := range matches {
				attributes := map[string]string{}
				for _, attr := range node.Attr {
					attributes[attr.Key] = attr.Val
				}
				var text, outer bytes.Buffer
				content(node, &text)
				html.Render(&outer, node)
				total += outer.Len()
				if total > 4<<20 {
					panic(vm.NewTypeError("HTML result limit"))
				}
				result = append(result, map[string]any{"tag": node.Data, "attributes": attributes, "text": text.String(), "html": outer.String()})
			}
			return result
		})
		vm.Set("aescbc", func(value, keyHex, ivHex string) string {
			bytes, err := decodeBase64(value)
			if err != nil || len(bytes) == 0 || len(bytes) > 1<<20 || len(bytes)%aes.BlockSize != 0 {
				panic(vm.NewTypeError("ciphertext invalid"))
			}
			key, keyErr := hex.DecodeString(keyHex)
			iv, ivErr := hex.DecodeString(ivHex)
			if keyErr != nil || ivErr != nil || len(iv) != aes.BlockSize {
				panic(vm.NewTypeError("cipher invalid"))
			}
			block, err := aes.NewCipher(key)
			if err != nil {
				panic(vm.NewTypeError("cipher invalid"))
			}
			cipher.NewCBCDecrypter(block, iv).CryptBlocks(bytes, bytes)
			padding := int(bytes[len(bytes)-1])
			if padding < 1 || padding > aes.BlockSize || padding > len(bytes) {
				panic(vm.NewTypeError("padding invalid"))
			}
			for _, value := range bytes[len(bytes)-padding:] {
				if int(value) != padding {
					panic(vm.NewTypeError("padding invalid"))
				}
			}
			return string(bytes[:len(bytes)-padding])
		})
		vm.Set("md5", func(value string) string { sum := md5.Sum([]byte(value)); return hex.EncodeToString(sum[:]) })
		vm.Set("base64decode", func(value string) string {
			bytes, err := decodeBase64(value)
			if err != nil || len(bytes) > 1<<20 {
				panic(vm.NewTypeError("base64 invalid"))
			}
			return string(bytes)
		})
		vm.Set("base64bytes", func(value string) []int {
			bytes, err := decodeBase64(value)
			if err != nil || len(bytes) > 1<<20 {
				panic(vm.NewTypeError("base64 invalid"))
			}
			result := make([]int, len(bytes))
			for i, b := range bytes {
				result[i] = int(b)
			}
			return result
		})
		vm.Set("base64encode", func(value string) string {
			if len(value) > 1<<20 {
				panic(vm.NewTypeError("base64 limit"))
			}
			return base64.StdEncoding.EncodeToString([]byte(value))
		})
		sum := sha256.Sum256([]byte(input.Program))
		key := hex.EncodeToString(sum[:])
		programs.Lock()
		program := programs.values[key]
		programs.Unlock()
		if program == nil {
			program, err = goja.Compile("source.js", input.Program, true)
			if err == nil {
				programs.Lock()
				if len(programs.values) >= 8 {
					programs.values = map[string]*goja.Program{}
				}
				programs.values[key] = program
				programs.Unlock()
			}
		}
		if err == nil {
			_, err = vm.RunProgram(program)
		}
		if err == nil {
			execute, ok := goja.AssertFunction(vm.Get("execute"))
			if !ok {
				err = errors.New("missing execute")
			} else {
				var payload, state any
				json.Unmarshal(input.Payload, &payload)
				json.Unmarshal(input.State, &state)
				value, err = execute(goja.Undefined(), vm.ToValue(input.Action), vm.ToValue(payload), vm.ToValue(state))
				if err == nil {
					item.iterator = value.ToObject(vm)
					item.next, ok = goja.AssertFunction(item.iterator.Get("next"))
					if !ok {
						err = errors.New("not generator")
					}
				}
			}
		}
	}
	if err == nil && item.next != nil {
		var response any
		json.Unmarshal(input.Response, &response)
		value, err = item.next(item.iterator, vm.ToValue(response))
	}
	timerFired := !timer.Stop()
	executionTime := time.Since(executionStarted)
	item.cpuUsed += executionTime
	if timerFired || executionTime >= sourceStepTimeout || item.cpuUsed > sourceSessionTimeout {
		remove(input.ID)
		return failureWith("source_timeout", "站源处理超时，请减少加载范围或更新订阅后重试")
	}
	if err != nil || value == nil {
		remove(input.ID)
		var exception *goja.Exception
		if errors.As(err, &exception) {
			object := exception.Value().ToObject(vm)
			reason, statusValue := object.Get("sourceError"), object.Get("httpStatus")
			if reason != nil && reason.String() == "http" && statusValue != nil {
				status := statusValue.ToInteger()
				if status == 0 || status >= 400 && status <= 599 {
					body, _ := json.Marshal(map[string]any{"ok": false, "code": "source_http", "httpStatus": status, "error": "站源接口请求失败，请检查网络或更新订阅"})
					return string(body)
				}
			}

			name := object.Get("name")
			kind := "Error"
			if name != nil {
				switch name.String() {
				case "SyntaxError", "TypeError", "ReferenceError", "RangeError", "Error":
					kind = name.String()
				}
			}
			line := 0
			if match := regexp.MustCompile(`:(\d+):\d+`).FindStringSubmatch(exception.String()); len(match) == 2 {
				line, _ = strconv.Atoi(match[1])
			}
			body, _ := json.Marshal(map[string]any{"ok": false, "code": "source_script", "exceptionType": kind, "scriptLine": line, "error": "站源解析失败，请更新订阅后重试"})
			return string(body)
		}
		var interrupted *goja.InterruptedError
		if errors.As(err, &interrupted) {
			reason, _ := interrupted.Value().(string)
			switch reason {
			case "cancelled":
				return failureWith("source_cancelled", "站源请求已取消，请重试")
			case "expired":
				return failureWith("source_session", "站源运行会话已过期，请重试")
			case "execution limit":
				return failureWith("source_timeout", "站源处理超时，请减少加载范围或更新订阅后重试")
			}
		}
		var stackOverflow *goja.StackOverflowError
		if errors.As(err, &stackOverflow) {
			return failureWith("source_stack", "站源数据嵌套过深，请更新订阅后重试")
		}
		return failureWith("source_script", "站源解析失败，请更新订阅后重试")
	}
	object := value.ToObject(vm)
	done := object.Get("done").ToBoolean()
	data := object.Get("value").Export()
	body, err := json.Marshal(map[string]any{"ok": true, "data": map[string]any{"done": done, "value": data}})
	if done {
		remove(input.ID)
	}
	sessions.Lock()
	item.updated = time.Now()
	sessions.Unlock()
	if err != nil || len(body) > 8<<20 {
		remove(input.ID)
		return failureWith("source_result", "站源返回的数据无法处理，请更新订阅后重试")
	}
	return string(body)
}
func remove(id string) { sessions.Lock(); delete(sessions.values, id); sessions.Unlock() }
func failureWith(code, message string) string {
	body, _ := json.Marshal(map[string]any{"ok": false, "code": code, "error": message})
	return string(body)
}

func decodeBase64(value string) ([]byte, error) {
	result, err := base64.StdEncoding.DecodeString(value)
	if err != nil {
		return base64.RawStdEncoding.DecodeString(value)
	}
	return result, nil
}
