package sourcevm

import (
	"crypto/md5"
	"crypto/sha256"
	"duanjuapp/native/internal/cryptoutil"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"testing"
)

func TestHongguoPassportVectors(t *testing.T) {
	var vectors []struct {
		Params       map[string]string
		Body         string
		Now          int64
		Nonce        [4]uint32
		Query        string
		HeaderHashes map[string]string
		Branch       uint32
		Proof        string
		ProtoHash    string
	}
	raw, err := os.ReadFile("testdata/hongguo_sign_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	if err = json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	for index, v := range vectors {
		t.Run(fmt.Sprint(index), func(t *testing.T) {
			query, headers, err := hongguoPassport(v.Params, []byte(v.Body), v.Now, v.Nonce)
			if err != nil {
				t.Fatal(err)
			}
			if query != v.Query {
				t.Fatalf("query mismatch: got %s want %s", query, v.Query)
			}
			for name, expected := range v.HeaderHashes {
				sum := sha256.Sum256([]byte(headers[name]))
				if hex.EncodeToString(sum[:]) != expected {
					t.Errorf("%s mismatch", name)
				}
			}
			queryHash := cryptoutil.SM3([]byte(query))
			var bodyHash [16]byte
			if v.Body != "" {
				bodyHash = md5.Sum([]byte(v.Body))
			}
			proof := hongguoProof(v.Branch, uint32(v.Now/1000), queryHash, bodyHash)
			if hex.EncodeToString(proof) != v.Proof {
				t.Error("proof mismatch")
			}
			message := hongguoMessage(query, v.Params["device_id"], uint32(v.Now/1000), v.Nonce[0], queryHash, bodyHash, proof)
			sum := sha256.Sum256(message)
			if hex.EncodeToString(sum[:]) != v.ProtoHash {
				t.Error("message mismatch")
			}
		})
	}
}

func TestHongguoPassportRejectsInvalidInput(t *testing.T) {
	for _, params := range []string{`{}`, `{"aid":"wrong","device_id":"123"}`, `{"aid":"8662","device_id":"bad-id"}`} {
		if _, err := hongguoPassportSign(params, "", 1700000000000); err == nil {
			t.Error("accepted invalid signing parameters")
		}
	}
	if _, err := hongguoPassportSign(`{"aid":"8662","device_id":"123"}`, "", -1); err == nil {
		t.Error("accepted invalid time")
	}
}

func TestRequestSupportsHongguoSigning(t *testing.T) {
	program := `function* execute(){var signed=JSON.parse(hongguoSign(JSON.stringify({aid:"8662",device_id:"1000000000000001"}),"",1700000000000));return {signed:!!signed.headers["X-Medusa"],region:signed.headers["X-Tt-Store-Region"]};}`
	input, _ := json.Marshal(map[string]any{"command": "start", "id": "hongguo-sign-runtime", "program": program, "action": "resolve", "payload": map[string]any{}, "state": map[string]any{}})
	response := requestEnvelope(t, Request(string(input)))
	if response["ok"] != true {
		t.Fatalf("signing failed: %#v", response)
	}
	value := response["data"].(map[string]any)["value"].(map[string]any)
	if value["signed"] != true || value["region"] != "cn" {
		t.Fatal("signing capability unavailable")
	}
}
