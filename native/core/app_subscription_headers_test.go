package core

import (
	"encoding/base64"
	"net/url"
	"testing"
)

func TestSubscriptionHeaderPolicy(t *testing.T) {
	const host = "api5-normal-sinfonlineb.fqnovel.com"
	for _, name := range []string{"X-Helios", "x-medusa", "X-SS-DP", "X-Tt-Store-Region", "X-Tt-Store-Region-Src"} {
		if !subscriptionHeaderAllowed(name, sourceHongguo, host) {
			t.Errorf("redfruit header rejected: %s", name)
		}
		for _, row := range []struct{ source, host string }{{"bilibili", host}, {sourceHongguo, "example.com"}, {sourceHongguo, host + ".example.com"}} {
			if subscriptionHeaderAllowed(name, row.source, row.host) {
				t.Errorf("header escaped source/host restriction: %s", name)
			}
		}
	}
	if !subscriptionHeaderAllowed("User-Agent", "bilibili", "api.bilibili.com") {
		t.Error("existing header behavior changed")
	}
	if subscriptionHeaderAllowed("Cookie", sourceHongguo, host) {
		t.Error("script cookie header allowed")
	}
}

func TestSubscriptionRegistrationBoundary(t *testing.T) {
	address, _ := url.Parse("https://log5-applog-lf.fqnovel.com/service/2/device_register/")
	body := append([]byte("tc\x05\x10\x00\x00"), make([]byte, 48)...)
	command := subscriptionHTTPRequest{Source: sourceHongguo, Method: "POST", BodyBase64: base64.StdEncoding.EncodeToString(body)}
	if got, err := subscriptionRequestBody(command, address); err != nil || string(got) != string(body) {
		t.Fatal("binary request changed", err)
	}
	for _, mutate := range []func(*subscriptionHTTPRequest){
		func(c *subscriptionHTTPRequest) { c.Source = "bilibili" },
		func(c *subscriptionHTTPRequest) { c.Method = "GET" },
		func(c *subscriptionHTTPRequest) { c.Body = "text" },
		func(c *subscriptionHTTPRequest) { c.Cookie = "private" },
		func(c *subscriptionHTTPRequest) { c.BodyBase64 = "bad" },
	} {
		other := command
		mutate(&other)
		if _, err := subscriptionRequestBody(other, address); err == nil {
			t.Error("accepted invalid binary request")
		}
	}
	for _, raw := range []string{"https://log5-applog-lf.fqnovel.com/other", "https://log5-applog-lf.fqnovel.com.example/service/2/device_register/"} {
		other, _ := url.Parse(raw)
		if _, err := subscriptionRequestBody(command, other); err == nil {
			t.Error("binary body escaped endpoint boundary")
		}
	}
	for _, name := range []string{"log-encode-type", "x-vc-bdturing-sdk-version", "lc", "passport-sdk-version", "x-neptune", "x-ss-dp"} {
		if !subscriptionHeaderAllowed(name, sourceHongguo, address.Hostname()) || subscriptionHeaderAllowed(name, "bilibili", address.Hostname()) || subscriptionHeaderAllowed(name, sourceHongguo, "example.com") {
			t.Errorf("registration header boundary: %s", name)
		}
	}
	if !subscriptionHeaderAllowed("X-Medusa", sourceHongguo, "api5-normal-hl.fqnovel.com") || subscriptionHeaderAllowed("X-Medusa", sourceHongguo, address.Hostname()) {
		t.Error("model signature host boundary")
	}
}
