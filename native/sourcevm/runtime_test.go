package sourcevm

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
)

func requestEnvelope(t *testing.T, raw string) map[string]any {
	t.Helper()
	var result map[string]any
	if err := json.Unmarshal([]byte(raw), &result); err != nil {
		t.Fatalf("invalid runtime response: %v", err)
	}
	return result
}

func TestRequestResumesGeneratorAfterHTTP(t *testing.T) {
	id := fmt.Sprintf("runtime-test-%d", time.Now().UnixNano())
	program := `function* execute(){var response=yield {type:"http",url:"https://example.test/feed"};return {count:response.status};}`
	started := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"start","id":%q,"program":%q,"action":"catalog","payload":{},"state":{}}`, id, program)))
	if started["ok"] != true {
		t.Fatalf("generator did not start: %#v", started)
	}
	data := started["data"].(map[string]any)
	if data["done"] != false {
		t.Fatalf("expected HTTP yield, got %#v", data)
	}
	response := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"next","id":%q,"response":{"status":200,"text":"fixture"}}`, id)))
	if response["ok"] != true {
		t.Fatalf("generator did not resume: %#v", response)
	}
	result := response["data"].(map[string]any)
	if result["done"] != true || result["value"].(map[string]any)["count"] != float64(200) {
		t.Fatalf("unexpected generator result: %#v", result)
	}
}

func TestRequestPreservesSafeHTTPStatus(t *testing.T) {
	id := fmt.Sprintf("runtime-http-test-%d", time.Now().UnixNano())
	program := `function* execute(){var response=yield {type:"http",url:"https://example.test/feed"};var error=new Error("private response details");error.sourceError="http";error.httpStatus=response.status;throw error;}`
	started := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"start","id":%q,"program":%q,"action":"catalog","payload":{},"state":{}}`, id, program)))
	if started["ok"] != true {
		t.Fatalf("generator did not start: %#v", started)
	}
	response := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"next","id":%q,"response":{"status":404,"text":"private response details"}}`, id)))
	if response["ok"] != false || response["code"] != "source_http" || response["httpStatus"] != float64(404) {
		t.Fatalf("HTTP failure details were not preserved safely: %#v", response)
	}
	if response["error"] == "private response details" {
		t.Fatal("runtime exposed source response details")
	}
}

func TestRequestUsesSafeTimeoutError(t *testing.T) {
	id := fmt.Sprintf("runtime-timeout-test-%d", time.Now().UnixNano())
	program := `function* execute(){while(true){}}`
	response := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"start","id":%q,"program":%q,"action":"catalog","payload":{},"state":{}}`, id, program)))
	if response["ok"] != false || response["code"] != "source_timeout" {
		t.Fatalf("expected bounded timeout response, got %#v", response)
	}
}

func TestRequestUsesSafeStackError(t *testing.T) {
	id := fmt.Sprintf("runtime-stack-test-%d", time.Now().UnixNano())
	program := `function recurse(){return recurse()} function* execute(){recurse()}`
	response := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"start","id":%q,"program":%q,"action":"catalog","payload":{},"state":{}}`, id, program)))
	if response["ok"] != false || response["code"] != "source_stack" {
		t.Fatalf("expected safe stack response, got %#v", response)
	}
}

func TestScriptDiagnosticDoesNotExposeExceptionMessage(t *testing.T) {
	id := fmt.Sprintf("runtime-diagnostic-%d", time.Now().UnixNano())
	program := `function* execute(){throw new TypeError("private-cookie-value https://secret.test/?token=private");}`
	raw := Request(fmt.Sprintf(`{"command":"start","id":%q,"program":%q,"action":"catalog","payload":{},"state":{}}`, id, program))
	value := requestEnvelope(t, raw)
	if value["code"] != "source_script" || value["exceptionType"] != "TypeError" {
		t.Fatalf("missing safe diagnostic: %s", raw)
	}
	if strings.Contains(raw, "private") || strings.Contains(raw, "secret.test") {
		t.Fatalf("exception detail leaked: %s", raw)
	}
}
