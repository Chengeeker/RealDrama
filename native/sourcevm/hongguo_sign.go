package sourcevm

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"math"
	"math/bits"
	"net/url"
	"strconv"
	"strings"

	"duanjuapp/native/internal/cryptoutil"
)

func hongguoPassportSign(parameters, body string, now int64) (string, error) {
	if len(parameters) > 32768 || len(body) > 1<<20 || now < 0 || now/1000 > math.MaxUint32 {
		return "", errors.New("signing input invalid")
	}
	var params map[string]string
	if json.Unmarshal([]byte(parameters), &params) != nil || params["aid"] != "8662" {
		return "", errors.New("signing parameters invalid")
	}
	device := params["device_id"]
	if len(device) == 0 || len(device) > 32 {
		return "", errors.New("device identifier invalid")
	}
	for _, digit := range device {
		if digit < '0' || digit > '9' {
			return "", errors.New("device identifier invalid")
		}
	}
	var entropy [16]byte
	if _, err := rand.Read(entropy[:]); err != nil {
		return "", errors.New("signing entropy unavailable")
	}
	var nonce [4]uint32
	for i := range nonce {
		nonce[i] = binary.LittleEndian.Uint32(entropy[i*4:])
	}
	query, headers, err := hongguoPassport(params, []byte(body), now, nonce)
	if err != nil {
		return "", err
	}
	result, err := json.Marshal(map[string]any{"query": query, "headers": headers})
	return string(result), err
}

func hongguoPassport(params map[string]string, body []byte, now int64, nonce [4]uint32) (string, map[string]string, error) {
	stamp := uint32(now / 1000)
	var bodyHash [16]byte
	if len(body) > 0 {
		bodyHash = md5.Sum(body)
	}
	values := url.Values{}
	for key, value := range params {
		values.Set(key, value)
	}
	var query string
	var queryHash [32]byte
	var branch uint32
	selected := false
	for offset := int64(0); offset < 256; offset++ {
		values.Set("_rticket", strconv.FormatInt(now+offset, 10))
		query = values.Encode()
		queryHash = cryptoutil.SM3([]byte(query))
		branch = hongguoMix(hongguoLE(stamp), hongguoMix(bodyHash[:], hongguoMix(queryHash[:], 539167016)))
		if (branch&15)%3 == 2 {
			selected = true
			break
		}
	}
	if !selected {
		return "", nil, errors.New("signing branch unavailable")
	}
	headers := map[string]string{
		"X-Khronos":             strconv.FormatUint(uint64(stamp), 10),
		"X-SS-Req-Ticket":       values.Get("_rticket"),
		"X-Gorgon":              hongguoPassportGorgon(query, bodyHash, stamp, uint16(nonce[0])),
		"X-Helios":              hongguoHelios(stamp, nonce[3]),
		"X-Medusa":              base64.StdEncoding.EncodeToString(hongguoMedusa(query, stamp, nonce, params["device_id"], branch, queryHash, bodyHash)),
		"X-SS-STUB":             "",
		"X-SS-DP":               "8662",
		"X-Tt-Store-Region":     "cn",
		"X-Tt-Store-Region-Src": "did",
	}
	if len(body) > 0 {
		headers["X-SS-STUB"] = strings.ToUpper(hex.EncodeToString(bodyHash[:]))
	}
	return query, headers, nil
}

func hongguoLE(value uint32) []byte {
	out := make([]byte, 4)
	binary.LittleEndian.PutUint32(out, value)
	return out
}

func hongguoMix(data []byte, value uint32) uint32 {
	for i, b := range data {
		if i%2 == 0 {
			value = value>>4 ^ value ^ value<<6 ^ uint32(b)
		} else {
			value = value>>7 ^ value ^ ^(uint32(b) | value<<12)
		}
	}
	return value
}

func hongguoPassportGorgon(query string, bodyHash [16]byte, stamp uint32, nonce uint16) string {
	digest := md5.Sum([]byte(query))
	var data [20]byte
	copy(data[:4], digest[:4])
	copy(data[4:8], bodyHash[:4])
	binary.LittleEndian.PutUint32(data[12:], 67503104)
	binary.BigEndian.PutUint32(data[16:], stamp)
	key := [8]byte{74, 64, 22, byte(nonce >> 8), 71, 108, 1, byte(nonce)}
	var box [256]byte
	for i := range box {
		box[i] = byte(i)
	}
	var position byte
	for i := range box {
		position += box[i] + key[i%8]
		box[i] = box[position]
	}
	position = 0
	for i := range data {
		position += box[i+1]
		value := box[position]
		box[i+1] = value
		data[i] ^= box[byte(2*value)]
	}
	for i := range data {
		data[i] = bits.RotateLeft8(data[i], 4)
		data[i] = ^bits.Reverse8(data[i]^data[(i+1)%len(data)]) ^ 20
	}
	out := []byte{132, 4, byte(nonce), byte(nonce >> 8), 64, 1}
	return hex.EncodeToString(append(out, data[:]...))
}

func hongguoHelios(stamp, nonce uint32) string {
	digest := md5.Sum(append(hongguoLE(nonce), []byte("8662")...))
	key := []byte(hex.EncodeToString(digest[:]))
	left := binary.LittleEndian.Uint64(key)
	queue := []uint64{
		binary.LittleEndian.Uint64(key[8:]),
		binary.LittleEndian.Uint64(key[16:]),
		binary.LittleEndian.Uint64(key[24:]),
	}
	var rounds [34]uint64
	rounds[0] = left
	for i := 0; i < 33; i++ {
		mixed := (bits.RotateLeft64(queue[0], -8) + left) ^ uint64(i)
		queue = append(queue[1:], mixed)
		left = mixed ^ bits.RotateLeft64(left, 3)
		rounds[i+1] = left
	}
	payload := []byte(strconv.FormatUint(uint64(stamp), 10) + "-1588093228-8662")
	padding := 16 - len(payload)%16
	for i := 0; i < padding; i++ {
		payload = append(payload, byte(padding))
	}
	for offset := 0; offset < len(payload); offset += 16 {
		a := binary.LittleEndian.Uint64(payload[offset:])
		b := binary.LittleEndian.Uint64(payload[offset+8:])
		for _, key := range rounds {
			b = key ^ (a + bits.RotateLeft64(b, -8))
			a = b ^ bits.RotateLeft64(a, 3)
		}
		binary.LittleEndian.PutUint64(payload[offset:], a)
		binary.LittleEndian.PutUint64(payload[offset+8:], b)
	}
	return base64.StdEncoding.EncodeToString(append(hongguoLE(nonce), payload...))
}

func hongguoProof(branch, stamp uint32, queryHash [32]byte, bodyHash [16]byte) []byte {
	group := int((branch&15)-2) / 3
	seed := [5]uint32{2306929307, 3948190847, 2961647323, 3557602790, 3908393444}[group] + stamp
	shift := (seed + 5) & 7
	payload := append(append([]byte(nil), queryHash[:]...), bodyHash[:]...)
	payload = append(payload, hongguoLE(stamp)...)
	for _, b := range []byte{0x84, 0x96, 0x77, 0x9d, 0xd4, 0x15, 0x0b, 0xf8} {
		payload = append(payload, byte((257*uint32(b))>>shift))
	}
	payload = append(payload, 160, 1, 0, 0)
	initial := [4]uint32{2044785403, 3367314800, 3955423437, 2081443219}
	mask := [4]uint32{431900774, 3898181300, 3785044590, 1909577684}
	for i := range initial {
		initial[i] = bits.RotateLeft32(initial[i], -int(seed&31))
		mask[i] = bits.RotateLeft32(mask[i], -int((seed+6)&31))
	}
	rotation := [4][4]int{{7, 12, 17, 22}, {5, 9, 14, 20}, {4, 11, 16, 23}, {6, 10, 15, 21}}
	a, b, c, d := initial[0], initial[1], initial[2], initial[3]
	for round := 0; round < 64; round++ {
		phase := round / 16
		var mixed uint32
		switch phase {
		case 0:
			mixed = b&c | ^b&d
		case 1:
			mixed = b&d | c&^d
		case 2:
			mixed = b ^ c ^ d
		case 3:
			mixed = c ^ (b | ^d)
		}
		word := hongguoWordOrder[group*64+round]
		input := a + mixed + binary.LittleEndian.Uint32(payload[int(word)*4:]) + bits.RotateLeft32(hongguoRoundConstants[round], -int((seed+1)&31))
		next := b + bits.RotateLeft32(input, rotation[phase][round%4])
		a, d, c, b = d, c, b, next
	}
	out := make([]byte, 20)
	for i, value := range [4]uint32{a, b, c, d} {
		binary.LittleEndian.PutUint32(out[i*4:], (initial[i]+value)^mask[i])
	}
	checksum := uint32(539100192)
	for i, value := range out[:12] {
		if i%2 == 0 {
			checksum = checksum>>3 ^ checksum ^ uint32(value) ^ checksum<<7
		} else {
			checksum = checksum>>5 ^ checksum ^ ^(uint32(value) | checksum<<11)
		}
	}
	binary.LittleEndian.PutUint32(out[16:], 16777216^(4|checksum))
	return out
}

type hongguoProto []byte

func (p *hongguoProto) integer(field uint64, value int64) {
	*p = binary.AppendUvarint(*p, field<<3)
	*p = binary.AppendUvarint(*p, uint64(value<<1)^uint64(value>>63))
}

func (p *hongguoProto) bytes(field uint64, value []byte) {
	if len(value) == 0 {
		return
	}
	*p = binary.AppendUvarint(*p, field<<3|2)
	*p = binary.AppendUvarint(*p, uint64(len(value)))
	*p = append(*p, value...)
}

func (p *hongguoProto) text(field uint64, value string) {
	p.bytes(field, []byte(value))
}

func hongguoDeviceProto(device string) []byte {
	var p hongguoProto
	p.integer(1, 1)
	p.integer(2, 2)
	for i, value := range []string{"8662", device, "Ai6svO3PyrwDOUSmO6ZcResxu", "!noperm!"} {
		p.text(uint64(i+3), value)
	}
	p.integer(7, -888888)
	p.integer(8, -888888)
	p.integer(9, 3)
	p.integer(10, -888888)
	p.text(11, "!notset!")
	p.text(12, "Asia/Shanghai,8")
	p.text(13, "zh_CN")
	p.integer(14, 4)
	for i, value := range []float32{255.24993896484375, 35.58599090576172, 3.467449188232422, 3.467449188232422, 255.1754913330078, 42.17544174194336} {
		p = binary.AppendUvarint(p, uint64(i+16)<<3|5)
		p = append(p, hongguoLE(math.Float32bits(value))...)
	}
	p.text(22, "16")
	p.integer(23, 41)
	p.integer(24, 36)
	for i := uint64(25); i <= 28; i++ {
		value := int64(1728388016635)
		if i == 28 {
			value += 2
		}
		p.integer(i, value)
	}
	p.integer(29, -1)
	for i, value := range []string{"25053RT47C", "Redmi", "25053RT47C", "25053RT47C", "Redmi", "Redmi", "Redmi"} {
		p.text(uint64(i+30), value)
	}
	p.integer(38, 31)
	return p
}

func hongguoMessage(query, device string, stamp, nonce uint32, queryHash [32]byte, bodyHash [16]byte, proof []byte) []byte {
	var clock, environment, counters, p hongguoProto
	clock.integer(1, int64(stamp))
	clock.integer(2, -2)
	clock.integer(4, 200)
	environment.integer(1, 110)
	environment.integer(2, 146331399)
	environment.integer(3, 146331396)
	environment.integer(5, 7)
	environment.text(6, "v04.06.04.03-bugfix")
	environment.integer(7, 11001)
	environment.bytes(12, hongguoDeviceProto(device))
	environment.bytes(13, clock)
	environment.text(14, "7.3.5.32")
	counters.integer(1, 111)
	counters.integer(2, 10)
	counters.integer(3, 694367)
	counters.integer(5, 586952199)
	p.bytes(1, []byte{0xf7, 0xe8, 0x5f, 0xfa, 0xd7, 0xd7, 0xdc, 0x3b, 0xd6, 0x2a, 0xc8, 0x70, 0x57, 0xcf, 0x61, 0x18})
	p.integer(2, 3)
	p.integer(3, int64(nonce))
	p.text(4, "8662")
	p.text(5, device)
	p.text(6, "1588093228")
	p.text(7, "7.3.5.32")
	p.text(8, "v04.06.04-ml-android")
	p.integer(9, 67503104)
	p.bytes(10, []byte{64, 1, 0, 0, 0, 0, 0, 0})
	p.integer(12, int64(stamp))
	p.bytes(13, proof)
	p.bytes(14, queryHash[:6])
	p.bytes(15, counters)
	p.text(16, "AXYQOS6n2m60x1fVZHIrH3iol")
	p.integer(17, int64(stamp))
	combined := append(append([]byte(query), bodyHash[:]...), []byte("none")...)
	digest := cryptoutil.SM3(combined)
	p.bytes(19, digest[:])
	p.text(20, "none")
	p.integer(21, 312)
	p.bytes(23, environment)
	p.text(24, "{\"cmr\":16777216,\"cmr2\":16777216,\"un_h\":1879194040,\"vpn\":0,\"kd\":0,\"fkd\":3672518972,\"pd\":-1872573247,\"dyn\":\"\",\"do\":0,\"tk\":true}")
	return p
}

func hongguoScramble(message []byte, key [32]byte) []byte {
	out := make([]byte, len(message))
	for i, value := range message {
		offset := (4 * i) & 28
		a, b := key[offset], key[offset+1]
		x := ^(bits.RotateLeft8(value, 4) + a) ^ b
		x = bits.RotateLeft8(x, 3) + b
		out[len(out)-1-i] = x ^ ^a
	}
	mix, initial := out[0]^out[1], out[0]
	out[0] += ^mix
	out[1] += out[0] ^ out[len(out)-1] ^ 254
	out[2] += (mix - initial) ^ bits.RotateLeft8(out[1], 3) ^ 2
	for i := 0; i < len(out)-4; i++ {
		out[i+3] += bits.RotateLeft8(out[i+2], 3) ^ out[i+1] ^ ^byte(i+3)
	}
	out[len(out)-1] ^= out[len(out)-2]
	var sum byte
	for _, value := range out[1:] {
		sum += value
	}
	out[0] = (out[0] ^ out[1]) + sum
	return out
}

func hongguoV3(payload []byte, stamp uint32) []byte {
	mode := int(stamp & 3)
	box := hongguoSBoxes[mode*256 : (mode+1)*256]
	columns := [4][4]int{{1, 0, 2, 3}, {2, 0, 3, 1}, {0, 1, 3, 2}, {1, 0, 2, 3}}[mode]
	order := [4][16]int{
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
		{0, 9, 14, 15, 4, 13, 2, 7, 8, 1, 6, 3, 12, 5, 10, 11},
		{0, 9, 14, 7, 4, 13, 2, 11, 8, 1, 6, 3, 12, 5, 10, 15},
		{0, 9, 14, 11, 4, 13, 2, 7, 8, 1, 6, 15, 12, 5, 10, 3},
	}[mode]
	seed := [4]uint32{3389152732, 2185086278, 3376547203, 3264750175}[mode]
	var key [48]byte
	for i, value := range []byte{0xf1, 0x59, 0x33, 0x76, 0x76, 0x6e, 0xa9, 0x8d, 0x34, 0xf3, 0x1b, 0x05, 0x7a, 0x9d, 0x5b, 0xe4} {
		key[i] = value ^ byte(seed>>uint(i%4*8))
	}
	for word, bit := 4, uint(8); word < 12; word, bit = word+1, bit+2 {
		part := [4]byte{}
		copy(part[:], key[word*4-4:word*4])
		if word%4 == 0 {
			part = [4]byte{byte(seed>>(bit&24)) ^ box[part[1]], box[part[2]], box[part[3]], box[part[0]]}
		}
		for i := range part {
			key[word*4+i] = part[i] ^ key[word*4+i-16]
		}
	}
	encrypt := func(input [16]byte) [16]byte {
		addKey := func(offset int) {
			for i := range input {
				input[i] ^= key[offset+4*(i/4)+columns[i%4]]
			}
		}
		addKey(0)
		for round := 1; round <= 2; round++ {
			previous := input
			for i := range input {
				index := order[i]
				input[i] = box[previous[4*columns[index/4]+index%4]]
			}
			if round == 1 {
				previous = input
				for i := range input {
					input[i] = previous[4*(i/4)+columns[i%4]]
				}
				double := func(value byte) byte {
					if value&128 != 0 {
						return value<<1 ^ 27
					}
					return value << 1
				}
				for column := 0; column < 4; column++ {
					a, b, c, d := input[column], input[4+column], input[8+column], input[12+column]
					sum := a ^ b ^ c ^ d
					input[column] ^= sum ^ double(a^b)
					input[4+column] ^= sum ^ double(b^c)
					input[8+column] ^= sum ^ double(c^d)
					input[12+column] ^= sum ^ double(d^a)
				}
			}
			addKey(16 * round)
		}
		for i := range input {
			input[i] ^= key[16+i]
		}
		return input
	}
	var extracted [32]byte
	for i := 0; i < 31; i++ {
		group := payload[i*8 : i*8+8]
		extracted[i] = group[0]>>4&2 | group[1]&64 | group[2]>>2&1 | group[3]<<3&128 | group[4]>>1&4 | group[5]<<3&16 | group[6]<<5&32 | group[7]>>4&8
	}
	extracted[31] = 1
	iv := [16]byte{0x1f, 0xe1, 0x09, 0xa4, 0x12, 0x52, 0x83, 0xf4, 0x18, 0xde, 0x9e, 0x05, 0x1a, 0x96, 0x9e, 0x12}
	var encrypted [32]byte
	for offset := 0; offset < 32; offset += 16 {
		for i := range iv {
			iv[i] ^= extracted[offset+i]
		}
		iv = encrypt(iv)
		copy(encrypted[offset:], iv[:])
	}
	out := append([]byte{encrypted[31]}, payload...)
	for i := 0; i < 31; i++ {
		group, value := out[1+8*i:1+8*i+8], encrypted[i]
		group[0] = group[0]&^32 | value<<4&32
		group[1] = group[1]&^64 | value&64
		group[2] = group[2]&^4 | value<<2&4
		group[3] = group[3]&^16 | value>>3&16
		group[4] = group[4]&^8 | value<<1&8
		group[5] = group[5]&^2 | value>>3&2
		group[6] = group[6]&^1 | value>>5&1
		group[7] = group[7]&127 | value<<4&128
	}
	return out
}

func hongguoMedusa(query string, stamp uint32, nonce [4]uint32, device string, branch uint32, queryHash [32]byte, bodyHash [16]byte) []byte {
	proof := hongguoProof(branch, stamp, queryHash, bodyHash)
	message := hongguoMessage(query, device, stamp, nonce[0], queryHash, bodyHash, proof)
	material := []byte{0x8e, 0xbd, 0xfa, 0x38, 0x06, 0xec, 0xc5, 0xce, 0xe7, 0x94, 0x23, 0xe6, 0x02, 0x9e, 0xd8, 0x25, 0x40, 0xbc, 0x22, 0x18, 0xbb, 0x7e, 0xae, 0xf7, 0x1c, 0xb6, 0x91, 0xf7, 0xaa, 0x8a, 0xa2, 0xf5}
	derived := cryptoutil.SM3(append(append(append([]byte(nil), material...), hongguoLE(nonce[1])...), material...))
	value := (nonce[1] >> 16) & 255
	mask := hongguoLE(^((value<<11 | nonce[1]>>24) ^ value>>5 ^ value))
	data := append([]byte{64, 1, 0, 0, 0, 0, 0, 0}, hongguoScramble(message, derived)...)
	for left, right := 0, len(data)-1; left < right; left, right = left+1, right-1 {
		data[left], data[right] = data[right], data[left]
	}
	for i := range data {
		data[i] ^= mask[(^i)&3]
	}
	flags := uint32(402653185) | uint32(queryHash[0]&63)<<14 | uint32(proof[0]&63)<<8
	wrapped := append([]byte{53}, hongguoLE(nonce[2])...)
	wrapped = append(wrapped, hongguoLE(flags)...)
	wrapped = append(wrapped, data...)
	wrapped = append(wrapped, hongguoLE(nonce[1])[2:]...)
	encrypted := hongguoV3(wrapped, stamp)
	prefix := []byte{3, 0, 0, 0, 0xf7, 0xe8, 0x5f, 0xfa, 0xd7, 0xd7, 0xdc, 0x3b, 0xd6, 0x2a, 0xc8, 0x70, 0x57, 0xcf, 0x61, 0x18}
	for offset := 0; offset < len(prefix); offset += 4 {
		binary.LittleEndian.PutUint32(prefix[offset:], binary.LittleEndian.Uint32(prefix[offset:])^stamp)
	}
	prefix = append(prefix, hongguoLE(nonce[1])[:2]...)
	prefix = append(prefix, 0, 1)
	return append(prefix, encrypted...)
}
