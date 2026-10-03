package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"time"
)

type bilibiliFollowCursor struct {
	offsets map[int]string
	updated time.Time
}

func bilibiliRows(rows []any) []Drama {
	items := []Drama{}
	seen := map[string]bool{}
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		if kind := mapString(row, "goto"); kind != "" && kind != "av" {
			continue
		}
		if item, valid := bilibiliDramaFromMap(row); valid && !seen[item.ID] {
			seen[item.ID] = true
			items = append(items, item)
		}
	}
	return items
}

func (d *Downloader) fetchBilibiliFeedPage(ctx context.Context, page int, query, category string) ([]Drama, bool, error) {
	if page < 1 || page > 100000 {
		return nil, false, errors.New("哔哩哔哩分页超出接口范围")
	}
	if query != "" {
		return d.fetchBilibiliCatalogPage(ctx, page, query)
	}
	if category == "following" {
		return d.bilibiliFollowingPage(ctx, page)
	}
	if category == "ranking" {
		data, err := d.bilibiliJSON(ctx, "/x/web-interface/ranking/v2", url.Values{"rid": {"0"}, "type": {"all"}}, "https://www.bilibili.com/")
		if err != nil {
			return nil, false, err
		}
		rows, ok := data["list"].([]any)
		if !ok || len(rows) > 1000 {
			return nil, false, errors.New("哔哩哔哩排行数据无效")
		}
		start := min((page-1)*20, len(rows))
		end := min(start+20, len(rows))
		return bilibiliRows(rows[start:end]), end < len(rows), nil
	}
	values := url.Values{"version": {"1"}, "feed_version": {"V8"}, "homepage_ver": {"1"}, "ps": {"20"}, "fresh_idx": {strconv.Itoa(page)}, "brush": {strconv.Itoa(page)}, "fresh_type": {"4"}}
	data, err := d.bilibiliSignedJSON(ctx, "/x/web-interface/wbi/index/top/feed/rcmd", values, "https://www.bilibili.com/")
	if err != nil {
		return nil, false, err
	}
	rows, ok := data["item"].([]any)
	if !ok || len(rows) > 200 {
		return nil, false, errors.New("哔哩哔哩推荐数据无效")
	}
	return bilibiliRows(rows), len(rows) != 0, nil
}

func (d *Downloader) bilibiliFollowingPage(ctx context.Context, page int) ([]Drama, bool, error) {
	raw, _ := ctx.Value(bilibiliCookieContextKey{}).(string)
	cookie, err := bilibiliSafeCookie(raw)
	if err != nil {
		return nil, false, err
	}
	if cookie == "" {
		return nil, false, errors.New("正在关注需要登录，请先在站源管理中设置哔哩哔哩 Cookie")
	}
	digest := sha256.Sum256([]byte(cookie))
	key := hex.EncodeToString(digest[:])
	d.bilibiliKeyMu.Lock()
	if d.bilibiliFollowing == nil {
		d.bilibiliFollowing = map[string]*bilibiliFollowCursor{}
	}
	for identity, state := range d.bilibiliFollowing {
		if time.Since(state.updated) > 30*time.Minute {
			delete(d.bilibiliFollowing, identity)
		}
	}
	state := d.bilibiliFollowing[key]
	offset := ""
	if page > 1 && state != nil {
		offset = state.offsets[page]
	}
	d.bilibiliKeyMu.Unlock()
	if page > 1 && offset == "" {
		return nil, false, errors.New("关注分页已失效，请刷新正在关注后继续加载")
	}
	items := []Drama{}
	more := false
	for attempt := 0; attempt < 3; attempt++ {
		data, requestErr := d.bilibiliJSON(ctx, "/x/polymer/web-dynamic/v1/feed/all", url.Values{"type": {"video"}, "offset": {offset}, "timezone_offset": {"-480"}, "features": {"itemOpusStyle"}}, "https://www.bilibili.com/")
		if requestErr != nil {
			return nil, false, requestErr
		}
		rows, ok := data["items"].([]any)
		if !ok || len(rows) > 200 {
			return nil, false, errors.New("哔哩哔哩关注数据无效")
		}
		for _, value := range rows {
			row, ok := value.(map[string]any)
			if !ok || row["type"] != "DYNAMIC_TYPE_AV" {
				continue
			}
			modules, _ := row["modules"].(map[string]any)
			dynamic, _ := modules["module_dynamic"].(map[string]any)
			major, _ := dynamic["major"].(map[string]any)
			archive, _ := major["archive"].(map[string]any)
			if archive == nil {
				continue
			}
			author, _ := modules["module_author"].(map[string]any)
			entry := map[string]any{"bvid": archive["bvid"], "title": archive["title"], "pic": archive["cover"], "desc": archive["desc"], "owner": author}
			if item, valid := bilibiliDramaFromMap(entry); valid {
				items = append(items, item)
			}
		}
		next := mapString(data, "offset")
		more = (data["has_more"] == true || nativeText(data["has_more"]) == "1") && next != "" && next != offset && len(next) <= 256
		offset = next
		if len(items) != 0 || !more {
			break
		}
	}
	d.bilibiliKeyMu.Lock()
	if len(d.bilibiliFollowing) >= 4 && d.bilibiliFollowing[key] == nil {
		for identity := range d.bilibiliFollowing {
			delete(d.bilibiliFollowing, identity)
			break
		}
	}
	state = d.bilibiliFollowing[key]
	if state == nil {
		state = &bilibiliFollowCursor{offsets: map[int]string{}}
		d.bilibiliFollowing[key] = state
	}
	if page == 1 {
		state.offsets = map[int]string{}
	}
	for previous := range state.offsets {
		if previous < page-32 {
			delete(state.offsets, previous)
		}
	}
	if more {
		state.offsets[page+1] = offset
	}
	state.updated = time.Now()
	d.bilibiliKeyMu.Unlock()
	return items, more, nil
}

func (d *Downloader) bilibiliCreator(ctx context.Context, drama nativeDrama, page int) (map[string]any, error) {
	mid, err := strconv.ParseInt(drama.CreatorID, 10, 64)
	if err != nil || mid <= 0 {
		_, bvid, valid := splitProviderDramaID(drama.ID)
		if !valid {
			return nil, errors.New("哔哩哔哩作者标识无效")
		}
		fresh, _, detailErr := d.fetchBilibiliDetail(ctx, bvid)
		if detailErr != nil {
			return nil, detailErr
		}
		drama = mergeNativeDrama(drama, nativeNormalize(fresh))
		mid, err = strconv.ParseInt(drama.CreatorID, 10, 64)
		if err != nil || mid <= 0 {
			return nil, errors.New("视频没有返回作者 UID")
		}
	}
	if page < 1 || page > 100000 {
		return nil, errors.New("作者作品分页无效")
	}
	referer := fmt.Sprintf("https://space.bilibili.com/%d/", mid)
	values := url.Values{"mid": {strconv.FormatInt(mid, 10)}, "pn": {strconv.Itoa(page)}, "ps": {"30"}, "tid": {"0"}, "order": {"pubdate"}, "platform": {"web"}, "web_location": {"1550101"}}
	data, err := d.bilibiliSignedJSON(ctx, "/x/space/wbi/arc/search", values, referer)
	if err != nil {
		return nil, err
	}
	list, _ := data["list"].(map[string]any)
	rows, ok := list["vlist"].([]any)
	if !ok || len(rows) > 100 {
		return nil, errors.New("作者作品数据无效")
	}
	items := bilibiliRows(rows)
	name, avatar, bio := drama.CreatorName, drama.CreatorAvatar, ""
	result := map[string]any{"userId": strconv.FormatInt(mid, 10)}
	if page == 1 {
		if info, profileErr := d.bilibiliJSON(ctx, "/x/web-interface/card", url.Values{"mid": {strconv.FormatInt(mid, 10)}}, referer); profileErr == nil {
			card, _ := info["card"].(map[string]any)
			name = firstNonEmpty(mapString(card, "name"), name)
			avatar = firstNonEmpty(mapString(card, "face"), avatar)
			bio = truncate(bilibiliCleanText(mapString(card, "sign")), 4000)
			result["followers"] = card["fans"]
			result["following"] = card["attention"]
			result["likes"] = info["like_num"]
		}
	}
	normalized := []nativeDrama{}
	for _, item := range items {
		item.CreatorID = drama.CreatorID
		item.CreatorName = firstNonEmpty(item.CreatorName, name)
		item.CreatorAvatar = firstNonEmpty(item.CreatorAvatar, avatar)
		normalized = append(normalized, nativeNormalize(item))
	}
	pagination, _ := data["page"].(map[string]any)
	count := bilibiliInt(pagination, "count")
	result["name"], result["avatar"], result["bio"] = name, avatar, bio
	result["items"], result["cursor"] = normalized, strconv.Itoa(page+1)
	result["hasMore"] = page*30 < count
	return result, nil
}

func (d *Downloader) bilibiliComments(ctx context.Context, drama nativeDrama, page int) (map[string]any, error) {
	if page < 1 || page > 10 {
		return nil, errors.New("评论最多展示 200 条")
	}
	_, bvid, valid := splitProviderDramaID(drama.ID)
	if !valid || !validBilibiliBV(bvid) {
		return nil, errors.New("视频标识无效")
	}
	view, err := d.bilibiliSignedJSON(ctx, "/x/web-interface/wbi/view", url.Values{"bvid": {bvid}}, "https://www.bilibili.com/")
	if err != nil {
		return nil, err
	}
	aid := bilibiliInt64(view, "aid")
	if aid <= 0 {
		return nil, errors.New("视频没有返回评论标识")
	}
	data, err := d.bilibiliJSON(ctx, "/x/v2/reply", url.Values{"oid": {strconv.FormatInt(aid, 10)}, "type": {"1"}, "pn": {strconv.Itoa(page)}, "ps": {"20"}, "sort": {"2"}}, "https://www.bilibili.com/video/"+bvid+"/")
	if err != nil {
		return nil, err
	}
	rows, _ := data["replies"].([]any)
	if len(rows) > 100 {
		return nil, errors.New("评论数据过多")
	}
	items := []map[string]any{}
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok {
			continue
		}
		member, _ := row["member"].(map[string]any)
		content, _ := row["content"].(map[string]any)
		id := bilibiliIntegerText(row["rpid"])
		text := truncate(mapString(content, "message"), 4000)
		if id == "" || text == "" {
			continue
		}
		items = append(items, map[string]any{"id": id, "author": truncate(mapString(member, "uname"), 80), "avatar": providerCoverAddress(mapString(member, "avatar"), "https://www.bilibili.com/"), "text": text, "likes": bilibiliInt(row, "like")})
	}
	pagination, _ := data["page"].(map[string]any)
	total := bilibiliInt(pagination, "count")
	return map[string]any{"items": items, "total": total, "cursor": strconv.Itoa(page + 1), "hasMore": len(rows) > 0 && page < 10 && page*20 < total}, nil
}
