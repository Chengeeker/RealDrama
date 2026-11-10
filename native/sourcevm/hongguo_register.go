package sourcevm

import (
	"bytes"
	"compress/gzip"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha512"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

func hongguoRegisterRequest(now int64) (string, error) {
	if now < 0 || now > 1<<53 {
		return "", errors.New("registration timestamp invalid")
	}
	var entropy [88]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", err
	}
	uuid := func(data []byte) string {
		data[6] = data[6]&15 | 64
		data[8] = data[8]&63 | 128
		return fmt.Sprintf("%x-%x-%x-%x-%x", data[:4], data[4:6], data[6:8], data[8:10], data[10:16])
	}
	cdid := uuid(entropy[32:48])
	header := map[string]any{
		"display_name": "红果免费短剧", "update_version_code": 73932, "manifest_version_code": 73932,
		"app_version_minor": "7.3.9.32", "aid": 8662, "channel": "update_64", "package": "com.phoenix.read",
		"app_version": "7.3.9.32", "version_code": 73932, "sdk_version": "3.7.0-rc.34-fanqie-xiaoshuo",
		"sdk_target_version": 29, "git_hash": "3a88f4e", "os": "Android", "os_version": "16", "os_api": 36,
		"device_model": "25053RT47C", "device_brand": "Redmi", "device_manufacturer": "Redmi",
		"cpu_abi": "arm64-v8a", "release_build": "b5e187f", "density_dpi": 520, "display_density": "mdpi",
		"resolution": "1280x2772", "language": "zh", "timezone": 8, "access": "wifi", "not_request_sender": 0,
		"carrier": "CHINA MOBILE", "mcc_mnc": "46000", "rom": "eng.root.20231116.160340", "rom_version": "W528JS release-keys",
		"cdid": cdid, "sig_hash": "56a962410c494bbaf0b58dba20cae56f", "openudid": hex.EncodeToString(entropy[80:]),
		"clientudid": uuid(entropy[48:64]), "ipv6_list": []string{}, "region": "CN", "tz_name": "Asia/Shanghai",
		"tz_offset": 28800, "sim_region": "cn", "sim_serial_number": []string{}, "oaid_may_support": false,
		"req_id": uuid(entropy[64:80]), "device_platform": "android", "pre_installed_channel": "",
		"custom":                 map[string]any{"account_region_src": "fallback", "account_region": "cn", "host_bit": 64, "dragon_device_type": "phone"},
		"apk_first_install_time": now, "is_system_app": 0, "sdk_flavor": "china", "guest_mode": 0,
	}
	input, err := json.Marshal(map[string]any{"magic_tag": "ss_app_log", "header": header, "_gen_time": now})
	if err != nil {
		return "", err
	}
	var compressed bytes.Buffer
	writer := gzip.NewWriter(&compressed)
	if _, err := writer.Write(input); err != nil {
		return "", err
	}
	if err := writer.Close(); err != nil {
		return "", err
	}
	salt, _ := hex.DecodeString("4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")
	first := sha512.Sum512(entropy[:32])
	key := sha512.Sum512(append(first[:], salt...))
	digest := sha512.Sum512(compressed.Bytes())
	plain := append(digest[:], compressed.Bytes()...)
	padding := aes.BlockSize - len(plain)%aes.BlockSize
	plain = append(plain, bytes.Repeat([]byte{byte(padding)}, padding)...)
	block, err := aes.NewCipher(key[:16])
	if err != nil {
		return "", err
	}
	cipher.NewCBCEncrypter(block, key[16:32]).CryptBlocks(plain, plain)
	body := append([]byte{0x74, 0x63, 5, 0x10, 0, 0}, entropy[:32]...)
	body = append(body, plain...)
	stub := md5.Sum(body)
	result, err := json.Marshal(map[string]any{
		"url":    "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1",
		"method": "POST", "type": "http", "bodyBase64": base64.StdEncoding.EncodeToString(body), "cdid": cdid,
		"headers": map[string]string{
			"User-Agent": "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",
			"Accept":     "application/json", "Content-Type": "application/octet-stream;tt-data=a", "log-encode-type": "gzip",
			"x-ss-dp": "8662", "x-ss-req-ticket": strconv.FormatInt(now, 10), "x-vc-bdturing-sdk-version": "4.0.3.cn",
			"lc": "101", "sdk-version": "2", "passport-sdk-version": "5051452", "x-neptune": "-8|50:51:59:30:40:47:49:39",
			"x-ss-stub": strings.ToUpper(hex.EncodeToString(stub[:])),
		},
	})
	return string(result), err
}
