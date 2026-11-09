package com.real.drama.compose

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class MigrationTest {
    @Test fun videoTextureKeepsAspectAcrossRepeatedViewportChanges() {
        for (aspect in listOf(16f / 9f, 9f / 16f, 1f, 2.4f)) repeat(20) {
            for ((w, h) in listOf(360f to 720f, 800f to 360f, 360f to 640f)) {
                val (x, y) = fittedTextureScale(w, h, aspect)
                val actualW = minOf(1f, aspect) * w * x
                val actualH = minOf(1f, 1f / aspect) * h * y
                assertEquals(aspect, actualW / actualH, .0001f)
                assertEquals(minOf(w, h * aspect), actualW, .01f)
                assertTrue(actualW <= w + .01f && actualH <= h + .01f)
            }
        }
        assertEquals(1f to 1f, fittedTextureScale(0f, 100f, 1f))
        assertEquals(1f to 1f, fittedTextureScale(100f, 100f, Float.NaN))
    }
    @Test fun feedKeepsRecentlyViewedNeighborsAndBoundsResources() {
        val ids = (1..20).map { "video-$it" }
        var retained = emptySet<String>()
        fun visit(number: Int) { retained = feedRetainedPlayers(ids, number - 1, retained, warm = true, lowMemory = false) }
        (1..5).forEach(::visit)
        visit(4)
        assertTrue(retained.containsAll(listOf("video-3", "video-4", "video-5")))
        visit(3)
        assertTrue(retained.containsAll(listOf("video-3", "video-4", "video-5")))
        visit(4); visit(5)
        assertTrue(retained.containsAll(listOf("video-3", "video-4", "video-5", "video-6")))
        for (number in listOf(8, 7, 6, 7, 8, 9, 20, 1)) {
            visit(number)
            assertTrue(retained.size <= 5)
            assertTrue(retained.all { kotlin.math.abs(ids.indexOf(it) - (number - 1)) <= 2 })
        }
        assertEquals(setOf("video-4"), feedRetainedPlayers(ids, 3, retained, true, true))
        assertEquals(setOf("video-1"), feedRetainedPlayers(ids, 0, emptySet(), false, false))
        assertTrue(feedRetainedPlayers(emptyList(), 0, retained, true, false).isEmpty())
    }
    @Test fun danmakuMovesBetweenPlayerSamplesAndStopsWhenPaused() {
        val frames = (0..14).map { danmakuPosition(10.0, it / 60.0, true, 1.0) }
        assertTrue(frames.zipWithNext().all { (a, b) -> b > a })
        assertEquals(10.0, danmakuPosition(10.0, .2, false, 1.0), .0001)
        assertEquals(10.4, danmakuPosition(10.0, .2, true, 2.0), .0001)
        assertEquals(10.5, danmakuPosition(10.0, 2.0, true, 1.0), .0001)
    }
    @Test fun openingOrReplacingMediaPreservesLatestPauseIntent() = kotlinx.coroutines.runBlocking {
        val player = MpvPlayer(JSONObject(), observeInitially = false)
        try {
            player.play(true)
            player.play(false)
            player.open(obj("url" to "/synthetic-one.mp4"))
            assertFalse(player.state.value.playing)
            assertFalse(player.state.value.buffering)
            player.open(obj("url" to "/synthetic-two.mp4"))
            assertFalse(player.state.value.playing)
        } finally { player.close() }
    }
    @Test fun playerPagesFollowSourceAndLocalCapabilities() {
        val all = setOf("comments", "creator", "download")
        fun keys(kind: String, count: Int, caps: Set<String> = all, local: Boolean = false, download: Boolean = true) =
            playerSections(kind, count, caps, local, download).map { it.first }
        assertEquals(listOf("synopsis", "comments", "creator", "download"), keys("video", 1))
        assertEquals(listOf("episodes", "synopsis", "comments", "creator", "download"), keys("video", 2))
        assertEquals(listOf("episodes", "synopsis"), keys("drama", 1, emptySet()))
        assertEquals(listOf("synopsis"), keys("video", 1, local = true))
        assertFalse(keys("video", 1, download = false).contains("download"))
    }

    @Test fun nativeSnapshotDistinguishesPauseBufferingAndEnd() {
        val values = doubleArrayOf(12.0, 60.0, 1920.0, 1080.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        assertTrue(playbackSnapshot(values, true, null).playing)
        assertEquals(30.0, playbackSnapshot(values, true, null).buffered, 0.0)
        values[8] = 1.0
        assertTrue(playbackSnapshot(values, true, null).buffering)
        assertFalse(playbackSnapshot(values, false, null).buffering)
        values[5] = 1.0
        assertFalse(playbackSnapshot(values, true, null).buffering)
        values[5] = 0.0; values[6] = 1.0
        assertTrue(playbackSnapshot(values, true, null).completed)
        assertFalse(playbackSnapshot(values, true, null).playing)
        values[0] = Double.NaN; values[2] = -1.0; values[9] = -13.0
        val failed = playbackSnapshot(values, true, null)
        assertEquals(0.0, failed.position, 0.0); assertEquals(0.0, failed.width, 0.0)
        assertEquals("媒体播放失败（-13）", failed.error)
    }

    @Test fun nativeSnapshotUsesRotatedDisplayDimensions() {
        val values = doubleArrayOf(12.0, 60.0, 1920.0, 1080.0, 30.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        for (rotation in listOf(90.0, 270.0, -90.0, -270.0)) {
            values[10] = rotation
            val state = playbackSnapshot(values, true, null)
            assertEquals(1080.0, state.width, 0.0)
            assertEquals(1920.0, state.height, 0.0)
        }
        for (rotation in listOf(0.0, 180.0, 360.0, Double.NaN, Double.POSITIVE_INFINITY)) {
            values[10] = rotation
            val state = playbackSnapshot(values, true, null)
            assertEquals(1920.0, state.width, 0.0)
            assertEquals(1080.0, state.height, 0.0)
        }
    }

    @Test fun scrubIsBoundedAndUsesFineControlForLongVideos() {
        assertEquals(90.0, scrubPosition(60.0, 100f, 600, 3600.0), .001)
        assertEquals(0.0, scrubPosition(5.0, -100f, 600, 60.0), .001)
        assertEquals(60.0, scrubPosition(55.0, 100f, 600, 60.0), .001)
        assertEquals(12.0, scrubPosition(12.0, 100f, 600, 0.0), .001)
    }

    @Test fun feedFullscreenRestoresEntryOrientation() {
        val portrait = android.content.res.Configuration.ORIENTATION_PORTRAIT
        val landscape = android.content.res.Configuration.ORIENTATION_LANDSCAPE
        val portraitUp = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        val sensorPortrait = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        val sensorLandscape = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        repeat(2) {
            org.junit.Assert.assertEquals(sensorLandscape, feedOrientationRequest(true, 16.0 / 9.0, portrait))
            org.junit.Assert.assertEquals(portraitUp, feedOrientationRequest(false, 16.0 / 9.0, portrait))
        }
        org.junit.Assert.assertEquals(sensorPortrait, feedOrientationRequest(true, 9.0 / 16.0, landscape))
        org.junit.Assert.assertEquals(sensorLandscape, feedOrientationRequest(false, 9.0 / 16.0, landscape))
        org.junit.Assert.assertNull(feedOrientationRequest(true, 0.0, portrait))
    }

    @Test fun feedStartsFinishedWorksFromFirstEpisodeAndHonorsDouyinCooldown() {
        val episodes = listOf(Episode(obj("id" to "first"), 1), Episode(obj("id" to "third"), 3))
        assertEquals(1, feedResumeIndex(episodes, obj("episode" to 3, "position" to 10.0, "duration" to 60.0)))
        assertEquals(0, feedResumeIndex(episodes, obj("episode" to 3, "position" to 60.0, "duration" to 60.0)))
        assertEquals(30, feedRetrySeconds("抖音接口已限流，已暂停约 30 秒", true))
        assertEquals(60, feedRetrySeconds("HTTP 429", true))
        assertNull(feedRetrySeconds("HTTP 429", false))
    }

    @Test fun manualSyncPreviewCountsMembershipConflictsAndRemovals() {
        fun row(vararg values: Boolean) = obj("member" to JSONArray(values.map { obj("value" to it) }))
        val followed = row(true)
        val old = mapOf("removed" to followed, "conflict" to followed, "updated" to followed)
        val next = mapOf("added" to followed, "removed" to row(false), "conflict" to row(false, true),
            "updated" to followed.copy().put("progress", JSONArray(listOf(obj("value" to 50)))))
        assertEquals(LanChangeCount(1, 1, 2, 1), LanChangeCount.between(old, next))
    }

    @Test fun webDavValidatesBeforeSavingConnectionSettings() {
        WebDavClient("https://backup.example/config.json", "user", "password")
        for (address in listOf("http://backup.example/config.json", "https://user:password@backup.example/config.json", "https://backup.example/", "https://backup.example/config.json?token=secret", "https://backup.example/config.json#fragment")) {
            assertThrows(IllegalArgumentException::class.java) { WebDavClient(address, "user", "password") }
        }
        assertThrows(IllegalArgumentException::class.java) { WebDavClient("https://backup.example/config.json", "user:name", "password") }
        assertThrows(IllegalArgumentException::class.java) { WebDavClient("https://backup.example/config.json", "user", "password\nheader") }
    }
    @Test fun feedCategoriesAreInterleavedAcrossSources() {
        assertEquals(listOf(listOf("one" to "a", "two" to "x"), listOf("one" to "b")), feedCategoryBatches(linkedMapOf("one" to listOf("a", "b"), "two" to listOf("x"))))
        assertTrue(feedCategoryBatches(emptyMap()).isEmpty())
    }
    @Test fun feedSignalsMatchRetainedWeightsAndUndoSemantics() {
        val engine = FeedRecommendations(emptyList()); val drama = Drama(obj("id" to "test:1", "source" to "test", "title" to "测试"))
        engine.signal(drama, .3); engine.like(drama); assertEquals(1.0, engine.session.last().value, 0.0)
        engine.like(drama); assertEquals(1, engine.session.size); assertEquals(.3, engine.session.single().value, 0.0)
        engine.notInterested(drama); assertEquals(-1.5, engine.session.single().value, 0.0)
        repeat(100) { engine.signal(drama, .05) }; assertEquals(60, engine.session.size)
        assertEquals(-1.2, leavingFeedValue(2, null, 0), 0.0); assertEquals(.3, leavingFeedValue(31, null, 0), 0.0)
        val watched = obj("updatedAt" to "2026-11-05T12:00:00Z", "duration" to 100.0, "position" to 99.0, "episode" to 5)
        assertEquals(2.8, leavingFeedValue(2, watched, 0), .00001)
        assertEquals(-1.2, leavingFeedValue(2, watched, Long.MAX_VALUE), 0.0)
    }
    @Test fun homeFeedOnlyRequestsEnabledSelectedFormatsAndKeepsExclusions() {
        val available = listOf(obj("id" to "short_play", "name" to "真人剧"), obj("id" to "comic_series", "name" to "漫剧"), obj("id" to "tag:重生", "name" to "重生"))
        assertTrue(feedRequestCategories("hongguo", JSONObject()).isEmpty())
        val selected = feedCategorySelection(obj("enabled" to true), available, setOf("short_play", "tag:重生"))
        assertEquals(listOf("short_play"), feedRequestCategories("hongguo", selected)); assertEquals("漫剧", selected.getJSONObject("excludedCategories").getString("comic_series"))
        val disabled = feedCategorySelection(selected, available, setOf("tag:重生")); assertTrue(feedRequestCategories("hongguo", disabled).isEmpty())
        assertTrue(feedCategorySelection(selected, available, available.map { it.text("id") }.toSet()).getJSONObject("excludedCategories").length() == 0)
    }
    @Test fun downloadFiltersKeepArchivedVideosSeparateAndMatchNativeVersions() {
        fun job(id: String, state: String, archived: Boolean = false) = obj("id" to id, "state" to state, "archived" to archived, "index" to 1, "created" to 100L, "bytes" to 20L, "actualQuality" to 720, "drama" to obj("id" to "hongguo:$id", "source" to "hongguo", "title" to "测试$id", "releaseStatus" to "completed"))
        val rows = listOf(job("a", "completed", true), job("b", "completed"), job("c", "paused"), job("d", "downloading"))
        assertEquals(listOf("b", "c", "d"), downloadCollections(rows, "", "all", "finished") { "站源" }.flatten().map { it.text("id") })
        assertEquals(listOf("a"), downloadCollections(rows, "测试 站源", "archived", "") { "站源" }.flatten().map { it.text("id") })
        assertEquals(listOf("c", "d"), downloadCollections(rows, "", "pending", "") { "站源" }.flatten().map { it.text("id") })
        assertTrue(downloadableCommand(rows[0], "restore")); assertFalse(downloadableCommand(rows[0], "archive")); assertTrue(downloadableCommand(rows[2], "resume")); assertFalse(downloadableCommand(rows[1], "resume"))
        assertEquals("100-20-720", MediaLibrary.version(rows[0])); assertEquals("100-20-720-2", MediaLibrary.version(rows[0].put("revision", 2)))
    }
    @Test fun catalogSortingAndSearchMatchLegacyRules() {
        fun drama(id: String, title: String, heat: String, release: String = "") = Drama(obj("id" to "hongguo:$id", "source" to "hongguo", "title" to title, "heat" to heat, "releaseStatus" to release, "description" to "校园成长", "tags" to JSONArray().put("重生")))
        val rows = listOf(drama("ten", "测试第十季", "未知"), drama("two", "测试第二季", "1.2万次播放", "completed"), drama("one", "测试第1季", "12,000"))
        assertEquals(listOf("hongguo:one", "hongguo:two", "hongguo:ten"), sortCatalog(rows, obj("sort" to "season")).map { it.id })
        assertEquals(listOf("hongguo:two", "hongguo:one", "hongguo:ten"), sortCatalog(rows, obj("sort" to "heat")).map { it.id })
        assertEquals(listOf("hongguo:two"), sortCatalog(rows, obj("release" to "finished")).map { it.id })
        assertTrue(matchesDramaQuery(rows[0], "校园 重生")); assertFalse(matchesDramaQuery(rows[0], "校园 都市"))
        assertEquals("abc12", normalizedSearchText("ＡＢＣ １２！")); assertNull(catalogMetric("1.2万人气"))
        assertEquals(120000000.0, catalogMetric("1.2亿+"))
    }
    @Test fun seriesNoticesPreserveReadStateAndExcludeAlreadyFollowedSeasons() {
        fun drama(id: String, title: String) = Drama(obj("id" to "hongguo:$id", "source" to "hongguo", "title" to title))
        val one = drama("1", "故事"); val two = drama("2", "故事第二季"); val ten = drama("10", "故事第十季")
        val candidates = listOf(one, two, ten, drama("invalid", "故事第百百季"), drama("other", "别的故事第二季"))
        assertEquals(listOf(1, 2, 10), seriesEntries(one, candidates).map { it.season })
        var state = observeSeries(one, observedFollow(null, one), candidates, setOf(one.id))
        assertEquals("新季 2 部", followUpdateLabel(state))
        state.getJSONObject("seriesSeasons").getJSONObject(two.id).put("read", true)
        state = observeSeries(one, state, candidates, setOf(one.id, ten.id))
        assertEquals("", followUpdateLabel(state)); assertTrue(state.getJSONObject("seriesSeasons").getJSONObject(two.id).getBoolean("read"))
    }
    @Test fun sparseMetadataKeepsSpecificTaxonomyAndUnknownVip() {
        val original = Drama(obj("id" to "hongguo:1", "source" to "hongguo", "title" to "原名", "category" to "悬疑", "episodes" to 20, "vip" to true, "releaseStatus" to "finished", "tags" to JSONArray().put("成长")))
        val result = mergeDramaMetadata(original, Drama(obj("id" to original.id, "source" to original.source, "title" to "短剧", "category" to "真人剧", "releaseStatus" to "unknown")))
        assertEquals("原名", result.title); assertEquals("悬疑", result.json.text("category")); assertTrue(result.json.getBoolean("vip")); assertEquals(20, result.json.getInt("episodes")); assertEquals(setOf("成长", "悬疑", "真人剧"), result.json.array("tags").strings().toSet())
    }
    @Test fun finishedEpisodesResumeAtNextActualNumber() {
        val episodes = listOf(1, 3, 5).map { Episode(obj("id" to "$it"), it) }
        assertEquals(2, resumeEpisodeIndex(episodes, obj("episode" to 3, "position" to 99.0, "duration" to 100.0)))
        assertEquals(1, resumeEpisodeIndex(episodes, obj("episode" to 3, "position" to 98.0, "duration" to 100.0)))
        assertEquals(2, resumeEpisodeIndex(episodes, obj("episode" to 20, "position" to 50.0, "duration" to 100.0)))
    }
    @Test fun commentFallbacksMatchOriginalShortcodes() {
        assertEquals("👀 👌 未知 [invalidnested", commentText("[暗中观察] [ O_K ] [未知] [invalid[nested]"))
    }
    @Test fun rankingPayloadPreservesNestedIdentityAndMetric() {
        val response = obj("items" to JSONArray().put(obj("rank" to 2, "metric" to "热度 1万", "drama" to obj("id" to "hongguo:two", "source" to "hongguo", "title" to "合成第二部"))))
        val row = rankingEntries(response, "hongguo").single()
        assertEquals("hongguo:two", row.drama.id); assertEquals(2, row.rank); assertEquals("热度 1万", row.metric)
        assertThrows(IllegalArgumentException::class.java) { rankingEntries(response, "other") }
    }
    @Test fun localTaxonomyUsesMetadataAndInterleavesSources() {
        val groups = listOf(obj("id" to "plot", "topics" to JSONArray().put(obj("id" to "rebirth", "aliases" to JSONArray().put("重生")))), obj("id" to "other", "topics" to JSONArray().put(obj("id" to "other", "aliases" to JSONArray().put("其他")))))
        val recommendations = FeedRecommendations(groups)
        val a = Drama(obj("id" to "hongguo:a", "source" to "hongguo", "title" to "重生", "category" to "都市"))
        val b = Drama(obj("id" to "hongguo:b", "source" to "hongguo", "title" to "故事", "tags" to JSONArray().put("重生逆袭")))
        assertFalse(taxonomyMatches(a, "taxonomy:rebirth", recommendations)); assertTrue(taxonomyMatches(b, "taxonomy-group:plot", recommendations))
        assertEquals(listOf(a.id, b.id), interleaveDramas(listOf(listOf(a, b), listOf(b))).map { it.id })
    }
    @Test fun lanMetadataIsCompactedAndTimestampMatchesFlutter() {
        val drama = compactLanDrama(obj("id" to "hongguo:synthetic", "source" to "hongguo", "title" to "长".repeat(301), "description" to "文".repeat(4001), "cover" to "file:///private", "tags" to JSONArray((1..40).map { "标签".repeat(60) })))
        assertEquals(300, drama.text("title").length); assertEquals(4000, drama.text("description").length); assertEquals("", drama.text("cover")); assertEquals(32, drama.array("tags").length())
        assertEquals("2026-11-05T00:00:00.000Z", lanTimestamp("2026-11-05T00:00:00Z")); assertEquals("2026-11-05T00:00:00.123456Z", lanTimestamp("2026-11-05T00:00:00.123456789Z"))
        assertThrows(IllegalArgumentException::class.java) { LanRecords(obj("schema" to 1, "replica" to "1".repeat(32), "counter" to "1", "records" to JSONArray())) }
    }
    private val a = "1".repeat(32)
    private val b = "2".repeat(32)
    private fun cell(value: Any?, replica: String = a, counter: Long = 1) = JSONArray().put(obj("v" to obj(replica to counter), "value" to value))
    private fun fixture() = JSONObject(javaClass.getResourceAsStream("/flutter-protocol.json")!!.bufferedReader().use { it.readText() })
    @Test fun flutterAndComposeProduceIdenticalRecordHashes() {
        val fixture = fixture(); val record = fixture.getJSONObject("record")
        validateLanRecord(record)
        assertEquals(fixture.getString("canonical"), canonical(record))
        assertEquals(fixture.getString("hash"), lanHash(record))
        assertEquals(canonical(record.getJSONObject("drama")), canonical(Drama(obj("id" to "hongguo:fixture", "source" to "hongguo", "title" to "合成测试", "episodes" to 12)).json))
        assertEquals(canonical(record), canonical(record.copy()))
    }
    @Test fun independentConflictsAreCommutativeAndExplicit() {
        val left = cell(true); val right = cell(false, b)
        val result = mergeCell(left, right)
        assertEquals(2, result.length()); assertEquals(canonical(result), canonical(mergeCell(right, left)))
        val resolution = JSONArray().put(obj("v" to obj(a to 2, b to 1), "value" to true))
        assertEquals(canonical(resolution), canonical(mergeCell(result, resolution)))
    }
    @Test fun equalValuesJoinVersionsAndForgedEqualVersionsFail() {
        assertEquals(1, mergeCell(cell(true), cell(true, b)).length())
        assertThrows(IllegalArgumentException::class.java) { mergeCell(cell(true), cell(false)) }
    }
    @Test fun fractionalAndStringCountersAreRejected() {
        for (counter in listOf<Any>(1.5, "1", 0L, 9007199254740000L)) {
            val record = fixture().getJSONObject("record")
            record.getJSONArray("member").getJSONObject(0).getJSONObject("v").put(a, counter)
            assertThrows(IllegalArgumentException::class.java) { validateLanRecord(record) }
        }
    }
    @Test fun duplicateRecordsAreRejected() {
        val row = fixture().getJSONObject("record")
        assertThrows(IllegalArgumentException::class.java) { LanRecords(obj("schema" to 1, "replica" to a, "counter" to 3, "records" to JSONArray().put(row).put(row))) }
    }
    @Test fun clearingHistoryAlsoResolvesConflictingRemoteProgress() {
        val row = fixture().getJSONObject("record")
        val originalMember = canonical(row.getJSONArray("member"))
        val originalStatus = canonical(row.getJSONArray("status"))
        row.put("progress", mergeCell(row.getJSONArray("progress"), cell(null, b, 8)))
        val document = LanRecords(obj("schema" to 1, "replica" to a, "counter" to 10, "records" to JSONArray().put(row)))
        document.clearProgress(setOf(row.getJSONObject("drama").text("id")))
        val cleared = document.records.values.single()
        assertEquals(1, cleared.getJSONArray("progress").length()); assertTrue(cleared.getJSONArray("progress").getJSONObject(0).isNull("value"))
        assertEquals(originalMember, canonical(cleared.getJSONArray("member"))); assertEquals(originalStatus, canonical(cleared.getJSONArray("status")))
    }
    @Test fun watchCompletionMatchesRetainedThresholdAndManualOverride() {
        val drama = Drama(obj("id" to "hongguo:a", "source" to "hongguo", "title" to "测试", "episodes" to 12))
        assertEquals("watching", observedFollow(null, drama, 12, 119.0, 121.0).text("status"))
        assertEquals("watched", observedFollow(null, drama, 12, 120.0, 121.0).text("status"))
        val manual = obj("status" to "watched", "manuallyWatched" to true, "knownEpisodes" to 10, "readEpisodes" to 10)
        assertEquals("watched", observedFollow(manual, drama, 1, 2.0, 120.0).text("status"))
        assertEquals("watching", observedFollow(manual.copy().put("manuallyWatched", false), drama).text("status"))
    }
    private fun probe(codec: String = "h264", width: Int = 1920, audio: Boolean = true, transfer: String = "bt709", seconds: Double = 120.0) = MediaProbe(obj("format" to obj("duration" to seconds), "streams" to JSONArray().put(obj("codec_type" to "video", "codec_name" to codec, "width" to width, "height" to 1080, "pix_fmt" to "yuv420p", "color_transfer" to transfer, "extradata_hash" to "test")).apply {
        if (audio) put(obj("codec_type" to "audio", "codec_name" to "aac", "profile" to "LC", "sample_rate" to "48000", "channels" to 2, "channel_layout" to "stereo", "extradata_hash" to "aac"))
    }))
    @Test fun mergePreservesMajorityVideoAndNormalizesOnlyOutliers() {
        val rows = listOf(probe(), probe(width = 1280), probe())
        val plan = MergePlan(rows)
        assertEquals(listOf(false, true, false), plan.videoChanges)
        assertFalse(plan.audioChanges.any { it }); assertTrue(plan.transport)
        assertTrue(plan.arguments("input", "out", rows[0], 0).contains("copy"))
        assertTrue(plan.arguments("input", "out", rows[1], 1).contains("libx264"))
    }
    @Test fun missingAudioIsPaddedAndAacIsNormalizedAcrossAllParts() {
        val rows = listOf(probe(), probe(audio = false))
        val plan = MergePlan(rows)
        assertEquals(listOf(true, true), plan.audioChanges)
        assertTrue(plan.arguments("in", "out", rows[1], 1).any { it.startsWith("anullsrc=") })
        assertTrue(plan.arguments("in", "out", rows[1], 1).contains("-t"))
        assertFalse(plan.arguments("in", "out", rows[0], 0).contains("-t"))
    }
    @Test fun mergeRejectsUnsafeHdrAndBadDurations() {
        assertThrows(IllegalArgumentException::class.java) { MergePlan(listOf(probe(), probe(transfer = "smpte2084"))) }
        assertThrows(IllegalArgumentException::class.java) { MergePlan(listOf(probe(), probe(seconds = 0.0))) }
    }
    @Test fun subscriptionRejectsCredentialEscapes() {
        val source = obj("schema" to 1, "api" to 1, "engine" to "javascript-generator-v1", "id" to "test", "name" to "测试", "version" to "1.0.0", "program" to "function* main() {}", "domains" to JSONArray().put("example.com"), "capabilities" to JSONArray().put("catalog"), "credentialDomains" to JSONArray().put("elsewhere.example"))
        assertThrows(IllegalArgumentException::class.java) { SourcePackage.parse(source.toString().toByteArray(), "local:test") }
    }
}
