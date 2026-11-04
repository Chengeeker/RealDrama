package core

import (
	"context"
	"net/http"
	"net/url"
	"testing"
)

func TestDouyinSubscriptionBypassesProxy(t *testing.T) {
	manual, _ := url.Parse("http://127.0.0.1:7890")
	for _, mode := range []string{"auto", "manual"} {
		router := &proxyRouter{mode: mode, manual: manual, systemOverride: true, system: nativeSystemProxy{HTTPS: manual.String()}}
		for _, source := range []string{"douyin", "douyin-live", "douyin-series", "douyin-theater", "douyin-test", "douyin-live-test", "douyin-series-test", "douyin-theater-test", "hongguo", "bilibili", "douyin-unrelated"} {
			direct := source != "hongguo" && source != "bilibili" && source != "douyin-unrelated"
			contexts := []context.Context{
				douyinDirectContext(context.Background(), source),
				providerMediaContext(context.Background(), &providerMediaCredentials{source: source}),
			}
			for _, ctx := range contexts {
				request, _ := http.NewRequestWithContext(ctx, "GET", "https://media.example.test/video", nil)
				proxy, err := router.proxy(request)
				if err != nil || (proxy == nil) != direct {
					t.Errorf("mode=%s source=%s direct=%v proxy=%v err=%v", mode, source, direct, proxy, err)
				}
				redirect := request.Clone(ctx)
				redirect.URL, _ = url.Parse("https://backup.example.test/video")
				proxy, err = router.proxy(redirect)
				if err != nil || (proxy == nil) != direct {
					t.Errorf("redirect route changed: mode=%s source=%s", mode, source)
				}
			}
		}
	}
}
