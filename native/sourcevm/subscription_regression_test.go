package sourcevm

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func subscriptionFixture(t *testing.T, name, action string, payload, state any) (string, map[string]any) {
	t.Helper()
	root := filepath.Join("..", "..", "..", "RealDrama-Subscription", "sources", name+".json")
	body, err := os.ReadFile(root)
	if err != nil {
		t.Skip("subscription checkout unavailable")
	}
	var pkg struct {
		Program string `json:"program"`
	}
	if json.Unmarshal(body, &pkg) != nil {
		t.Fatal("invalid subscription")
	}
	id := fmt.Sprintf("subscription-regression-%d", time.Now().UnixNano())
	raw, _ := json.Marshal(map[string]any{"command": "start", "id": id, "program": pkg.Program, "action": action, "payload": payload, "state": state})
	t.Cleanup(func() { Request(fmt.Sprintf(`{"command":"cancel","id":%q}`, id)) })
	return id, requestEnvelope(t, Request(string(raw)))
}
func resumeFixture(t *testing.T, id string, text string) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"command": "next", "id": id, "response": map[string]any{"status": 200, "text": text}})
	result := requestEnvelope(t, Request(string(raw)))
	if result["ok"] != true {
		t.Fatalf("fixture failed: %#v", result)
	}
	return result["data"].(map[string]any)
}
func TestYouTubeLegacyFeedAndQuotedAssignment(t *testing.T) {
	id, start := subscriptionFixture(t, "youtube", "catalog", map[string]any{"source": "youtube", "page": 1}, map[string]any{})
	if start["ok"] != true {
		t.Fatal(start)
	}
	html := `<script>ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"fixture"}}});window["ytInitialData"] = {"contents":{"richGridRenderer":{"contents":[{"richItemRenderer":{"content":{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Fixture video"}]},"ownerText":{"runs":[{"text":"Fixture author"}]},"thumbnail":{"thumbnails":[]}}}}}]}}};</script>`
	data := resumeFixture(t, id, html)
	if data["done"] != true {
		t.Fatal("unexpected request")
	}
	value := data["value"].(map[string]any)
	items := value["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["creatorName"] != "Fixture author" {
		t.Fatal("legacy card missing")
	}
}
func TestYouTubeEmptyFeedHasSpecificSafeError(t *testing.T) {
	id, start := subscriptionFixture(t, "youtube", "catalog", map[string]any{"source": "youtube"}, map[string]any{})
	if start["ok"] != true {
		t.Fatal(start)
	}
	html := `<script>ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"fixture"}}});var ytInitialData={"contents":{"richGridRenderer":{"contents":[]}}};</script>`
	raw, _ := json.Marshal(map[string]any{"command": "next", "id": id, "response": map[string]any{"status": 200, "text": html}})
	result := requestEnvelope(t, Request(string(raw)))
	if result["ok"] != true {
		t.Fatalf("fallback not requested: %#v", result)
	}
	command := result["data"].(map[string]any)["value"].(map[string]any)
	body := command["body"].(map[string]any)
	if body["browseId"] != "FEwhat_to_watch" {
		t.Fatal("unexpected fallback")
	}
	raw, _ = json.Marshal(map[string]any{"command": "next", "id": id, "response": map[string]any{"status": 200, "text": `{"contents":{"richGridRenderer":{"contents":[]}}}`}})
	result = requestEnvelope(t, Request(string(raw)))
	if result["code"] != "youtube_feed_empty" {
		t.Fatalf("unexpected error: %#v", result)
	}
}
func TestTikTokForcedResolveReadsSpecificVideoPage(t *testing.T) {
	payload := map[string]any{"source": "tiktok", "force": true, "drama": map[string]any{"sourceId": "123456789", "creatorId": "fixture"}}
	cached := map[string]any{"rows": map[string]any{"123456789": map[string]any{"id": "123456789", "author": map[string]any{"uniqueId": "fixture"}, "video": map[string]any{"playAddr": "https://synthetic.test/old.mp4"}}}}
	id, start := subscriptionFixture(t, "tiktok", "resolve", payload, cached)
	if start["ok"] != true {
		t.Fatal(start)
	}
	command := start["data"].(map[string]any)["value"].(map[string]any)
	if !strings.Contains(command["url"].(string), "/@fixture/video/123456789") {
		t.Fatal("cached address was reused")
	}
	html := `<script id="__UNIVERSAL_DATA_FOR_REHYDRATION__" type="application/json">{"__DEFAULT_SCOPE__":{"webapp.video-detail":{"itemInfo":{"itemStruct":{"id":"123456789","author":{"uniqueId":"fixture"},"video":{"height":720,"playAddr":"https://synthetic.test/fresh.mp4"}}}}}}</script>`
	result := resumeFixture(t, id, html)["value"].(map[string]any)
	if result["browser"] != true || result["headers"].(map[string]any)["Referer"] != "https://www.tiktok.com/@fixture/video/123456789" {
		t.Fatal("media request context missing")
	}
	if result["url"] != "https://synthetic.test/fresh.mp4" {
		t.Fatal("fresh media missing")
	}
}
func TestCrjCoverNormalizesRelativeAddress(t *testing.T) {
	id, start := subscriptionFixture(t, "crj91", "catalog", map[string]any{"category": "duanju"}, map[string]any{})
	if start["ok"] != true {
		t.Fatal(start)
	}
	result := resumeFixture(t, id, `<a class="card" href="/duanju/123-fixture/" data-track-item-name="Fixture"><img data-src="/posters/fixture.webp?a=1&amp;b=2"></a>`)["value"].(map[string]any)
	items := result["items"].([]any)
	if len(items) != 1 || items[0].(map[string]any)["cover"] != "https://91crdj.com/posters/fixture.webp?a=1&b=2" {
		t.Fatal("cover address not normalized")
	}
}

func TestYouTubeSectionCardsWithoutRichGrid(t *testing.T) {
	id, _ := subscriptionFixture(t, "youtube", "catalog", map[string]any{"source": "youtube"}, map[string]any{})
	html := `<script>ytcfg.set({"INNERTUBE_CONTEXT":{"client":{"clientName":"WEB","clientVersion":"fixture"}}});var ytInitialData={"contents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[{"gridVideoRenderer":{"videoId":"abcdefghijk","title":{"simpleText":"Fixture"},"thumbnail":{"thumbnails":[]}}}]}}]}}};</script>`
	value := resumeFixture(t, id, html)["value"].(map[string]any)
	if len(value["items"].([]any)) != 1 {
		t.Fatal("section card missing")
	}
}

func TestYouTubeMediaHeadersMatchWatchRequest(t *testing.T) {
	for name, streams := range map[string]string{
		"hls":         `{"hlsManifestUrl":"https://synthetic.test/live.m3u8"}`,
		"progressive": `{"formats":[{"url":"https://synthetic.test/high.mp4","height":720,"mimeType":"video/mp4"},{"url":"https://synthetic.test/low.mp4","height":360,"mimeType":"video/mp4"}]}`,
	} {
		t.Run(name, func(t *testing.T) {
			id, start := subscriptionFixture(t, "youtube", "resolve", map[string]any{"drama": map[string]any{"sourceId": "abcdefghijk"}}, map[string]any{})
			if start["ok"] != true {
				t.Fatal(start)
			}
			command := start["data"].(map[string]any)["value"].(map[string]any)
			agent := command["headers"].(map[string]any)["User-Agent"]
			if agent == nil || agent == "" {
				t.Fatal("missing watch user agent")
			}
			data := resumeFixture(t, id, "<script>var ytInitialPlayerResponse={\"streamingData\":"+streams+"};</script>")
			if data["done"] != true {
				t.Fatal("unexpected extra request")
			}
			plan := data["value"].(map[string]any)
			check := func(value map[string]any) {
				headers := value["headers"].(map[string]any)
				if headers["User-Agent"] != agent || headers["Referer"] != "https://www.youtube.com/" {
					t.Fatal("media headers differ from watch request")
				}
				if headers["Cookie"] != nil || headers["Authorization"] != nil {
					t.Fatal("account credentials leaked to media")
				}
			}
			check(plan)
			if variants, ok := plan["variants"].([]any); ok {
				if len(variants) != 2 {
					t.Fatal("lost fallback variants")
				}
				for _, variant := range variants {
					check(variant.(map[string]any))
				}
			}
		})
	}
}
