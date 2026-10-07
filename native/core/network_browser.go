package core

import (
	"context"
	"crypto/tls"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	fhttp "github.com/bogdanfinn/fhttp"
	tlsclient "github.com/bogdanfinn/tls-client"
	"github.com/bogdanfinn/tls-client/profiles"
	"golang.org/x/net/publicsuffix"
)

const huangguoBrowserProfile = "Chrome 150"

type browserHTTPClient interface {
	Do(*fhttp.Request) (*fhttp.Response, error)
	CloseIdleConnections()
}

type huangguoBrowserTransport struct {
	base      http.RoundTripper
	router    *proxyRouter
	host      string
	source    string
	insecure  bool
	record    func(diagnosticEvent)
	mu        sync.Mutex
	clients   map[string]browserHTTPClient
	newClient func(string) (browserHTTPClient, error)
}

func newHuangguoBrowserTransport(base http.RoundTripper, downloader *Downloader) *huangguoBrowserTransport {
	configured, _ := url.Parse(downloader.providerBaseURL(sourceHuangguoVideo))
	transport := &huangguoBrowserTransport{
		base: base, router: downloader.proxyRouter, host: configured.Host, source: sourceHuangguoVideo,
		insecure: downloader.cfg.InsecureTLS, record: downloader.recordDiagnostic,
		clients: make(map[string]browserHTTPClient),
	}
	transport.newClient = transport.createClient
	return transport
}

type subscriptionBrowserKey struct{}
type subscriptionBrowserSourceKey struct{}

func newSubscriptionBrowserTransport(base http.RoundTripper, downloader *Downloader) *huangguoBrowserTransport {
	transport := &huangguoBrowserTransport{base: base, router: downloader.proxyRouter, source: "subscription", insecure: downloader.cfg.InsecureTLS, record: downloader.recordDiagnostic, clients: make(map[string]browserHTTPClient)}
	transport.newClient = transport.createClient
	return transport
}
func subscriptionBrowserContext(ctx context.Context, source ...string) context.Context {
	ctx = context.WithValue(ctx, subscriptionBrowserKey{}, true)
	if len(source) > 0 && source[0] != "" {
		ctx = context.WithValue(ctx, subscriptionBrowserSourceKey{}, source[0])
	}
	return ctx
}

func subscriptionBrowserSource(ctx context.Context, fallback string) string {
	if source, ok := ctx.Value(subscriptionBrowserSourceKey{}).(string); ok && source != "" {
		return source
	}
	return fallback
}

func (transport *huangguoBrowserTransport) matches(request *http.Request) bool {
	return (request.Method == http.MethodGet || request.Method == http.MethodHead) &&
		(request.URL.Scheme == "http" || request.URL.Scheme == "https") &&
		(request.Context().Value(subscriptionBrowserKey{}) == true || transport.host != "" && (strings.EqualFold(request.URL.Host, transport.host) || strings.EqualFold(request.URL.Hostname(), "huangguo.video")))
}

func (transport *huangguoBrowserTransport) createClient(proxy string) (browserHTTPClient, error) {
	idleTimeout := 90 * time.Second
	options := []tlsclient.HttpClientOption{
		tlsclient.WithClientProfile(profiles.Chrome_150),
		tlsclient.WithRandomTLSExtensionOrder(),
		tlsclient.WithDisableHttp3(),
		tlsclient.WithNotFollowRedirects(),
		tlsclient.WithTimeoutSeconds(45),
		tlsclient.WithProxyUrl(proxy),
		tlsclient.WithCookieJar(tlsclient.NewCookieJar()),
		tlsclient.WithTransportOptions(&tlsclient.TransportOptions{
			IdleConnTimeout: &idleTimeout, MaxIdleConns: 8, MaxIdleConnsPerHost: 4,
			MaxResponseHeaderBytes: 1 << 20,
		}),
	}
	if transport.insecure {
		options = append(options, tlsclient.WithInsecureSkipVerify())
	}
	return tlsclient.NewHttpClient(tlsclient.NewNoopLogger(), options...)
}

func (transport *huangguoBrowserTransport) client(request *http.Request) (browserHTTPClient, error) {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	proxy, err := transport.router.proxy(request)
	if err != nil {
		return nil, err
	}
	proxyURL := ""
	if proxy != nil {
		proxyURL = proxy.String()
	}
	key := request.URL.Scheme + "://" + strings.ToLower(request.URL.Host) + "|" + proxyURL
	if client := transport.clients[key]; client != nil {
		return client, nil
	}
	client, err := transport.newClient(proxyURL)
	if err != nil {
		return nil, err
	}
	if len(transport.clients) >= 8 {
		for key, old := range transport.clients {
			old.CloseIdleConnections()
			delete(transport.clients, key)
			break
		}
	}
	transport.clients[key] = client
	return client, nil
}

func huangguoBrowserHeaders(request *http.Request) fhttp.Header {
	subscriptionBrowser := request.Context().Value(subscriptionBrowserKey{}) == true
	headers := fhttp.Header{
		"sec-ch-ua":                 {`"Chromium";v="150", "Google Chrome";v="150", "Not_A Brand";v="24"`},
		"sec-ch-ua-mobile":          {"?0"},
		"sec-ch-ua-platform":        {`"macOS"`},
		"upgrade-insecure-requests": {"1"},
		"user-agent":                {"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"},
		"accept":                    {"text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8"},
		"sec-fetch-site":            {"same-origin"},
		"sec-fetch-mode":            {"navigate"},
		"sec-fetch-user":            {"?1"},
		"sec-fetch-dest":            {"document"},
		"accept-language":           {"zh-CN,zh;q=0.9"},
		fhttp.HeaderOrderKey:        {"sec-ch-ua", "sec-ch-ua-mobile", "sec-ch-ua-platform", "upgrade-insecure-requests", "user-agent", "accept", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-user", "sec-fetch-dest", "referer", "accept-encoding", "accept-language", "cookie"},
	}
	if userAgent := request.Header.Get("User-Agent"); subscriptionBrowser && userAgent != "" {
		headers["user-agent"] = []string{userAgent}
		switch {
		case strings.Contains(userAgent, "Windows NT"):
			headers["sec-ch-ua-platform"] = []string{`"Windows"`}
		case strings.Contains(userAgent, "Macintosh") || strings.Contains(userAgent, "Mac OS X"):
			headers["sec-ch-ua-platform"] = []string{`"macOS"`}
		case strings.Contains(userAgent, "Android"):
			headers["sec-ch-ua-platform"] = []string{`"Android"`}
		case strings.Contains(userAgent, "Linux"):
			headers["sec-ch-ua-platform"] = []string{`"Linux"`}
		}
	}
	if mode := request.Header.Get("Sec-Fetch-Mode"); mode != "" && mode != "navigate" {
		headers["accept"] = []string{firstNonEmpty(request.Header.Get("Accept"), "*/*")}
		headers["sec-fetch-mode"] = []string{mode}
		headers["sec-fetch-dest"] = []string{firstNonEmpty(request.Header.Get("Sec-Fetch-Dest"), "empty")}
		delete(headers, "upgrade-insecure-requests")
		delete(headers, "sec-fetch-user")
	}
	for key, values := range request.Header {
		lower := strings.ToLower(key)
		if subscriptionBrowser && (lower == "user-agent" || lower == "accept") {
			headers[lower] = append([]string(nil), values...)
			continue
		}
		if _, fixed := headers[lower]; fixed || lower == "host" || lower == "connection" {
			continue
		}
		headers[lower] = append([]string(nil), values...)
	}
	if referer := request.Header.Get("Referer"); referer == "" {
		headers["sec-fetch-site"] = []string{"none"}
	} else if parsed, err := url.Parse(referer); err == nil && providerMediaOrigin(parsed) != providerMediaOrigin(request.URL) {
		if browserSameSite(parsed, request.URL) {
			headers["sec-fetch-site"] = []string{"same-site"}
		} else {
			headers["sec-fetch-site"] = []string{"cross-site"}
		}
	}
	return headers
}

func browserSameSite(left, right *url.URL) bool {
	if left == nil || right == nil || !strings.EqualFold(left.Scheme, right.Scheme) {
		return false
	}
	leftDomain, leftErr := publicsuffix.EffectiveTLDPlusOne(strings.TrimSuffix(strings.ToLower(left.Hostname()), "."))
	rightDomain, rightErr := publicsuffix.EffectiveTLDPlusOne(strings.TrimSuffix(strings.ToLower(right.Hostname()), "."))
	if leftErr != nil || rightErr != nil {
		return strings.EqualFold(left.Hostname(), right.Hostname())
	}
	return leftDomain == rightDomain
}

func standardBrowserHeaders(headers fhttp.Header) http.Header {
	result := make(http.Header, len(headers))
	for key, values := range headers {
		result[http.CanonicalHeaderKey(key)] = append([]string(nil), values...)
	}
	return result
}

func (transport *huangguoBrowserTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if !transport.matches(request) {
		return transport.base.RoundTrip(request)
	}
	client, err := transport.client(request)
	if err != nil {
		return nil, fmt.Errorf("浏览器兼容客户端初始化失败：%w", publicError(err))
	}
	upstream, err := fhttp.NewRequestWithContext(request.Context(), request.Method, request.URL.String(), request.Body)
	if err != nil {
		return nil, err
	}
	upstream.Header = huangguoBrowserHeaders(request)
	upstream.Host = request.Host
	upstream.ContentLength = request.ContentLength
	upstream.GetBody = request.GetBody
	response, err := client.Do(upstream)
	if err != nil {
		if response != nil && response.Body != nil {
			response.Body.Close()
		}
		return nil, publicError(err)
	}
	result := &http.Response{
		Status: response.Status, StatusCode: response.StatusCode,
		Proto: response.Proto, ProtoMajor: response.ProtoMajor, ProtoMinor: response.ProtoMinor,
		Header: standardBrowserHeaders(response.Header), Body: response.Body,
		ContentLength: response.ContentLength, TransferEncoding: response.TransferEncoding,
		Close: response.Close, Uncompressed: response.Uncompressed,
		Trailer: standardBrowserHeaders(response.Trailer), Request: request,
	}
	if state := response.TLS; state != nil {
		result.TLS = &tls.ConnectionState{Version: state.Version, HandshakeComplete: state.HandshakeComplete,
			DidResume: state.DidResume, CipherSuite: state.CipherSuite, NegotiatedProtocol: state.NegotiatedProtocol,
			ServerName: state.ServerName, PeerCertificates: state.PeerCertificates, VerifiedChains: state.VerifiedChains}
	}
	if transport.record != nil {
		level := "info"
		if result.StatusCode >= 400 || strings.EqualFold(result.Header.Get("Cf-Mitigated"), "challenge") {
			level = "warning"
		}
		transport.record(diagnosticEvent{Event: "network.browser_request", Level: level, Source: subscriptionBrowserSource(request.Context(), transport.source),
			Host: request.URL.Hostname(), HTTPStatus: result.StatusCode, Client: huangguoBrowserProfile,
			Protocol: result.Proto, CFRay: truncate(result.Header.Get("Cf-Ray"), 128),
			FetchMode: request.Header.Get("Sec-Fetch-Mode"), FetchDest: request.Header.Get("Sec-Fetch-Dest"),
			ResponseType: truncate(result.Header.Get("Content-Type"), 128), Message: "浏览器指纹请求完成"})
	}
	return result, nil
}

func (transport *huangguoBrowserTransport) CloseIdleConnections() {
	transport.mu.Lock()
	for key, client := range transport.clients {
		client.CloseIdleConnections()
		delete(transport.clients, key)
	}
	transport.mu.Unlock()
	if closer, ok := transport.base.(interface{ CloseIdleConnections() }); ok {
		closer.CloseIdleConnections()
	}
}
