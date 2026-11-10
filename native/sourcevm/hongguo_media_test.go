package sourcevm

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
)

func TestHongguoMediaURL(t *testing.T) {
	const seed = "c3ludGhldGljLXVybC1zZWVk"
	const encrypted = "qAABAIqg0G0hlbbb9a8djI4vG6rpuvxxJR/eU3yO1idU5epHesjDAjVnYjG/D0ukj1a8Yw=="
	got, err := hongguoMediaURL(encrypted, seed)
	if err != nil || got != "https://media.example/full.mp4?x=1" {
		t.Fatal("independent AES vector failed", err)
	}
	for _, value := range []string{"", "bad", encrypted[:30], strings.Repeat("a", 32769), "qAABAAConZ3x/HQwFvio+yqk4BCOnPpqKoxno1Pd4onUUot+", "qAABAJM+4JW7FEl09BuiAXJsMwF0zoQu9nPZcDv7uR8THb4qJnMv3JlGqgtlPZc+icW7xQ=="} {
		if _, err := hongguoMediaURL(value, seed); err == nil {
			t.Error("accepted invalid or unsafe media address")
		}
	}
	if _, err := hongguoMediaURL(encrypted, ""); err == nil {
		t.Error("accepted missing seed")
	}
	program := fmt.Sprintf(`function* execute(){return {url:hongguoMediaURL(%q,%q),request:JSON.parse(hongguoRegisterRequest(1700000000000)).method};}`, encrypted, seed)
	result := requestEnvelope(t, Request(fmt.Sprintf(`{"command":"start","id":"media-bindings","program":%q,"action":"resolve"}`, program)))
	if result["ok"] != true || result["data"].(map[string]any)["value"].(map[string]any)["url"] != got {
		t.Fatal("runtime capability binding failed")
	}
}

func TestHongguoRegistrationEnvelope(t *testing.T) {
	first, err := hongguoRegisterRequest(1700000000000)
	if err != nil {
		t.Fatal(err)
	}
	second, _ := hongguoRegisterRequest(1700000000000)
	if first == second {
		t.Fatal("registration reused identity")
	}
	var request struct {
		BodyBase64, CDID string
		Headers          map[string]string
	}
	if err := json.Unmarshal([]byte(first), &request); err != nil {
		t.Fatal(err)
	}
	body, err := base64.StdEncoding.DecodeString(request.BodyBase64)
	if err != nil || len(body) < 54 || string(body[:6]) != "tc\x05\x10\x00\x00" {
		t.Fatal("invalid binary envelope")
	}
	digest := md5.Sum(body)
	if request.Headers["x-ss-stub"] != strings.ToUpper(hex.EncodeToString(digest[:])) {
		t.Fatal("wire body hash mismatch")
	}
	salt, _ := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	hash := sha512.Sum512(body[6:38])
	key := sha512.Sum512(append(hash[:], salt...))
	block, _ := aes.NewCipher(key[:16])
	plain := body[38:]
	cipher.NewCBCDecrypter(block, key[16:32]).CryptBlocks(plain, plain)
	padding := int(plain[len(plain)-1])
	plain = plain[:len(plain)-padding]
	hash = sha512.Sum512(plain[64:])
	if !bytes.Equal(hash[:], plain[:64]) {
		t.Fatal("compressed body digest mismatch")
	}
	reader, err := gzip.NewReader(bytes.NewReader(plain[64:]))
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	data, err := io.ReadAll(reader)
	if err != nil {
		t.Fatal(err)
	}
	var payload struct{ Header map[string]any }
	if json.Unmarshal(data, &payload) != nil || payload.Header["cdid"] != request.CDID || payload.Header["aid"] != float64(8662) {
		t.Fatal("registration identity mismatch")
	}
	for _, now := range []int64{-1, 1<<53 + 1} {
		if _, err := hongguoRegisterRequest(now); err == nil {
			t.Error("accepted invalid timestamp")
		}
	}
}

func TestHongguoSignatureVersionFollowsRequest(t *testing.T) {
	message := hongguoMessage("version_name=7.1.3.32", "123", 1700000000, 0, [32]byte{}, [16]byte{}, nil)
	if bytes.Count(message, []byte("7.1.3.32")) != 2 || bytes.Contains(message, []byte("7.3.5.32")) {
		t.Fatal("signature version differs from request")
	}
}
