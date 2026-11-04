package core

import "testing"

func TestCrjDetailURLNormalizesOldAndNewHosts(t *testing.T) {
	for input, want := range map[string]string{
		"/duanju/123-sample/":                         "https://91crdjai.com/duanju/123-sample/",
		"https://91crdj.com/duanju/123-sample/1/":     "https://91crdjai.com/duanju/123-sample/1/",
		"https://www.91crdj.com/duanju/123-sample/":   "https://91crdjai.com/duanju/123-sample/",
		"https://91crdjai.com/duanju/123-sample/":     "https://91crdjai.com/duanju/123-sample/",
		"https://www.91crdjai.com/duanju/123-sample/": "https://91crdjai.com/duanju/123-sample/",
	} {
		if got := crjDetailURL(input); got != want {
			t.Errorf("crjDetailURL(%q) = %q, want %q", input, got, want)
		}
	}
	for _, input := range []string{
		"https://91crdj.com.evil.example/duanju/123-sample/",
		"https://evil.example/duanju/123-sample/",
	} {
		if got := crjDetailURL(input); got != "" {
			t.Errorf("crjDetailURL(%q) accepted an untrusted host: %q", input, got)
		}
	}
}

func TestCrjFixURLMigratesLegacySiteCovers(t *testing.T) {
	if got := crjFixURL("https://91crdj.com/static/cover.jpg"); got != "https://91crdjai.com/static/cover.jpg" {
		t.Fatalf("legacy cover URL was not migrated: %q", got)
	}
	if got := crjFixURL("https://pic.drleao.cn/cover.jpg"); got != "https://pic.drleao.cn/cover.jpg" {
		t.Fatalf("external cover host changed: %q", got)
	}
}
