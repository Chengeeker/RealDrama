package core

import (
	"context"
	"net/http"
	"testing"
)

func TestSubscriptionBrowserMediaContract(t *testing.T) {
	agent := "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/150.0.0.0 Safari/537.36"
	for _, fixture := range []struct{ target, site string }{
		{"https://v16-webapp-prime.us.tiktok.com/video/fixture", "same-site"},
		{"https://v16m-webapp.tiktokcdn-us.com/video/fixture", "cross-site"},
		{"http://v16-webapp-prime.us.tiktok.com/video/fixture", "cross-site"},
		{"http://www.tiktok.com/video/fixture", "cross-site"},
		{"https://www.tiktok.com:8443/video/fixture", "same-site"},
	} {
		credentials := &providerMediaCredentials{source: "tiktok", browser: true, userAgent: agent, referer: "https://www.tiktok.com/@fixture/video/1", origin: "https://www.tiktok.com", cookie: "fixture=synthetic"}
		ctx := providerMediaContext(context.Background(), credentials)
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, fixture.target, nil)
		if err != nil {
			t.Fatal(err)
		}
		if err := credentials.apply(request); err != nil {
			t.Fatal(err)
		}
		headers := standardBrowserHeaders(huangguoBrowserHeaders(request))
		if headers.Get("User-Agent") != agent || headers.Get("Sec-CH-UA-Platform") != `"Windows"` || headers.Get("Sec-Fetch-Site") != fixture.site {
			t.Fatal("browser identity or site classification changed")
		}
		if headers.Get("Accept") != "*/*" || headers.Get("Sec-Fetch-Mode") != "cors" || headers.Get("Sec-Fetch-Dest") != "empty" || headers.Get("Upgrade-Insecure-Requests") != "" {
			t.Fatal("media used navigation headers")
		}
		if headers.Get("Cookie") != "" {
			t.Fatal("account cookie leaked to CDN")
		}
		if subscriptionBrowserSource(ctx, "subscription") != "tiktok" {
			t.Fatal("wrong diagnostic source")
		}
	}
}
