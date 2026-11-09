package sourcevm

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"net/url"
)

func hongguoMediaURL(value, seed string) (string, error) {
	invalid := errors.New("media address invalid")
	if len(value) > 32768 || len(seed) > 4096 {
		return "", invalid
	}
	raw, err := decodeBase64(value)
	if err != nil || len(raw) < 20 || raw[0] != 0xa8 || raw[2] != 1 || raw[3] != 0 || (len(raw)-4)%aes.BlockSize != 0 {
		return "", invalid
	}
	material, err := decodeBase64(seed)
	if err != nil || len(material) == 0 {
		return "", invalid
	}
	salt, _ := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	first := sha512.Sum512(material)
	key := sha512.Sum512(append(first[:], salt...))
	block, err := aes.NewCipher(key[:16])
	if err != nil {
		return "", invalid
	}
	plain := raw[4:]
	cipher.NewCBCDecrypter(block, key[16:32]).CryptBlocks(plain, plain)
	padding := int(plain[len(plain)-1])
	if padding < 1 || padding > aes.BlockSize || !bytes.Equal(plain[len(plain)-padding:], bytes.Repeat([]byte{byte(padding)}, padding)) {
		return "", invalid
	}
	plain = bytes.TrimRight(plain[:len(plain)-padding], "\x00")
	address, err := url.Parse(string(plain))
	if err != nil || address.Scheme != "https" || address.User != nil || address.Hostname() == "" || address.Port() != "" && address.Port() != "443" {
		return "", invalid
	}
	return address.String(), nil
}
