package core

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"encoding/xml"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const bilibiliAPIBase = "https://api.bilibili.com"

type bilibiliCookieContextKey struct{}
type bilibiliQualityContextKey struct{}

var (
	bilibiliBVPattern    = regexp.MustCompile(`^BV[0-9A-Za-z]{10}$`)
	bilibiliTagPattern   = regexp.MustCompile(`(?s)<[^>]*>`)
	bilibiliRangePattern = regexp.MustCompile(`^\d+-\d+$`)
	bilibiliWBIIndices   = []int{
		46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35,
		27, 43, 5, 49, 33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13,
		37, 48, 7, 16, 24, 55, 40, 61, 26, 17, 0, 1, 60, 51, 30, 4,
		22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11, 36, 20, 34, 44, 52,
	}
)

type bilibiliEnvelope struct {
	Code    json.RawMessage `json:"code"`
	Message string          `json:"message"`
	Data    map[string]any  `json:"data"`
}

func validBilibiliBV(value string) bool {
	return bilibiliBVPattern.MatchString(strings.TrimSpace(value))
}

func bilibiliSafeCookie(raw string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if len(raw) > 32768 || strings.ContainsAny(raw, "\r\n") {
		return "", errors.New("哔哩哔哩 Cookie 格式无效")
	}
	for _, char := range raw {
		if char < 0x20 || char > 0x7e {
			return "", errors.New("哔哩哔哩 Cookie 格式无效")
		}
	}
	parts := strings.Split(raw, ";")
	fields := make(map[string]string, len(parts))
	for _, part := range parts {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		name, value, found := strings.Cut(part, "=")
		if !found || strings.TrimSpace(name) == "" || strings.ContainsAny(name+value, "\x00\r\n") {
			return "", errors.New("哔哩哔哩 Cookie 格式无效")
		}
		fields[strings.TrimSpace(name)] = strings.TrimSpace(value)
	}
	if fields["SESSDATA"] == "" {
		return "", errors.New("哔哩哔哩 Cookie 缺少 SESSDATA")
	}
	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	values := make([]string, 0, len(keys))
	for _, key := range keys {
		values = append(values, key+"="+fields[key])
	}
	return strings.Join(values, "; "), nil
}

func (d *Downloader) bilibiliJSON(ctx context.Context, route string, values url.Values, referer string) (map[string]any, error) {
	if !strings.HasPrefix(route, "/x/") || strings.ContainsAny(route, "\r\n?#") {
		return nil, errors.New("哔哩哔哩接口路径无效")
	}
	address := bilibiliAPIBase + route
	if len(values) > 0 {
		address += "?" + values.Encode()
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("无法创建哔哩哔哩请求")
	}
	request.Header.Set("User-Agent", userAgent)
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Origin", "https://www.bilibili.com")
	request.Header.Set("Referer", firstNonEmpty(referer, "https://www.bilibili.com/"))
	if raw, _ := ctx.Value(bilibiliCookieContextKey{}).(string); raw != "" {
		cookie, cookieErr := bilibiliSafeCookie(raw)
		if cookieErr != nil {
			return nil, cookieErr
		}
		if request.URL.Host != "api.bilibili.com" {
			return nil, errors.New("哔哩哔哩 Cookie 仅允许发送到官方 API 域名")
		}
		request.Header.Set("Cookie", cookie)
	}
	response, err := d.doCatalogRequestWithTimeout(request, providerTimeout)
	if err != nil {
		return nil, fmt.Errorf("连接哔哩哔哩失败：%w", err)
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, (8<<20)+1))
	if err != nil || len(body) > 8<<20 {
		return nil, errors.New("哔哩哔哩响应超过处理上限或读取失败")
	}
	if response.StatusCode != http.StatusOK {
		return nil, d.catalogResponseError(request, response, body)
	}
	var envelope bilibiliEnvelope
	if json.Unmarshal(body, &envelope) != nil {
		return nil, errors.New("哔哩哔哩返回了无法识别的数据")
	}
	code := strings.Trim(string(envelope.Code), `"`)
	allowAnonymousNav := route == "/x/web-interface/nav" && code == "-101" && envelope.Data != nil
	if code != "" && code != "0" && !allowAnonymousNav {
		message := truncate(strings.TrimSpace(envelope.Message), 180)
		if message == "" {
			message = "请求未获准"
		}
		return nil, fmt.Errorf("哔哩哔哩接口返回 %s：%s", code, message)
	}
	if envelope.Data == nil {
		return nil, errors.New("哔哩哔哩响应缺少 data 数据")
	}
	return envelope.Data, nil
}

func (d *Downloader) bilibiliMixinKey(ctx context.Context) (string, error) {
	d.bilibiliKeyMu.Lock()
	if d.bilibiliWBIKey != "" && time.Since(d.bilibiliWBIKeyAt) < 6*time.Hour {
		key := d.bilibiliWBIKey
		d.bilibiliKeyMu.Unlock()
		return key, nil
	}
	d.bilibiliKeyMu.Unlock()
	data, err := d.bilibiliJSON(ctx, "/x/web-interface/nav", nil, "https://www.bilibili.com/")
	if err != nil {
		return "", err
	}
	imageData, _ := data["wbi_img"].(map[string]any)
	imageURL, subURL := mapString(imageData, "img_url"), mapString(imageData, "sub_url")
	imageKey, subKey := bilibiliImageKey(imageURL), bilibiliImageKey(subURL)
	if len(imageKey) == 0 || len(subKey) == 0 {
		return "", errors.New("哔哩哔哩没有返回可用的 WBI 签名密钥")
	}
	combined := imageKey + subKey
	var mixed strings.Builder
	for _, index := range bilibiliWBIIndices {
		if index >= len(combined) {
			return "", errors.New("哔哩哔哩 WBI 密钥长度无效")
		}
		mixed.WriteByte(combined[index])
	}
	key := mixed.String()
	d.bilibiliKeyMu.Lock()
	d.bilibiliWBIKey, d.bilibiliWBIKeyAt = key, time.Now()
	d.bilibiliKeyMu.Unlock()
	return key, nil
}

func bilibiliImageKey(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Hostname() == "" {
		return ""
	}
	name := path.Base(parsed.Path)
	extension := path.Ext(name)
	return strings.TrimSuffix(name, extension)
}

func (d *Downloader) bilibiliSignedURL(ctx context.Context, route string, values url.Values) (string, error) {
	key, err := d.bilibiliMixinKey(ctx)
	if err != nil {
		return "", err
	}
	params := make(url.Values, len(values)+1)
	for name, entries := range values {
		for _, value := range entries {
			value = strings.NewReplacer("!", "", "'", "", "(", "", ")", "", "*", "").Replace(value)
			params.Add(name, value)
		}
	}
	params.Set("wts", strconv.FormatInt(time.Now().Unix(), 10))
	encoded := params.Encode()
	sum := md5.Sum([]byte(encoded + key))
	return bilibiliAPIBase + route + "?" + encoded + "&w_rid=" + hex.EncodeToString(sum[:]), nil
}

func (d *Downloader) bilibiliSignedJSON(ctx context.Context, route string, values url.Values, referer string) (map[string]any, error) {
	address, err := d.bilibiliSignedURL(ctx, route, values)
	if err != nil {
		return nil, err
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host != "api.bilibili.com" {
		return nil, errors.New("哔哩哔哩签名请求地址无效")
	}
	return d.bilibiliJSON(ctx, parsed.Path, parsed.Query(), referer)
}

func (d *Downloader) bilibiliAccount(ctx context.Context) (map[string]any, error) {
	data, err := d.bilibiliJSON(ctx, "/x/web-interface/nav", nil, "https://www.bilibili.com/")
	if err != nil {
		return nil, err
	}
	loggedIn, _ := data["isLogin"].(bool)
	name := strings.TrimSpace(mapString(data, "uname"))
	return map[string]any{"isLogin": loggedIn, "name": truncate(name, 80)}, nil
}

func (d *Downloader) fetchBilibiliCatalogPage(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	if page < 1 || page > 100000 {
		return nil, false, errors.New("哔哩哔哩分页超出接口范围")
	}
	values := url.Values{}
	values.Set("pn", strconv.Itoa(page))
	values.Set("ps", "20")
	var data map[string]any
	var err error
	if strings.TrimSpace(query) == "" {
		data, err = d.bilibiliJSON(ctx, "/x/web-interface/popular", values, "https://www.bilibili.com/")
	} else {
		values = url.Values{}
		values.Set("search_type", "video")
		values.Set("keyword", strings.TrimSpace(query))
		values.Set("page", strconv.Itoa(page))
		values.Set("page_size", "20")
		values.Set("platform", "pc")
		values.Set("web_location", "1430654")
		values.Set("order", "totalrank")
		data, err = d.bilibiliSignedJSON(ctx, "/x/web-interface/wbi/search/type", values, "https://search.bilibili.com/")
	}
	if err != nil {
		return nil, false, err
	}
	key := "list"
	if strings.TrimSpace(query) != "" {
		key = "result"
	}
	rows, ok := data[key].([]any)
	if !ok || len(rows) > 200 {
		return nil, false, errors.New("哔哩哔哩目录结构无效")
	}
	items := make([]Drama, 0, len(rows))
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		drama, valid := bilibiliDramaFromMap(row)
		if valid {
			items = append(items, drama)
		}
	}
	totalPages := bilibiliInt(data, "numPages", "num_pages")
	more := len(rows) >= 20
	if totalPages > 0 {
		more = page < min(totalPages, 100000)
	}
	if len(rows) > 0 && len(items) == 0 {
		return nil, false, errors.New("哔哩哔哩目录中没有有效的公开视频记录")
	}
	return items, more, nil
}

func bilibiliDramaFromMap(row map[string]any) (Drama, bool) {
	bvid := strings.TrimSpace(mapString(row, "bvid"))
	title := bilibiliCleanText(mapString(row, "title"))
	if !validBilibiliBV(bvid) || title == "" {
		return Drama{}, false
	}
	cover := providerCoverAddress(mapString(row, "pic"), "https://www.bilibili.com/")
	description := bilibiliCleanText(mapString(row, "desc", "description"))
	category := bilibiliCleanText(mapString(row, "typename"))
	views := bilibiliIntegerText(row["play"], row["view"])
	owner, _ := row["owner"].(map[string]any)
	stat, _ := row["stat"].(map[string]any)
	if views == "" {
		views = bilibiliIntegerText(stat["view"])
	}
	return Drama{
		ID: providerDramaID(sourceBilibili, bvid), Source: sourceBilibili, SourceID: bvid,
		Title: truncate(title, 256), Name: truncate(title, 256), Desc: truncate(description, 12000), Intro: truncate(description, 12000),
		Cover: cover, CoverURL: cover, TotalEpisode: bilibiliInt(row, "videos"), EpisodeCount: bilibiliInt(row, "videos"),
		Category: firstNonEmpty(category, "视频"), ChannelName: "哔哩哔哩", Views: views,
		CreatorID:     firstNonEmpty(bilibiliIntegerText(owner["mid"]), bilibiliIntegerText(row["mid"])),
		CreatorName:   truncate(bilibiliCleanText(firstNonEmpty(mapString(owner, "name"), mapString(row, "author"))), 80),
		CreatorAvatar: providerCoverAddress(firstNonEmpty(mapString(owner, "face"), mapString(row, "upic")), "https://www.bilibili.com/"),
	}, true
}

func (d *Downloader) fetchBilibiliDetail(ctx context.Context, bvid string) (Drama, []Chapter, error) {
	bvid = strings.TrimSpace(bvid)
	if !validBilibiliBV(bvid) {
		return Drama{}, nil, errors.New("哔哩哔哩视频 ID 无效")
	}
	values := url.Values{}
	values.Set("bvid", bvid)
	data, err := d.bilibiliSignedJSON(ctx, "/x/web-interface/wbi/view", values, "https://www.bilibili.com/video/"+bvid+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	actual := strings.TrimSpace(mapString(data, "bvid"))
	if actual != bvid {
		return Drama{}, nil, errors.New("哔哩哔哩详情与请求视频不匹配")
	}
	title := bilibiliCleanText(mapString(data, "title"))
	if title == "" {
		return Drama{}, nil, errors.New("哔哩哔哩详情缺少标题")
	}
	cover := providerCoverAddress(mapString(data, "pic"), "https://www.bilibili.com/")
	description := bilibiliCleanText(mapString(data, "desc"))
	pages, _ := data["pages"].([]any)
	if len(pages) == 0 {
		pages = []any{data}
	}
	if len(pages) > 5000 {
		return Drama{}, nil, errors.New("哔哩哔哩分 P 数量超过处理上限")
	}
	chapters := make([]Chapter, 0, len(pages))
	for index, value := range pages {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		cid := bilibiliInt64(row, "cid")
		if cid <= 0 {
			continue
		}
		page := bilibiliInt(row, "page")
		if page <= 0 {
			page = index + 1
		}
		part := bilibiliCleanText(mapString(row, "part"))
		if part == "" {
			part = fmt.Sprintf("P%d", page)
		}
		pageURL := fmt.Sprintf("https://www.bilibili.com/video/%s/?p=%d", bvid, page)
		chapters = append(chapters, Chapter{
			ID: providerChapterID(sourceBilibili, bvid, strconv.FormatInt(cid, 10)), Source: sourceBilibili,
			Title: truncate(part, 256), VideoURL: "bilibili://play/" + strconv.FormatInt(cid, 10),
			CurrentEpisode: rawEpisode(page), PageURL: pageURL, Referer: "https://www.bilibili.com/",
		})
	}
	if len(chapters) == 0 {
		return Drama{}, nil, errors.New("哔哩哔哩视频没有可用的分 P 信息")
	}
	sortProviderChapters(chapters)
	owner, _ := data["owner"].(map[string]any)
	stat, _ := data["stat"].(map[string]any)
	ownerName := truncate(bilibiliCleanText(mapString(owner, "name")), 80)
	tags := []string{}
	if ownerName != "" {
		tags = append(tags, ownerName)
	}
	drama := Drama{
		ID: providerDramaID(sourceBilibili, bvid), Source: sourceBilibili, SourceID: bvid,
		Title: truncate(title, 256), Name: truncate(title, 256), Desc: truncate(description, 12000), Intro: truncate(description, 12000),
		Cover: cover, CoverURL: cover, TotalEpisode: len(chapters), EpisodeCount: len(chapters),
		Category: firstNonEmpty(bilibiliCleanText(mapString(data, "tname")), "视频"), ChannelName: "哔哩哔哩",
		Views: bilibiliIntegerText(stat["view"]), Tags: tags,
		CreatorID: bilibiliIntegerText(owner["mid"]), CreatorName: ownerName,
		CreatorAvatar: providerCoverAddress(mapString(owner, "face"), "https://www.bilibili.com/"),
	}
	return drama, chapters, nil
}

type bilibiliRepresentation struct {
	baseURL        string
	initialization string
	indexRange     string
	mimeType       string
	codecs         string
	bandwidth      int64
	width          int
	height         int
	quality        int
}

func (d *Downloader) resolveBilibiliMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, bvid, valid := splitProviderDramaID(task.DramaID)
	if !valid || source != sourceBilibili || !validBilibiliBV(bvid) {
		return providerMedia{}, errors.New("哔哩哔哩视频信息无效，请刷新分集")
	}
	parts := strings.Split(task.Chapter.ID, ":")
	if len(parts) != 3 || parts[0] != sourceBilibili || parts[1] != bvid || task.Chapter.Source != "" && canonicalProviderSource(task.Chapter.Source) != sourceBilibili {
		return providerMedia{}, errors.New("哔哩哔哩分 P 与视频不匹配")
	}
	cid, err := strconv.ParseInt(parts[2], 10, 64)
	if err != nil || cid <= 0 {
		return providerMedia{}, errors.New("哔哩哔哩分 P 标识无效")
	}
	if strings.HasPrefix(task.Chapter.VideoURL, "bilibili://play/") {
		urlCID, parseErr := strconv.ParseInt(strings.TrimPrefix(task.Chapter.VideoURL, "bilibili://play/"), 10, 64)
		if parseErr != nil || urlCID != cid {
			return providerMedia{}, errors.New("哔哩哔哩分 P 地址与标识不匹配")
		}
	} else {
		return providerMedia{}, errors.New("哔哩哔哩分 P 解析地址无效")
	}
	quality := 0
	quality, _ = ctx.Value(bilibiliQualityContextKey{}).(int)
	qn := bilibiliQualityCode(quality)
	values := url.Values{}
	values.Set("bvid", bvid)
	values.Set("cid", strconv.FormatInt(cid, 10))
	values.Set("qn", strconv.Itoa(qn))
	values.Set("fnval", "4048")
	values.Set("fnver", "0")
	values.Set("fourk", "1")
	referer := "https://www.bilibili.com/video/" + bvid + "/"
	data, err := d.bilibiliSignedJSON(ctx, "/x/player/wbi/playurl", values, referer)
	if err != nil {
		return providerMedia{}, err
	}
	if bilibiliInt(data, "drm_tech_type", "drmTechType") > 0 {
		return providerMedia{}, errors.New("该视频使用受保护媒体格式，当前播放器不支持解码")
	}
	dash, _ := data["dash"].(map[string]any)
	if dash == nil {
		return providerMedia{}, errors.New("哔哩哔哩未返回 DASH 播放流，当前无法播放该视频")
	}
	videoRows, _ := dash["video"].([]any)
	audioRows, _ := dash["audio"].([]any)
	if len(videoRows) == 0 || len(videoRows) > 80 || len(audioRows) > 40 {
		return providerMedia{}, errors.New("哔哩哔哩 DASH 音视频轨道无效")
	}
	audio, hasAudio := bilibiliSelectAudio(audioRows)
	duration := time.Duration(max(0, bilibiliInt64(data, "timelength"))) * time.Millisecond
	best := map[int]bilibiliRepresentation{}
	for _, value := range videoRows {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		representation, valid := bilibiliParseRepresentation(row)
		if !valid || representation.height <= 0 {
			continue
		}
		existing, found := best[representation.height]
		if !found || bilibiliRepresentationScore(representation) > bilibiliRepresentationScore(existing) {
			best[representation.height] = representation
		}
	}
	heights := make([]int, 0, len(best))
	for height := range best {
		heights = append(heights, height)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(heights)))
	variants := make([]providerMedia, 0, len(heights))
	for _, height := range heights {
		video := best[height]
		playlist := bilibiliMPD(video, audio, hasAudio, duration)
		if playlist == "" {
			continue
		}
		variants = append(variants, providerMedia{
			URL: video.baseURL, Referer: referer,
			Playlist: playlist, PlaylistType: "dash", ProbeURL: video.baseURL, Quality: height,
		})
	}
	if len(variants) == 0 {
		return providerMedia{}, errors.New("哔哩哔哩未返回可用的音视频分段信息")
	}
	primary := variants[0]
	primary.Variants = variants[1:]
	return primary, nil
}

func bilibiliQualityCode(height int) int {
	switch {
	case height >= 4320:
		return 127
	case height >= 2160:
		return 120
	case height >= 1080:
		return 80
	case height >= 720:
		return 64
	case height >= 480:
		return 32
	case height >= 360:
		return 16
	case height > 0:
		return 6
	default:
		return 80
	}
}

func bilibiliParseRepresentation(row map[string]any) (bilibiliRepresentation, bool) {
	baseURL := strings.TrimSpace(mapString(row, "baseUrl", "base_url"))
	if !isBilibiliMediaURL(baseURL) {
		backups, _ := row["backupUrl"].([]any)
		if backups == nil {
			backups, _ = row["backup_url"].([]any)
		}
		for _, candidate := range backups {
			if raw, ok := candidate.(string); ok && isBilibiliMediaURL(raw) {
				baseURL = raw
				break
			}
		}
	}
	segment, _ := row["SegmentBase"].(map[string]any)
	if segment == nil {
		segment, _ = row["segment_base"].(map[string]any)
	}
	initialization := strings.TrimSpace(mapString(segment, "Initialization", "initialization"))
	indexRange := strings.TrimSpace(mapString(segment, "indexRange", "index_range"))
	if !isBilibiliMediaURL(baseURL) || !bilibiliRangePattern.MatchString(initialization) || !bilibiliRangePattern.MatchString(indexRange) {
		return bilibiliRepresentation{}, false
	}
	quality := bilibiliInt(row, "height")
	if quality <= 0 {
		quality = bilibiliHeightForQuality(bilibiliInt(row, "id", "quality"))
	}
	return bilibiliRepresentation{
		baseURL: baseURL, initialization: initialization, indexRange: indexRange,
		mimeType: firstNonEmpty(mapString(row, "mimeType", "mime_type"), "video/mp4"),
		codecs:   truncate(mapString(row, "codecs"), 120), bandwidth: bilibiliInt64(row, "bandwidth"),
		width: bilibiliInt(row, "width"), height: quality, quality: quality,
	}, true
}

func bilibiliSelectAudio(rows []any) (bilibiliRepresentation, bool) {
	var best bilibiliRepresentation
	found := false
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		representation, valid := bilibiliParseRepresentation(row)
		if !valid {
			continue
		}
		if !found || bilibiliAudioScore(representation) > bilibiliAudioScore(best) {
			best, found = representation, true
		}
	}
	return best, found
}

func bilibiliRepresentationScore(value bilibiliRepresentation) int64 {
	priority := int64(0)
	codecs := strings.ToLower(value.codecs)
	switch {
	case strings.Contains(codecs, "avc") || strings.Contains(codecs, "h264"):
		priority = 1_000_000_000_000
	case strings.Contains(codecs, "hev") || strings.Contains(codecs, "h265"):
		priority = 500_000_000_000
	}
	return priority + value.bandwidth
}

func bilibiliAudioScore(value bilibiliRepresentation) int64 {
	priority := int64(0)
	if strings.Contains(strings.ToLower(value.codecs), "mp4a") {
		priority = 1_000_000_000_000
	}
	return priority + value.bandwidth
}

func bilibiliHeightForQuality(quality int) int {
	switch quality {
	case 127:
		return 4320
	case 126, 120, 121, 122:
		return 2160
	case 112, 116, 125, 80:
		return 1080
	case 74, 64:
		return 720
	case 32:
		return 480
	case 16:
		return 360
	case 6:
		return 240
	default:
		return 0
	}
}

func bilibiliMPD(video, audio bilibiliRepresentation, hasAudio bool, duration time.Duration) string {
	if !isBilibiliMediaURL(video.baseURL) {
		return ""
	}
	var output strings.Builder
	output.WriteString(`<?xml version="1.0" encoding="UTF-8"?><MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" profiles="urn:mpeg:dash:profile:isoff-on-demand:2011" minBufferTime="PT1.5S"`)
	if duration > 0 {
		output.WriteString(` mediaPresentationDuration="PT`)
		output.WriteString(strconv.FormatFloat(duration.Seconds(), 'f', 3, 64))
		output.WriteString(`S"`)
	}
	output.WriteString(`><Period><AdaptationSet id="1" contentType="video" mimeType="video/mp4" segmentAlignment="true"><Representation id="video"`)
	output.WriteString(` bandwidth="` + strconv.FormatInt(max(1, video.bandwidth), 10) + `"`)
	if video.width > 0 {
		output.WriteString(` width="` + strconv.Itoa(video.width) + `"`)
	}
	if video.height > 0 {
		output.WriteString(` height="` + strconv.Itoa(video.height) + `"`)
	}
	if video.codecs != "" {
		output.WriteString(` codecs="` + bilibiliXMLEscape(video.codecs) + `"`)
	}
	output.WriteString(`><BaseURL>` + bilibiliXMLEscape(video.baseURL) + `</BaseURL><SegmentBase indexRange="` + video.indexRange + `"><Initialization range="` + video.initialization + `"/></SegmentBase></Representation></AdaptationSet>`)
	if hasAudio && isBilibiliMediaURL(audio.baseURL) {
		output.WriteString(`<AdaptationSet id="2" contentType="audio" mimeType="audio/mp4" segmentAlignment="true"><Representation id="audio" bandwidth="`)
		output.WriteString(strconv.FormatInt(max(1, audio.bandwidth), 10) + `"`)
		if audio.codecs != "" {
			output.WriteString(` codecs="` + bilibiliXMLEscape(audio.codecs) + `"`)
		}
		output.WriteString(`><BaseURL>` + bilibiliXMLEscape(audio.baseURL) + `</BaseURL><SegmentBase indexRange="` + audio.indexRange + `"><Initialization range="` + audio.initialization + `"/></SegmentBase></Representation></AdaptationSet>`)
	}
	output.WriteString(`</Period></MPD>`)
	return output.String()
}

func bilibiliXMLEscape(value string) string {
	var output strings.Builder
	_ = xml.EscapeText(&output, []byte(value))
	return output.String()
}

func isBilibiliMediaURL(raw string) bool {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil {
		return false
	}
	host := strings.ToLower(parsed.Hostname())
	for _, suffix := range []string{".bilivideo.com", ".bilivideo.cn", ".biliapi.net", ".hdslb.com", ".edge.mountaintoys.cn"} {
		if strings.HasSuffix(host, suffix) {
			return true
		}
	}
	return false
}

func bilibiliCleanText(value string) string {
	value = bilibiliTagPattern.ReplaceAllString(value, " ")
	value = html.UnescapeString(value)
	return strings.Join(strings.Fields(value), " ")
}

func bilibiliInt(row map[string]any, keys ...string) int {
	value := bilibiliInt64(row, keys...)
	if value > int64(^uint(0)>>1) || value < 0 {
		return 0
	}
	return int(value)
}

func bilibiliInt64(row map[string]any, keys ...string) int64 {
	for _, key := range keys {
		if value, ok := row[key]; ok {
			parsed, err := strconv.ParseInt(nativeText(value), 10, 64)
			if err == nil && parsed >= 0 {
				return parsed
			}
		}
	}
	return 0
}

func bilibiliIntegerText(values ...any) string {
	for _, value := range values {
		if number, err := strconv.ParseInt(nativeText(value), 10, 64); err == nil && number > 0 {
			return strconv.FormatInt(number, 10)
		}
	}
	return ""
}
