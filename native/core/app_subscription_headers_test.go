package core

import "testing"

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
