package cryptoutil

import (
	"encoding/hex"
	"strings"
	"testing"
)

func TestSM3Vectors(t *testing.T) {
	for _, v := range []struct{ in, want string }{
		{"abc", "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0"},
		{strings.Repeat("abcd", 16), "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732"},
	} {
		sum := SM3([]byte(v.in))
		if hex.EncodeToString(sum[:]) != v.want {
			t.Errorf("SM3 mismatch for %q", v.in)
		}
	}
}
