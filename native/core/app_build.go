package core

import "errors"

var buildAllSources = "false"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func nativeSourceAvailable(source string) bool {
	return subscriptionID.MatchString(canonicalProviderSource(source))
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	source := canonicalProviderSource(job.Drama.Source)
	if source == "" {
		source = sourceFromDramaID(job.Drama.ID)
	}
	return nativeSourceAvailable(source) && nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "rankingBoards", "rankings", "suggestions", "catalog", "cached", "categories", "sourceStatus", "sourceJob", "cancelSourceJob", "cover", "prepareCover", "detail", "metadata", "resolve", "preload", "prepareHandoff", "bilibiliAccount", "bilibiliCreator", "bilibiliComments":
		return errors.New("此操作已经迁移至站源订阅，请导入兼容站源")
	case "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errors.New("条目标识无效")
		}
	}
	return nil
}
