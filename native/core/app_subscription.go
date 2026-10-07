package core

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"time"

	"duanjuapp/native/sourcevm"
)

type subscriptionPackage struct {
	ID                 string   `json:"id"`
	API                int      `json:"api"`
	Program            string   `json:"program"`
	Domains            []string `json:"domains"`
	Capabilities       []string `json:"capabilities"`
	CredentialRequired bool     `json:"credentialRequired"`
	Browser            bool     `json:"browser"`
}
type subscriptionMedia struct {
	nativePlan
	Manifest     string              `json:"manifest"`
	ManifestType string              `json:"manifestType"`
	MediaCookies []string            `json:"mediaCookies"`
	Source       string              `json:"source"`
	Browser      bool                `json:"browser"`
	Rewrite      bool                `json:"rewrite"`
	Variants     []subscriptionMedia `json:"variants"`
}

var subscriptionID = regexp.MustCompile(`^[a-z][a-z0-9-]{0,63}$`)
var subscriptionDigest = regexp.MustCompile(`^[a-f0-9]{64}$`)

type subscriptionHTTPRequest struct {
	Source            string            `json:"source"`
	Operation         string            `json:"operation"`
	URL               string            `json:"url"`
	Binary            bool              `json:"binary"`
	Method            string            `json:"method"`
	Headers           map[string]string `json:"headers"`
	Body              string            `json:"body"`
	Domains           []string          `json:"domains"`
	Cookie            string            `json:"cookie"`
	CredentialDomains []string          `json:"credentialDomains"`
	Background        bool              `json:"background"`
	Browser           bool              `json:"browser"`
}

func (engine *nativeEngine) subscriptionHTTP(ctx context.Context, raw json.RawMessage) (map[string]any, error) {
	var command subscriptionHTTPRequest
	if len(raw) > 2<<20 || json.Unmarshal(raw, &command) != nil {
		return nil, errors.New("订阅请求格式无效")
	}
	address, err := subscriptionURL(ctx, command.URL)
	if err != nil {
		return nil, err
	}
	if !slices.Contains(command.Domains, address.Hostname()) || len(command.Domains) > 30 {
		return nil, errors.New("请求超出订阅声明域名")
	}
	if command.Method != "GET" && command.Method != "POST" || len(command.Body) > 1<<20 {
		return nil, errors.New("请求方法或长度无效")
	}
	if command.Background {
		ctx = context.WithValue(ctx, backgroundCatalogKey{}, true)
	}
	if command.Browser && command.Cookie == "" {
		source := command.Source
		if !subscriptionID.MatchString(source) {
			source = "subscription"
		}
		ctx = subscriptionBrowserContext(ctx, source)
	}
	request, err := http.NewRequestWithContext(ctx, command.Method, command.URL, strings.NewReader(command.Body))
	if err != nil {
		return nil, errors.New("请求地址无效")
	}
	for key, value := range command.Headers {
		switch strings.ToLower(key) {
		case "user-agent", "accept", "accept-language", "referer", "origin", "content-type", "authorization", "x-gorgon", "x-khronos", "x-ss-req-ticket", "x-ss-stub", "sdk-version", "x-xs-from-web", "temp", "x-user-agent":
			if len(value) > 16384 {
				return nil, errors.New("请求头过大")
			}
			request.Header.Set(key, value)
		default:
			return nil, errors.New("请求头不受支持")
		}
	}
	if command.Cookie != "" {
		allowedReadPost := command.Method == "POST" &&
			address.Hostname() == "www.douyin.com" &&
			address.Path == "/aweme/v2/web/module/feed/" && command.Body == ""
		if command.Method != "GET" && !allowedReadPost {
			return nil, errors.New("账号订阅仅支持读取请求")
		}
		if !slices.Contains(command.CredentialDomains, address.Hostname()) || len(command.Cookie) > 65536 {
			return nil, errors.New("凭据域名无效")
		}
		request.Header.Set("Cookie", command.Cookie)
	}
	release, err := engine.downloader.limiter.acquire(ctx, request)
	if err != nil {
		return nil, err
	}
	defer release()
	client := *engine.downloader.client
	client.Jar = nil
	client.Timeout = 15 * time.Second
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return errors.New("订阅请求不允许重定向") }
	response, err := client.Do(request)
	if err != nil {
		return nil, errors.New("站源连接失败或已取消")
	}
	defer response.Body.Close()
	engine.downloader.limiter.observe(request, response)
	if response.StatusCode >= 400 {
		source := command.Source
		if !subscriptionID.MatchString(source) {
			source = ""
		}
		operation := "request"
		switch command.Operation {
		case "catalog", "categories", "search", "detail", "resolve", "live", "creator", "comments", "danmaku":
			operation = command.Operation
		}
		engine.downloader.recordDiagnostic(diagnosticEvent{Event: "subscription_http", Source: source, Host: address.Hostname(), HTTPStatus: response.StatusCode, Message: "站源接口请求被拒绝，操作：" + operation})
	}
	limit := int64(8 << 20)
	if command.Binary {
		limit = 1 << 20
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
	if err != nil || int64(len(body)) > limit {
		return nil, errors.New("站源响应过大或超时")
	}
	cookies := []string{}
	for _, cookie := range response.Cookies() {
		if strings.HasPrefix(cookie.Name, "CloudFront-") {
			cookies = append(cookies, cookie.Name+"="+cookie.Value)
		}
	}
	text := string(body)
	if command.Binary {
		text = ""
	}
	result := map[string]any{"status": response.StatusCode, "text": text, "mediaCookies": cookies, "retryAfter": response.Header.Get("Retry-After")}
	if command.Binary {
		result["base64"] = base64.StdEncoding.EncodeToString(body)
	}
	return result, nil
}
func (engine *nativeEngine) subscriptionPackage(id string) (subscriptionPackage, error) {
	var result subscriptionPackage
	if !subscriptionID.MatchString(id) {
		return result, errors.New("站源标识无效")
	}
	root := filepath.Join(engine.directory, "source-subscriptions")
	registry, err := os.ReadFile(filepath.Join(root, "registry.json"))
	if err != nil || len(registry) > 512<<10 {
		return result, errors.New("请先导入站源订阅")
	}
	var records []struct {
		ID     string `json:"id"`
		Digest string `json:"digest"`
	}
	if json.Unmarshal(registry, &records) != nil {
		return result, errors.New("站源订阅目录无法读取")
	}
	for _, record := range records {
		if record.ID != id {
			continue
		}
		if !subscriptionDigest.MatchString(record.Digest) {
			break
		}
		raw, err := os.ReadFile(filepath.Join(root, id+"-"+record.Digest+".json"))
		if err != nil || len(raw) > 2<<20 {
			break
		}
		sum := sha256.Sum256(raw)
		if hex.EncodeToString(sum[:]) != record.Digest || json.Unmarshal(raw, &result) != nil || result.ID != id || result.API != 1 {
			break
		}
		return result, nil
	}
	return subscriptionPackage{}, errors.New("站源未安装或校验失败")
}

type subscriptionAddressCacheKey struct{}

func subscriptionURL(ctx context.Context, raw string) (*url.URL, error) {
	address, err := url.Parse(raw)
	if err != nil || address.Scheme != "https" || address.User != nil || address.Hostname() == "" || address.Port() != "" && address.Port() != "443" {
		return nil, errors.New("媒体地址必须为 HTTPS")
	}
	cache, _ := ctx.Value(subscriptionAddressCacheKey{}).(map[string]bool)
	if cache[address.Hostname()] {
		return address, nil
	}
	addresses, err := net.DefaultResolver.LookupIPAddr(ctx, address.Hostname())
	if err != nil || len(addresses) == 0 {
		return nil, errors.New("媒体域名无法解析")
	}
	for _, item := range addresses {
		if item.IP.IsLoopback() || item.IP.IsPrivate() || item.IP.IsLinkLocalUnicast() || item.IP.IsUnspecified() || item.IP.IsMulticast() || subscriptionCarrierAddress(item.IP) {
			return nil, errors.New("订阅不能访问本机或内网")
		}
	}
	if cache != nil {
		cache[address.Hostname()] = true
	}
	return address, nil
}
func subscriptionCarrierAddress(ip net.IP) bool {
	value := ip.To4()
	return value != nil && value[0] == 100 && value[1] >= 64 && value[1] <= 127
}
func subscriptionProvider(parent context.Context, raw []byte) (providerMedia, nativePlan, error) {
	var value subscriptionMedia
	if len(raw) > 2<<20 || json.Unmarshal(raw, &value) != nil {
		return providerMedia{}, nativePlan{}, errors.New("播放计划无效")
	}
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	address, err := subscriptionURL(ctx, value.URL)
	if err != nil {
		return providerMedia{}, nativePlan{}, err
	}
	for key := range value.Headers {
		if strings.ToLower(key) != "referer" && strings.ToLower(key) != "user-agent" && strings.ToLower(key) != "origin" && strings.ToLower(key) != "x-preview-token" {
			return providerMedia{}, nativePlan{}, errors.New("媒体请求头包含不支持的字段")
		}
	}
	for _, header := range value.Headers {
		if len(header) > 16384 || strings.ContainsAny(header, "\r\n") {
			return providerMedia{}, nativePlan{}, errors.New("媒体请求头无效")
		}
	}
	media := providerMedia{URL: value.URL, AudioURL: value.AudioURL, Referer: value.Headers["Referer"], Playlist: value.Manifest, PlaylistType: value.ManifestType, Quality: value.Quality}
	if value.AudioURL != "" {
		if _, err := subscriptionURL(ctx, value.AudioURL); err != nil {
			return providerMedia{}, nativePlan{}, err
		}
	}
	for _, cookie := range value.MediaCookies {
		if len(cookie) > 16384 || !strings.HasPrefix(cookie, "CloudFront-") || strings.ContainsAny(cookie, "\r\n; ") {
			return providerMedia{}, nativePlan{}, errors.New("媒体凭据格式无效")
		}
	}
	source := value.Source
	if !subscriptionID.MatchString(source) {
		source = "subscription"
	}
	media.credentials = &providerMediaCredentials{source: source, origin: providerMediaOrigin(address), cookie: strings.Join(value.MediaCookies, "; "), referer: media.Referer, userAgent: value.Headers["User-Agent"], browser: value.Browser, headers: map[string]string{}}
	for key, header := range value.Headers {
		if strings.ToLower(key) == "x-preview-token" {
			media.credentials.headers[key] = header
		}
	}
	if value.ExpiresAt > 0 {
		media.credentials.expires = time.UnixMilli(value.ExpiresAt)
	}
	if value.Key != "" {
		key, err := hex.DecodeString(value.Key)
		if err != nil || len(key) != 16 {
			return providerMedia{}, nativePlan{}, errors.New("媒体解密参数无效")
		}
		media.CENCKey = key
	}
	return media, value.nativePlan, nil
}
func (engine *nativeEngine) subscriptionPlan(ctx context.Context, raw json.RawMessage) (nativePlan, error) {
	validation, cancel := context.WithTimeout(context.WithValue(ctx, subscriptionAddressCacheKey{}, map[string]bool{}), 5*time.Second)
	defer cancel()
	media, plan, err := subscriptionProvider(validation, raw)
	if err != nil {
		return plan, err
	}
	var metadata subscriptionMedia
	if json.Unmarshal(raw, &metadata) != nil || len(metadata.Variants) > 16 {
		return plan, errors.New("播放计划无效")
	}
	if metadata.Rewrite {
		packageValue, err := engine.subscriptionPackage(metadata.Source)
		if err != nil {
			return plan, err
		}
		media.RewritePlaylist = func(body string) string {
			id := "playlist:" + time.Now().Format("150405.000000000")
			command, _ := json.Marshal(map[string]any{"command": "start", "id": id, "program": packageValue.Program, "action": "rewrite", "payload": map[string]any{"source": metadata.Source, "body": body}, "state": map[string]any{}})
			var result struct {
				OK   bool `json:"ok"`
				Data struct {
					Done  bool `json:"done"`
					Value struct {
						Manifest string `json:"manifest"`
					} `json:"value"`
				} `json:"data"`
			}
			response := sourcevm.Request(string(command))
			cancel, _ := json.Marshal(map[string]any{"command": "cancel", "id": id})
			sourcevm.Request(string(cancel))
			if json.Unmarshal([]byte(response), &result) != nil || !result.OK || !result.Data.Done || result.Data.Value.Manifest == "" {
				return ""
			}
			return result.Data.Value.Manifest
		}
	}

	for _, variant := range metadata.Variants {
		variant.Variants = nil
		variantRaw, _ := json.Marshal(variant)
		candidate, _, err := subscriptionProvider(validation, variantRaw)
		if err != nil {
			return plan, err
		}
		if metadata.Rewrite {
			candidate.RewritePlaylist = media.RewritePlaylist
		}
		if candidate.URL != media.URL || candidate.Playlist != media.Playlist {
			media.Variants = append(media.Variants, candidate)
		}
	}

	opened, err := engine.nativeOpenPlayback(ctx, nativePlaybackChoices(media, plan.Quality))
	if err != nil {
		return plan, err
	}
	if len(plan.Headers) > 0 {
		for key, value := range plan.Headers {
			opened.Headers[key] = value
		}
	}
	if len(plan.Qualities) > 0 {
		opened.Qualities = plan.Qualities
	}
	return opened, nil
}
func (engine *nativeEngine) subscriptionDownload(ctx context.Context, job nativeDownloadJob) (providerMedia, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	packageValue, err := engine.subscriptionPackage(job.Drama.Source)
	if err != nil {
		return providerMedia{}, err
	}
	if !slices.Contains(packageValue.Capabilities, "download") || packageValue.CredentialRequired {
		return providerMedia{}, errors.New("此订阅不支持后台下载")
	}
	chapter := job.Chapter.SubscriptionInput
	if len(chapter) == 0 {
		chapter, _ = json.Marshal(job.Chapter)
	}
	payload, _ := json.Marshal(map[string]any{"drama": job.Drama, "chapter": json.RawMessage(chapter), "index": job.Index, "quality": job.Quality, "source": job.Drama.Source})
	id := "download:" + job.ID + ":" + time.Now().Format("150405.000000000")
	defer func() {
		request, _ := json.Marshal(map[string]any{"command": "cancel", "id": id})
		sourcevm.Request(string(request))
	}()
	request := map[string]any{"command": "start", "id": id, "program": packageValue.Program, "action": "resolve", "payload": json.RawMessage(payload), "state": map[string]any{}}
	for step := 0; step < 16; step++ {
		if err := ctx.Err(); err != nil {
			return providerMedia{}, err
		}
		body, _ := json.Marshal(request)
		var envelope struct {
			OK   bool `json:"ok"`
			Data struct {
				Done  bool            `json:"done"`
				Value json.RawMessage `json:"value"`
			} `json:"data"`
		}
		if json.Unmarshal([]byte(sourcevm.Request(string(body))), &envelope) != nil || !envelope.OK {
			return providerMedia{}, errors.New("站源脚本执行失败，请更新订阅")
		}
		if envelope.Data.Done {
			media, _, err := subscriptionProvider(ctx, envelope.Data.Value)
			return media, err
		}
		var command struct {
			Type, URL, Method string
			Headers           map[string]string
			Body              any
			Credential, Sign  bool
		}
		if json.Unmarshal(envelope.Data.Value, &command) != nil || command.Type != "http" || command.Credential || command.Sign {
			return providerMedia{}, errors.New("订阅请求了不支持的后台能力")
		}
		text := ""
		if command.Body != nil {
			if value, ok := command.Body.(string); ok {
				text = value
			} else {
				encoded, _ := json.Marshal(command.Body)
				text = string(encoded)
			}
		}
		commandRaw, _ := json.Marshal(subscriptionHTTPRequest{URL: command.URL, Method: command.Method, Headers: command.Headers, Body: text, Domains: packageValue.Domains, Background: true, Browser: packageValue.Browser})
		response, err := engine.subscriptionHTTP(ctx, commandRaw)
		if err != nil {
			if ctx.Err() != nil {
				return providerMedia{}, ctx.Err()
			}
			response = map[string]any{"status": 0, "text": ""}
		}
		request = map[string]any{"command": "next", "id": id, "response": response}
	}
	return providerMedia{}, errors.New("站源请求次数超限")
}

func (engine *nativeEngine) subscriptionCover(ctx context.Context, input nativeInput) (any, error) {
	drama := input.Drama
	if !subscriptionID.MatchString(drama.Source) || drama.Cover == "" {
		return nil, errors.New("海报参数无效")
	}
	if _, err := subscriptionURL(ctx, drama.Cover); err != nil {
		return nil, err
	}
	engine.ensureCoverCache()
	ctx = context.WithValue(ctx, subscriptionCoverNetworkKey{}, true)
	cached, err := engine.covers.loadAddress(ctx, drama, input.Force)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(cached)
	if err != nil {
		return nil, err
	}
	header := make([]byte, 256)
	count, readErr := file.Read(header)
	file.Close()
	if readErr != nil && readErr != io.EOF {
		return nil, readErr
	}
	result := map[string]any{"path": cached, "heic": isHEICImage(header[:count])}
	if input.Command == "prepare" {
		return engine.prepareCoverResult(result)
	}
	return result, nil
}
