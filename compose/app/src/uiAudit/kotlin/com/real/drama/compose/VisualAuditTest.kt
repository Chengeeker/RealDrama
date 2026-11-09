package com.real.drama.compose

import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material3.Surface
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performScrollTo
import androidx.compose.ui.test.performSemanticsAction
import androidx.compose.ui.test.performTouchInput
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsNotDisplayed
import androidx.compose.ui.test.click
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.test.swipeUp
import androidx.compose.ui.test.printToString
import androidx.compose.runtime.remember
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.Alignment
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.Implements
import org.robolectric.annotation.Implementation
import org.robolectric.util.ReflectionHelpers
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], qualifiers = "w390dp-h844dp-mdpi", application = DramaApplication::class, shadows = [AuditNativeBridge::class], instrumentedPackages = ["com.real.drama.compose.NativeBridge"])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class VisualAuditTest {
    private class AuditedSurfaceTexture : android.graphics.SurfaceTexture(0) {
        @Volatile var releasedOn: android.os.Looper? = null
        override fun release() {
            super.release()
            releasedOn = android.os.Looper.myLooper()
        }
    }
    @Test fun feedReturnsFromBackgroundWithoutLosingManualPause() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking {
            repo.store.open()
            repo.subscriptions.installed.value = listOf(SourcePackage(obj("id" to "synthetic", "name" to "合成视频", "kind" to "video", "version" to "1", "program" to "function* main(){}",
                "capabilities" to org.json.JSONArray(listOf("comments"))), "local:audit", "audit", ByteArray(0)))
        }
        val detail = Detail(Drama(obj("id" to "synthetic:resume", "source" to "synthetic", "title" to "后台恢复检查")), listOf(Episode(obj("id" to "1"), 1)))
        compose.setContent { CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}) {
            DramaTheme(repo.store) { PlayerPane(detail, active = true, feed = true, localOnly = true,
                localPlan = obj("url" to "/synthetic.mp4", "local" to true), modifier = Modifier.fillMaxSize()) }
        } }
        compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("后台恢复检查")).fetchSemanticsNodes().isNotEmpty() }
        compose.onRoot().performTouchInput { click() }
        compose.onNodeWithContentDescription("开始播放").assertExists()
        val positions = listOf("喜欢", "评论", "收藏", "不喜欢").map { compose.onNodeWithText(it).fetchSemanticsNode().boundsInRoot.top }
        org.junit.Assert.assertTrue(positions.zipWithNext().all { (before, after) -> before < after })
        repeat(3) {
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.CREATED)
            compose.activityRule.scenario.moveToState(androidx.lifecycle.Lifecycle.State.RESUMED)
            compose.waitForIdle()
            compose.onNodeWithContentDescription("开始播放").assertExists()
        }
        compose.runOnIdle {
            val decor = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
            decor.draw(android.graphics.Canvas(bitmap))
            val file = File("../build/feed-controls-20261110/feed-paused.png").apply { parentFile?.mkdirs() }
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun surfaceRestoreSkipsDestroyedAndDuplicateAttachments() = runBlocking {
        val player = MpvPlayer(org.json.JSONObject(), observeInitially = false)
        val mutex = ReflectionHelpers.getField<kotlinx.coroutines.sync.Mutex>(player, "mutex")
        val stale = AuditedSurfaceTexture()
        val current = AuditedSurfaceTexture()
        AuditNativeBridge.playerCreations.set(0)
        mutex.lock()
        player.attach(stale, 960, 960)
        player.detach(stale)
        player.attach(current, 960, 960)
        mutex.unlock()
        compose.waitUntil(10000) {
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            AuditNativeBridge.playerCreations.get() == 1
        }
        player.play(true)
        player.attach(current, 960, 960)
        player.open(obj("url" to "/synthetic.mp4"))
        org.junit.Assert.assertEquals(1, AuditNativeBridge.playerCreations.get())
        mutex.lock()
        player.attach(android.graphics.SurfaceTexture(0).also { it.release() }, 960, 960)
        player.close()
        mutex.unlock()
        player.detach(current)
        compose.waitUntil(10000) {
            org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
            current.releasedOn != null
        }
        org.junit.Assert.assertSame(android.os.Looper.getMainLooper(), stale.releasedOn)
        org.junit.Assert.assertSame(android.os.Looper.getMainLooper(), current.releasedOn)
        org.junit.Assert.assertEquals(1, AuditNativeBridge.playerCreations.get())
    }

    @Test fun releasedSurfaceCallbacksAreIgnoredAndSnapshotErrorsAreReported() = runBlocking {
        val player = MpvPlayer(org.json.JSONObject())
        val texture = AuditedSurfaceTexture()
        val view = FittedVideoTexture(compose.activity, player)
        AuditNativeBridge.snapshotFailure = true
        try {
            compose.runOnIdle { view.surfaceTextureListener!!.onSurfaceTextureAvailable(texture, 360, 720) }
            player.open(obj("url" to "/synthetic.mp4"))
            compose.waitUntil(10000) { player.state.value.error == "synthetic surface loss" }
            compose.runOnIdle { view.surfaceTextureListener!!.onSurfaceTextureDestroyed(texture) }
            compose.waitUntil(10000) {
                org.robolectric.Shadows.shadowOf(android.os.Looper.getMainLooper()).idle()
                texture.releasedOn != null
            }
            org.junit.Assert.assertSame(android.os.Looper.getMainLooper(), texture.releasedOn)
            compose.runOnIdle {
                view.surfaceTextureListener!!.onSurfaceTextureSizeChanged(texture, 720, 360)
                view.surfaceTextureListener!!.onSurfaceTextureUpdated(texture)
            }
        } finally { AuditNativeBridge.snapshotFailure = false; player.close() }
    }

    @Test fun homeToSettingsDoesNotShowRetainedDiscover() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking {
            repo.store.open()
            repo.store.set("startupDestination", "discover", true)
            repo.subscriptions.installed.value = listOf(SourcePackage(obj("id" to "hongguo", "name" to "红果", "version" to "1", "program" to "function* main(){}"), "local:audit", "audit", ByteArray(0)))
            repo.saveCatalog("hongguo", "", Catalog(listOf(Drama(obj("id" to "hongguo:retained", "source" to "hongguo", "title" to "不应穿过的发现内容"))), false, 1))
        }
        compose.setContent { CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}) { DramaTheme(repo.store) { RootTabs(true) } } }
        compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("不应穿过的发现内容")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithText("首页").performClick()
        compose.mainClock.advanceTimeBy(400)
        compose.waitForIdle()
        compose.mainClock.autoAdvance = false
        try {
            compose.onNodeWithText("设置").performClick()
            repeat(22) {
                compose.mainClock.advanceTimeByFrame()
                compose.waitForIdle()
                compose.onNodeWithText("不应穿过的发现内容").assertIsNotDisplayed()
            }
            compose.onNodeWithText("首页").performClick()
            repeat(22) {
                compose.mainClock.advanceTimeByFrame()
                compose.waitForIdle()
                compose.onNodeWithText("不应穿过的发现内容").assertIsNotDisplayed()
            }
        } finally { compose.mainClock.autoAdvance = true }
        compose.onNodeWithText("发现").performClick()
        compose.mainClock.advanceTimeBy(400)
        compose.onNodeWithText("不应穿过的发现内容").assertIsDisplayed()
    }

    @Test fun fullscreenControlsDoNotWaitForStatusBarToHide() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking { repo.store.open() }
        val full = mutableStateOf(false)
        var measuredStatus = 0
        compose.setContent { CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}) {
            val statusHeight = WindowInsets.statusBars.getTop(LocalDensity.current)
            androidx.compose.runtime.SideEffect { measuredStatus = statusHeight }
            DramaTheme(repo.store) { FeedScreen(true, full.value, false, {}, onFullScreen = { full.value = it }) }
        } }
        fun statusInset(height: Int) = compose.runOnIdle {
            val insets = androidx.core.view.WindowInsetsCompat.Builder()
                .setInsets(androidx.core.view.WindowInsetsCompat.Type.statusBars(), androidx.core.graphics.Insets.of(0, height, 0, 0))
                .setVisible(androidx.core.view.WindowInsetsCompat.Type.statusBars(), height > 0).build()
            androidx.core.view.ViewCompat.dispatchApplyWindowInsets(compose.activity.window.decorView, insets)
        }
        statusInset(64)
        compose.waitForIdle()
        org.junit.Assert.assertEquals(64, measuredStatus)
        compose.onNodeWithContentDescription("全屏播放").performClick()
        statusInset(64)
        compose.waitForIdle()
        org.junit.Assert.assertEquals(64, measuredStatus)
        val initial = compose.onNodeWithContentDescription("退出全屏").fetchSemanticsNode().boundsInRoot.top
        statusInset(0)
        compose.waitForIdle()
        val hidden = compose.onNodeWithContentDescription("退出全屏").fetchSemanticsNode().boundsInRoot.top
        org.junit.Assert.assertEquals(initial, hidden, .5f)
        org.junit.Assert.assertTrue(initial < 56f)
    }

    @Test fun playerGlassKeepsBackdropVisible() {
        compose.setContent {
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.Center) {
                androidx.compose.foundation.Canvas(Modifier.fillMaxSize()) {
                    drawRect(androidx.compose.ui.graphics.Color.Red, size = androidx.compose.ui.geometry.Size(size.width / 2, size.height))
                }
                Box(Modifier.fillMaxWidth().height(54.dp).playerGlass(androidx.compose.foundation.shape.CircleShape))
            }
        }
        compose.runOnIdle {
            val view = compose.activity.findViewById<android.view.View>(android.R.id.content)
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(android.graphics.Canvas(bitmap))
            val left = bitmap.getPixel(view.width / 2 - 8, view.height / 2)
            val right = bitmap.getPixel(view.width / 2 + 8, view.height / 2)
            org.junit.Assert.assertTrue(android.graphics.Color.red(left) - android.graphics.Color.red(right) > 120)
            org.junit.Assert.assertEquals(0, android.graphics.Color.red(right))
            org.junit.Assert.assertEquals(left, bitmap.getPixel(view.width / 2 - 8, view.height / 2 - 12))
            org.junit.Assert.assertEquals(left, bitmap.getPixel(view.width / 2 - 8, view.height / 2 + 12))
            val file = File("../build/feed-controls-20261110/glass-backdrop.png").apply { parentFile?.mkdirs() }
            file.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun fittedTextureDoesNotFlattenRoundVideoContent() {
        compose.runOnIdle {
            val player = MpvPlayer(org.json.JSONObject(), observeInitially = false)
            val view = FittedVideoTexture(compose.activity, player)
            try {
                for (aspect in listOf(16f / 9f, 9f / 16f)) {
                    view.setVideoAspect(aspect)
                    val source = Bitmap.createBitmap(512, 512, Bitmap.Config.ARGB_8888)
                    val paint = android.graphics.Paint(android.graphics.Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE }
                    android.graphics.Canvas(source).drawCircle(256f, 256f, 48f, paint)
                    for ((width, height) in listOf(360 to 720, 800 to 360, 360 to 720)) {
                        view.layout(0, 0, width, height)
                        val output = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                        val canvas = android.graphics.Canvas(output)
                        canvas.concat(view.getTransform(android.graphics.Matrix()))
                        canvas.drawBitmap(source, null, android.graphics.RectF(0f, 0f, width.toFloat(), height.toFloat()), paint)
                        val pixelsX = (0 until width).filter { android.graphics.Color.alpha(output.getPixel(it, height / 2)) > 230 }
                        val pixelsY = (0 until height).filter { android.graphics.Color.alpha(output.getPixel(width / 2, it)) > 230 }
                        org.junit.Assert.assertTrue(pixelsX.isNotEmpty() && pixelsY.isNotEmpty())
                        org.junit.Assert.assertEquals(pixelsX.size.toFloat(), pixelsY.size.toFloat(), 2f)
                        val folder = File("../build/rotation-stable-20261109").apply { mkdirs() }
                        File(folder, "fit-${if (aspect > 1) "wide" else "tall"}-${width}x${height}.png").outputStream().use { output.compress(Bitmap.CompressFormat.PNG, 100, it) }
                        output.recycle()
                    }
                    source.recycle()
                }
                org.junit.Assert.assertTrue(view.renderSide <= 1920)
                val low = MpvPlayer(obj("lowMemory" to true), observeInitially = false)
                try { org.junit.Assert.assertTrue(FittedVideoTexture(compose.activity, low).renderSide <= 960) } finally { low.close() }
            } finally { player.close() }
        }
    }
    @Test @Config(qualifiers = "w420dp-h844dp-mdpi")
    fun discoverKeepsCachedPageAcrossTabsUntilManualRefresh() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking {
            repo.store.open()
            repo.store.set("startupDestination", "discover", true)
            repo.subscriptions.installed.value = listOf(SourcePackage(obj("id" to "hongguo", "name" to "红果", "version" to "1", "program" to "function* main(){}"), "local:audit", "audit", ByteArray(0)))
            repo.saveCatalog("hongguo", "", Catalog(listOf(Drama(obj("id" to "hongguo:stable", "source" to "hongguo", "title" to "保留这一页"))), true, 1))
        }
        AuditNativeBridge.catalogRequests.set(0)
        compose.setContent { CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}) { DramaTheme(repo.store) { RootTabs(true) } } }
        compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("保留这一页")).fetchSemanticsNodes().isNotEmpty() }
        compose.mainClock.advanceTimeBy(1500)
        org.junit.Assert.assertEquals(0, AuditNativeBridge.catalogRequests.get())
        compose.onNodeWithText("设置").performClick()
        compose.runOnIdle { runBlocking { repo.saveCatalog("hongguo", "", Catalog(emptyList(), false, 1)) } }
        compose.onNodeWithText("发现").performClick()
        compose.onNodeWithText("保留这一页").assertIsDisplayed()
        org.junit.Assert.assertEquals(0, AuditNativeBridge.catalogRequests.get())
        compose.onNodeWithContentDescription("更新剧库").performClick()
        compose.waitUntil(10000) { AuditNativeBridge.catalogRequests.get() == 1 }
        compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("保留这一页")).fetchSemanticsNodes().isEmpty() }
    }

    @Test fun playbackSliderThumbIsCenteredOnTrack() {
        compose.setContent {
            Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.Center) {
                LegacySlider(50f, {}, {}, 100f, Modifier.fillMaxWidth().padding(horizontal = 16.dp).then(Modifier.height(30.dp)), feed = true)
            }
        }
        compose.runOnIdle {
            val view = compose.activity.findViewById<android.view.View>(android.R.id.content)
            val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
            view.draw(android.graphics.Canvas(bitmap))
            fun whiteRows(x: Int) = (0 until bitmap.height).filter { android.graphics.Color.red(bitmap.getPixel(x, it)) > 230 }
            val thumb = whiteRows(bitmap.width / 2)
            val track = whiteRows(bitmap.width / 4)
            org.junit.Assert.assertTrue(thumb.size >= 8)
            org.junit.Assert.assertTrue(track.isNotEmpty())
            org.junit.Assert.assertEquals((track.first() + track.last()) / 2f, (thumb.first() + thumb.last()) / 2f, 1f)
            val output = File("../build/feed-polish-20261109").apply { mkdirs() }
            File(output, "slider.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
            bitmap.recycle()
        }
    }

    @Test fun feedNeighborPanesSurviveBackAndForwardSwipes() {
        val current = androidx.compose.runtime.mutableIntStateOf(0)
        val live = mutableMapOf<String, Any>()
        val created = mutableMapOf<String, Int>()
        val ids = (1..12).map { "video-$it" }
        compose.setContent {
            var retained by remember { mutableStateOf(emptySet<String>()) }
            val keep = feedRetainedPlayers(ids, current.intValue, retained, true, false)
            androidx.compose.runtime.SideEffect { retained = keep }
            val pager = rememberPagerState { ids.size }
            androidx.compose.runtime.LaunchedEffect(current.intValue) { pager.scrollToPage(current.intValue) }
            VerticalPager(pager, Modifier.fillMaxSize(), beyondViewportPageCount = 2, key = { ids[it] }) { index ->
                if (ids[index] in keep) {
                    val instance = remember { Any() }
                    androidx.compose.runtime.DisposableEffect(instance) {
                        live[ids[index]] = instance
                        created[ids[index]] = (created[ids[index]] ?: 0) + 1
                        onDispose { live.remove(ids[index]) }
                    }
                    Box(Modifier.fillMaxSize())
                }
            }
        }
        for (index in 1..4) { compose.runOnIdle { current.intValue = index }; compose.waitForIdle() }
        val third = live["video-3"]; val fifth = live["video-5"]
        org.junit.Assert.assertNotNull(third); org.junit.Assert.assertNotNull(fifth)
        for (index in listOf(3, 2, 3, 4)) {
            compose.runOnIdle { current.intValue = index }; compose.waitForIdle()
            org.junit.Assert.assertSame(third, live["video-3"])
            org.junit.Assert.assertSame(fifth, live["video-5"])
        }
        org.junit.Assert.assertEquals(1, created["video-3"])
        org.junit.Assert.assertEquals(1, created["video-5"])
        compose.runOnIdle { current.intValue = 10 }; compose.waitForIdle()
        org.junit.Assert.assertFalse(live.containsKey("video-3"))
        org.junit.Assert.assertFalse(live.containsKey("video-5"))
    }
    @Test fun fullscreenSizeChangesKeepOutputAndMediaAlive() = runBlocking {
        AuditNativeBridge.commands.clear()
        AuditNativeBridge.playerCreations.set(0)
        val player = MpvPlayer(org.json.JSONObject(), observeInitially = false)
        val texture = android.graphics.SurfaceTexture(0)
        val view = FittedVideoTexture(compose.activity, player)
        try {
            compose.runOnIdle {
                view.layout(0, 0, 360, 720)
                view.setVideoAspect(16f / 9f)
                view.surfaceTextureListener!!.onSurfaceTextureAvailable(texture, 360, 720)
            }
            player.play(true)
            player.open(obj("url" to "/synthetic.mp4"))
            compose.runOnIdle {
                repeat(20) {
                    for ((width, height) in listOf(720 to 360, 360 to 720)) {
                        view.layout(0, 0, width, height)
                        view.surfaceTextureListener!!.onSurfaceTextureSizeChanged(texture, width, height)
                    }
                }
            }
            org.junit.Assert.assertEquals(1, AuditNativeBridge.playerCreations.get())
            org.junit.Assert.assertEquals(1, AuditNativeBridge.commands.count { it.firstOrNull() == "loadfile" })
            org.junit.Assert.assertEquals(1, AuditNativeBridge.commands.count { it.getOrNull(1) == "android-surface-size" })
            org.junit.Assert.assertFalse(AuditNativeBridge.commands.any { it.getOrNull(1) == "vo" })
            org.junit.Assert.assertTrue(player.state.value.playing)
        } finally { player.detach(texture); player.close() }
    }
    @get:Rule val compose = createAndroidComposeRule<androidx.activity.ComponentActivity>()
    @Test fun renderSettings() = render()
    @Test @Config(qualifiers = "w320dp-h640dp-night-mdpi")
    fun renderNarrowDark() = render("narrowDark", listOf("settings", "personalization", "webdav", "downloadPicker", "actionsData", "playerSettings"))
    @Test @Config(qualifiers = "w960dp-h540dp-land-mdpi")
    fun renderLandscapeAndTv() = render("landscape", listOf("playerSettings", "playerEpisodes", "tvSettings", "tvEpisodes"))

    @Test fun horizontalScrubCommitsOnceAndCancellationDoesNotSeek() {
        var preview: Float? = null
        val seeks = mutableListOf<Double>()
        compose.setContent {
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectPlaybackScrub({ PlaybackState(position = 60.0, duration = 1800.0) }, { preview = it }, seeks::add)
            })
        }
        compose.onRoot().performTouchInput {
            down(androidx.compose.ui.geometry.Offset(40f, 200f))
            moveTo(androidx.compose.ui.geometry.Offset(240f, 200f))
        }
        compose.runOnIdle { org.junit.Assert.assertNotNull(preview); org.junit.Assert.assertTrue(seeks.isEmpty()) }
        compose.onRoot().performTouchInput { up() }
        compose.runOnIdle { org.junit.Assert.assertNull(preview); org.junit.Assert.assertEquals(1, seeks.size); org.junit.Assert.assertTrue(seeks.single() > 60) }
        compose.onRoot().performTouchInput {
            down(androidx.compose.ui.geometry.Offset(240f, 200f))
            moveTo(androidx.compose.ui.geometry.Offset(40f, 200f))
            cancel()
        }
        compose.runOnIdle { org.junit.Assert.assertNull(preview); org.junit.Assert.assertEquals(1, seeks.size) }
        compose.onRoot().performTouchInput { swipeUp() }
        compose.runOnIdle { org.junit.Assert.assertEquals(1, seeks.size) }
    }

    @Test @Config(qualifiers = "w320dp-h640dp-night-mdpi")
    fun renderNarrowPlayerAndLockControls() = playerChrome("narrow", true)

    @Test @Config(qualifiers = "w960dp-h540dp-land-mdpi")
    fun renderLandscapePlayerAndLockControls() = playerChrome("landscape", false)

    private fun playerChrome(name: String, largeText: Boolean) {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking { repo.store.open() }
        val detail = Detail(Drama(obj("id" to "synthetic:player", "source" to "synthetic", "title" to "合成视频 · 控制层检查")), listOf(Episode(obj("id" to "1"), 1)))
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}, LocalDensity provides Density(density.density, if (largeText) 1.3f else 1f)) {
                DramaTheme(repo.store) {
                    PlayerPane(detail, active = false, localOnly = true, localPlan = obj("url" to "/synthetic.mp4", "local" to true), externalFull = true, modifier = Modifier.fillMaxSize())
                }
            }
        }
        compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasContentDescription("开始播放")).fetchSemanticsNodes().isNotEmpty() }
        compose.onNodeWithContentDescription("上一集").assertDoesNotExist()
        compose.onNodeWithContentDescription("选集").assertDoesNotExist()
        compose.onNodeWithContentDescription("锁定控制").performClick()
        compose.onNodeWithContentDescription("开始播放").assertDoesNotExist()
        compose.onNodeWithContentDescription("解锁控制").performClick()
        compose.onNodeWithContentDescription("开始播放").assertExists()
        val output = File("../build/visual-audit/compose/player-$name.png").apply { parentFile?.mkdirs() }
        compose.runOnIdle {
            val decor = compose.activity.window.decorView
            val bitmap = Bitmap.createBitmap(decor.width, decor.height, Bitmap.Config.ARGB_8888)
            decor.draw(android.graphics.Canvas(bitmap))
            output.outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }; bitmap.recycle()
        }
    }

    @Test fun feedTapRespondsBeforeDoubleTapWindowCloses() {
        var paused = false
        var likes = 0
        compose.setContent {
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectFeedTaps(100f, onTap = { paused = !paused; true }, onDoubleTap = { paused = !paused; likes++ })
            })
        }
        compose.onRoot().performTouchInput { click() }
        compose.runOnIdle {
            org.junit.Assert.assertTrue(paused)
            org.junit.Assert.assertEquals(0, likes)
        }
        compose.onRoot().performTouchInput { advanceEventTime(60); click() }
        compose.runOnIdle {
            org.junit.Assert.assertFalse(paused)
            org.junit.Assert.assertEquals(1, likes)
        }
    }

    @Test fun feedHoldReleaseDoesNotTogglePlaybackOrLike() {
        val events = mutableListOf<String>()
        compose.setContent {
            Box(Modifier.fillMaxSize().pointerInput(Unit) {
                detectFeedTaps(
                    100f,
                    onHold = {
                        events.add("boost")
                        val restore: () -> Unit = { events.add("normal") }
                        restore
                    },
                    onTap = { events.add("toggle"); true },
                    onDoubleTap = { events.add("like") },
                )
            })
        }
        compose.onRoot().performTouchInput { down(center) }
        compose.mainClock.advanceTimeBy(400)
        compose.onRoot().performTouchInput { advanceEventTime(400); up() }
        compose.runOnIdle { org.junit.Assert.assertEquals(listOf("boost", "normal"), events) }
    }

    @Test fun feedPreparationSharesDetailsAndTransfersOneWarmSession() = runBlocking {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        repo.store.open()
        val drama = Drama(auditData().getJSONArray("dramas").getJSONObject(0))
        repo.subscriptions.installed.value = listOf(SourcePackage(
            obj("id" to drama.source, "name" to "合成来源", "version" to "1", "program" to "function* main(){}"),
            "local:audit", "audit", ByteArray(0),
        ))
        AuditNativeBridge.feedWarmups.set(0)
        val warming = java.util.concurrent.CountDownLatch(1)
        val finish = java.util.concurrent.CountDownLatch(1)
        AuditNativeBridge.onFeedWarmup = {
            warming.countDown()
            check(finish.await(5, java.util.concurrent.TimeUnit.SECONDS))
        }
        val preparation = FeedPlaybackPreparation(repo, this)
        preparation.retain(setOf(drama.id), setOf(drama.id))
        val detail = preparation.detail(drama)
        org.junit.Assert.assertSame(detail, preparation.detail(drama))
        val episode = detail.await().getOrThrow().episodes.first()
        try {
            preparation.prepare(drama, episode, 720)
            preparation.prepare(drama, episode, 720)
            check(withContext(Dispatchers.IO) { warming.await(5, java.util.concurrent.TimeUnit.SECONDS) })
            preparation.retain(setOf(drama.id), setOf(drama.id))
            val plan = requireNotNull(preparation.take(drama, episode, 720))
            org.junit.Assert.assertEquals("feed-audit", plan.text("session"))
            org.junit.Assert.assertNull(preparation.take(drama, episode, 720))
            org.junit.Assert.assertEquals(1, AuditNativeBridge.feedWarmups.get())
            repo.release(plan)
        } finally {
            finish.countDown()
            AuditNativeBridge.onFeedWarmup = {}
            preparation.retain(emptySet(), emptySet())
        }
    }

    @Test fun cleanFeedCanSwipeToWideVideoAndTapOnlyRestoresControls() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking { repo.store.open() }
        val clean = mutableStateOf(true)
        var playerTaps = 0
        compose.setContent {
            CompositionLocalProvider(LocalRepository provides repo) {
                DramaTheme(repo.store) {
                    VerticalPager(rememberPagerState { 2 }, Modifier.fillMaxSize()) { index ->
                        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            Box(Modifier.fillMaxWidth().aspectRatio(if (index == 0) 9f / 16f else 16f / 9f)
                                .hapticClickable { playerTaps++ }, contentAlignment = Alignment.Center) {
                                androidx.compose.material3.Text(if (index == 0) "竖屏视频" else "横屏视频")
                            }
                            if (clean.value) FeedCleanExit { clean.value = false }
                        }
                    }
                }
            }
        }
        val exit = compose.onNodeWithContentDescription("退出清屏模式")
        val portrait = compose.onNodeWithText("竖屏视频")
        portrait.assertIsDisplayed()
        exit.performTouchInput { swipeUp() }
        val landscape = compose.onNodeWithText("横屏视频")
        landscape.assertIsDisplayed()
        val before = landscape.fetchSemanticsNode().boundsInRoot
        exit.performTouchInput { click() }
        exit.assertDoesNotExist()
        org.junit.Assert.assertEquals(before, landscape.fetchSemanticsNode().boundsInRoot)
        compose.runOnIdle { org.junit.Assert.assertEquals(0, playerTaps) }
    }

    @Test fun tabAndSwitchProduceOneFeedbackPerClick() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking { repo.store.open() }
        var feedback = 0
        val view = object : android.view.View(compose.activity) {
            override fun performHapticFeedback(feedbackConstant: Int): Boolean {
                org.junit.Assert.assertEquals(android.view.HapticFeedbackConstants.VIRTUAL_KEY, feedbackConstant)
                feedback++
                return true
            }
        }
        val checked = mutableStateOf(false)
        compose.setContent {
            CompositionLocalProvider(LocalRepository provides repo, LocalNavigate provides {}, androidx.compose.ui.platform.LocalView provides view) {
                DramaTheme(repo.store) {
                    androidx.compose.foundation.layout.Column {
                        SwitchRow("测试开关", checked.value) { checked.value = it }
                        Box(Modifier.weight(1f)) { RootTabs(true) }
                    }
                }
            }
        }
        compose.onNodeWithText("设置").performClick()
        compose.runOnIdle { org.junit.Assert.assertEquals(1, feedback) }
        compose.onNodeWithText("测试开关").performClick()
        compose.runOnIdle { org.junit.Assert.assertTrue(checked.value); org.junit.Assert.assertEquals(2, feedback) }
        compose.onNode(SemanticsMatcher.expectValue(SemanticsProperties.Role, androidx.compose.ui.semantics.Role.Switch)).performClick()
        compose.runOnIdle { org.junit.Assert.assertFalse(checked.value); org.junit.Assert.assertEquals(3, feedback) }
        compose.runOnIdle { runBlocking { repo.store.set("hapticFeedback", false, global = true) } }
        compose.onNodeWithText("发现").performClick()
        compose.runOnIdle { org.junit.Assert.assertEquals(3, feedback) }
    }

    @Test fun bottomTabsMoveContentAndHistoryOpensAsAnOverlay() {
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        val sample = auditData().getJSONArray("dramas").getJSONObject(0)
        runBlocking {
            repo.store.open()
            repo.store.set("history", org.json.JSONArray((1..300).map { index ->
                obj("drama" to sample.copy().put("id", "hongguo:history-$index").put("title", "合成历史 $index"),
                    "episode" to 2, "position" to 31.0, "duration" to 60.0, "updatedAt" to "2026-11-06T00:00:00Z")
            }))
        }
        repo.subscriptions.installed.value = listOf(SourcePackage(
            obj("id" to "hongguo", "name" to "红果", "version" to "1", "program" to "function* main(){}",
                "capabilities" to org.json.JSONArray(listOf("catalogTools"))), "local:audit", "audit", ByteArray(0),
        ))
        repo.ready.value = true
        compose.setContent { CompositionLocalProvider(LocalRepository provides repo) { DramaTheme(repo.store) { App(repo) } } }

        val header = compose.onNodeWithText("红果")
        val headerX = header.fetchSemanticsNode().boundsInRoot.left
        val settings = compose.onNodeWithText("设置")
        val tabBounds = settings.fetchSemanticsNode().boundsInRoot
        val historySummary = compose.onNodeWithText("当前设备 · 300 部", useUnmergedTree = true)
        fun frames(count: Int) {
            repeat(count) {
                compose.mainClock.advanceTimeByFrame()
                compose.waitForIdle()
            }
        }
        compose.mainClock.autoAdvance = false
        try {
            settings.performSemanticsAction(SemanticsActions.OnClick) { check(it()) }
            frames(8)
            org.junit.Assert.assertTrue(compose.onRoot(useUnmergedTree = true).printToString(),
                compose.onAllNodes(androidx.compose.ui.test.hasText("当前设备 · 300 部"), useUnmergedTree = true).fetchSemanticsNodes().isNotEmpty())
            val settingsDuringSlide = historySummary.fetchSemanticsNode().boundsInRoot.left
            header.assertDoesNotExist()
            org.junit.Assert.assertEquals(tabBounds, settings.fetchSemanticsNode().boundsInRoot)
            frames(18)
            org.junit.Assert.assertTrue(settingsDuringSlide > historySummary.fetchSemanticsNode().boundsInRoot.left)

            compose.onNodeWithText("发现").performClick()
            frames(8)
            org.junit.Assert.assertEquals(headerX, header.fetchSemanticsNode().boundsInRoot.left, 1f)
            frames(18)
            settings.performClick()
            frames(22)
            compose.onNodeWithText("当前设备 · 300 部").performClick()
            frames(8)
            val historyHeader = compose.onNodeWithText("最近观看 · 300")
            val historyDuringSlide = historyHeader.fetchSemanticsNode().boundsInRoot.left
            frames(20)
            org.junit.Assert.assertTrue(historyDuringSlide > historyHeader.fetchSemanticsNode().boundsInRoot.left)
            compose.onNodeWithText("合成历史 1").assertExists()
            org.junit.Assert.assertTrue(compose.onAllNodes(androidx.compose.ui.test.hasText("第 2 集 · 0:31")).fetchSemanticsNodes().isNotEmpty())
            compose.onNodeWithContentDescription("返回").performClick()
            frames(24)
            historyHeader.assertDoesNotExist()
        } finally {
            compose.mainClock.autoAdvance = true
        }
    }

    private fun render(profile: String = "", cases: List<String> = listOf(
        "settings", "about", "feedEmpty", "feedFullscreenEmpty", "personalization", "playbackSettings", "homeSettings", "sourceManagement", "homePreferences",
        "profiles", "subscriptions", "sources", "recommendationPreferences", "downloadPreferences",
        "downloadSettings", "resources", "storage", "downloads", "localMedia", "mergeQueue", "backup", "webdav",
        "lan", "detailData", "followingData", "history", "downloadsData", "downloadEpisodes", "discoverData", "downloadPicker",
        "detailExpanded", "actionsData", "webdavUpload", "sourcesData", "playerSettings", "playerSpeed", "playerQuality",
        "playerLocalQuality", "playerEpisodes", "playerLongEpisodes", "discoverSelection", "discoverSort", "profileEditor", "subscriptionsData", "subscriptionsRemove", "authorPanel", "commentsData", "creatorData", "rankingsData",
        "historyScrolled", "discoverScrolled",
    )) {
        AuditNativeBridge.populated = false
        val repo = (RuntimeEnvironment.getApplication() as DramaApplication).repository
        runBlocking { repo.store.open(); repo.store.set("dynamicColor", false, true) }
        org.junit.Assert.assertFalse(repo.store.forceLogin)
        val page = mutableStateOf("settings")
        compose.setContent {
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalRepository provides repo, LocalNavigate provides {},
                LocalDensity provides if (profile == "narrowDark") Density(density.density, 1.3f) else density,
            ) { DramaTheme(repo.store) {
            Surface { Box(Modifier.fillMaxSize()) { androidx.compose.runtime.key(page.value) { when (page.value) {
                "playerSettings", "playerSpeed", "playerQuality", "playerLocalQuality", "playerEpisodes", "playerLongEpisodes", "tvSettings", "tvEpisodes" -> {
                    val open = remember { mutableStateOf(false) }
                    val speed = remember { mutableStateOf(1.25) }
                    val name = page.value
                    val section = when (name) {
                        "playerSpeed" -> "speed"
                        "playerQuality", "playerLocalQuality" -> "quality"
                        "playerEpisodes", "playerLongEpisodes", "tvEpisodes" -> "episodes"
                        else -> "settings"
                    }
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        androidx.compose.material3.TextButton({ open.value = true }) { androidx.compose.material3.Text("打开播放菜单") }
                    }
                    val episodes = remember(name) {
                        if (name == "playerLongEpisodes") (1..72).map { Episode(obj("id" to "$it", "title" to "第${it}集", "vip" to (it > 64)), it) }
                        else auditData().getJSONArray("chapters").objects().map { Episode(it, it.getInt("currentEpisode")) }
                    }
                    if (open.value) PlaybackMenu(
                        section, episodes, if (name == "playerLongEpisodes") 59 else 2, speed.value, 1440, listOf(1080, 720), 1080, name == "playerLocalQuality",
                        true, true, true, false, "下一集已预加载", name.startsWith("tv"), rememberCoroutineScope(),
                        onDismiss = { open.value = false }, onEpisode = {},
                        onChange = { key, value -> if (key == "speed") speed.value = value as Double }, onFavorite = {},
                    )
                }
                "commentsData" -> {
                    val open = remember { mutableStateOf(false) }
                    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                        androidx.compose.material3.TextButton({ open.value = true }) { androidx.compose.material3.Text("打开评论") }
                    }
                    if (open.value) CommentsDialog(Drama(auditData().getJSONArray("dramas").getJSONObject(0))) { open.value = false }
                }
                "settings", "about" -> SettingsScreen()
                "creatorData" -> CreatorScreen(Drama(auditData().getJSONObject("creator").getJSONArray("items").getJSONObject(0)), {})
                "rankingsData" -> RankingsScreen({}, "hongguo")
                "sourcesData" -> SourcesScreen({})
                "feedEmpty", "feedFullscreenEmpty" -> RootTabs(true)
                "authorPanel" -> Box(Modifier.fillMaxSize().background(androidx.compose.ui.graphics.Color.Black), contentAlignment = Alignment.BottomStart) {
                    VideoAuthorPanel(Drama(obj(
                        "id" to "douyin:audit-author", "source" to "douyin", "title" to "这是一段用于检查作者区域的合成文字。".repeat(5),
                        "creatorName" to "合成作者", "creatorId" to "audit123", "creatorSecUid" to "synthetic-author",
                    )), {}, Modifier.padding(16.dp), glass = true)
                }
                "profileEditor" -> ProfilesScreen({})
                "subscriptionsData", "subscriptionsRemove" -> SubscriptionsScreen({})
                "detailData", "detailExpanded" -> DetailScreen(Drama(auditData().getJSONArray("dramas").getJSONObject(0)), {})
                "downloadPicker" -> Page("下载选集", {}) { padding -> Box(Modifier.padding(padding)) { DownloadPicker(Detail(Drama(auditData().getJSONArray("dramas").getJSONObject(0)), auditData().getJSONArray("chapters").objects().map { Episode(it, it.getInt("currentEpisode")) }), embedded = false) } }
                "actionsData" -> { val open = remember { mutableStateOf(false) }; Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { androidx.compose.material3.TextButton({ open.value = true }) { androidx.compose.material3.Text("打开操作") } }; if (open.value) DramaActionsDialog(Drama(auditData().getJSONArray("dramas").getJSONObject(0))) { open.value = false } }
                "webdavUpload" -> WebDavScreen({})
                "followingData" -> LibraryScreen(false)
                "downloadsData", "downloadEpisodes" -> DownloadsScreen({})
                "discoverData", "discoverSelection", "discoverSort", "discoverScrolled" -> RootTabs(true)
                "historyScrolled" -> LibraryScreen(true)
                else -> Destination(Route(page.value)) {}
            } } } }
        } } }
        val output = File("../build/visual-audit/compose", profile).apply { mkdirs() }
        for (name in cases) {
            AuditNativeBridge.longCatalog = name == "discoverScrolled"
            if (name == "historyScrolled") compose.runOnIdle { runBlocking {
                for (row in auditScrollDramas().asReversed()) repo.store.progress(Drama(row), 2, 30.0, 60.0, repo.store.epoch)
            } }
            if (name == "detailData" || name == "discoverScrolled") compose.runOnIdle { runBlocking {
                repo.subscriptions.installed.value = listOf(SourcePackage(obj("id" to "hongguo", "name" to "红果", "version" to "1", "program" to "function* main(){}", "capabilities" to org.json.JSONArray(listOf("catalogTools", "search", "rankings"))), "local:audit", "audit", ByteArray(0)))
                if (name == "discoverScrolled") repo.saveCatalog("hongguo", "", Catalog(auditScrollDramas().map(::Drama), false, 1))
                if (name == "detailData") {
                    for (drama in auditData().getJSONArray("dramas").objects()) repo.store.favorite(Drama(drama))
                    AuditNativeBridge.populated = true
                }
            } }
            if (name == "discoverSelection") compose.runOnIdle {
                repo.subscriptions.installed.value = repo.subscriptions.installed.value.map { pkg ->
                    pkg.copy(document = pkg.document.copy().put("capabilities", org.json.JSONArray(listOf("catalogTools", "search", "rankings", "download"))))
                }
            }
            if (name.startsWith("subscriptions") && name != "subscriptions") compose.runOnIdle {
                repo.subscriptions.installed.value = listOf(
                    SourcePackage(obj("id" to "hongguo", "name" to "合成订阅", "version" to "1.0.0", "program" to "function* main(){}", "capabilities" to org.json.JSONArray(listOf("rankings"))), "local:audit", "audit", ByteArray(0)),
                )
            }
            if (name == "authorPanel") compose.runOnIdle {
                repo.subscriptions.installed.value += SourcePackage(
                    obj("id" to "douyin", "name" to "合成来源", "version" to "1.0.0", "program" to "function* main(){}", "kind" to "video", "capabilities" to org.json.JSONArray(listOf("creator"))),
                    "local:audit", "audit", ByteArray(0),
                )
            }
            if (name == "rankingsData") compose.runOnIdle {
                repo.subscriptions.installed.value = repo.subscriptions.installed.value.map { pkg ->
                    if (pkg.id == "hongguo") pkg.copy(document = pkg.document.copy().put("name", "红果")) else pkg
                }
            }
            compose.runOnIdle { runBlocking { repo.store.set("startupDestination", if (name.startsWith("feed")) "home" else "discover", true) } }
            compose.runOnIdle { page.value = name }; compose.waitForIdle()
            if (name.startsWith("detail")) compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("选集 · 12 集", substring = true)).fetchSemanticsNodes().isNotEmpty() }
            if (name.startsWith("discover")) compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("第二部合成短剧的较长标题")).fetchSemanticsNodes().isNotEmpty() }
            if (name == "discoverSelection") {
                compose.onNodeWithContentDescription("多选下载").performClick()
                compose.onNodeWithText("点选要下载的短剧").assertExists()
                compose.onNodeWithText("第二部合成短剧的较长标题").performClick()
                compose.onNodeWithText("已选 1 部").assertExists()
            }
            if (name == "discoverSort") compose.onNodeWithContentDescription("排序与筛选").performClick()
            if (name == "sourcesData") compose.onNodeWithText("尚未检测连接").assertExists()
            if (name.startsWith("feed")) compose.onNodeWithText("先选择首页推荐内容").assertExists()
            if (name == "feedFullscreenEmpty") {
                compose.onNodeWithContentDescription("全屏播放").performClick()
                compose.onNodeWithContentDescription("退出全屏").assertExists()
            }
            if (name == "commentsData") {
                compose.onNodeWithText("打开评论").performClick()
                compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("评论 · 2")).fetchSemanticsNodes().isNotEmpty() }
            }
            if (name == "about") {
                compose.onNodeWithText("关于应用").performScrollTo().performClick()
                compose.onNodeWithText("查看许可").assertExists()
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                compose.onNodeWithText("作品收藏、作者关注与观看记录保存在当前设备。作者关注不会修改源站账号。")
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { check(it(layouts)) }
                val body = layouts.single().layoutInput.style
                org.junit.Assert.assertEquals(14.sp, body.fontSize)
                org.junit.Assert.assertEquals(400, body.fontWeight?.weight)
            }
            if (name == "downloadEpisodes") {
                compose.onNodeWithText("合成短剧：重逢之后").performClick()
                compose.onNodeWithText("第 2 集").assertExists()
            }
            if (name == "rankingsData") compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("热度 10 万")).fetchSemanticsNodes().isNotEmpty() }
            if (name == "creatorData") compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("作品 · 已加载 3 条")).fetchSemanticsNodes().isNotEmpty() }
            if (name == "profileEditor") {
                compose.onNodeWithText("添加用户").performClick()
                compose.onNodeWithText("0/40").assertExists()
            }
            if (name == "subscriptionsRemove") {
                compose.onNodeWithContentDescription("合成订阅更多操作").performClick()
                compose.onNodeWithText("移除订阅").performClick()
                compose.onNodeWithText("移除站源").assertExists()
            }
            if (name == "detailExpanded") compose.onNodeWithText("展开").performClick()
            if (name == "actionsData") compose.onNodeWithText("打开操作").performClick()
            if (name == "webdavUpload") compose.onNodeWithText("上传备份").performClick()
            if (name.startsWith("player") || name.startsWith("tv")) compose.onNodeWithText("打开播放菜单").performClick()
            if (name == "playerLongEpisodes") {
                compose.onNodeWithText("第 51–72 集").assertExists()
                compose.onNodeWithContentDescription("上一组选集").performClick()
                compose.onNodeWithText("第 1–50 集").assertExists()
                compose.onNodeWithText("定位当前").performClick()
                compose.onNodeWithText("第 51–72 集").assertExists()
            }
            if (name == "playerQuality") compose.onNodeWithText("已保存 1440P 偏好，本集暂无此画质。").assertExists()
            if (name == "playerLocalQuality") compose.onNodeWithText("本集正在播放本地原画，画质偏好用于后续在线播放。").assertExists()
            if (name.endsWith("Scrolled")) {
                val title = compose.onNodeWithText(if (name == "historyScrolled") "最近观看 · 15" else "红果")
                val grid = compose.onNode(SemanticsMatcher.keyIsDefined(SemanticsProperties.VerticalScrollAxisRange))
                compose.waitUntil(10000) {
                    grid.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].maxValue() > 0f
                }
                val before = title.fetchSemanticsNode().boundsInRoot
                val poster = compose.onNodeWithContentDescription("合成短剧：重逢之后 · 更多操作")
                val posterBefore = poster.fetchSemanticsNode().boundsInRoot.top
                grid.performSemanticsAction(SemanticsActions.ScrollBy) { scroll -> check(scroll(0f, 96f)) }
                compose.waitUntil(5000) {
                    grid.fetchSemanticsNode().config[SemanticsProperties.VerticalScrollAxisRange].value() > 0f
                }
                org.junit.Assert.assertEquals(before, title.fetchSemanticsNode().boundsInRoot)
                org.junit.Assert.assertEquals(posterBefore - 96f, poster.fetchSemanticsNode().boundsInRoot.top, 1f)
            }
            if (name == "discoverScrolled") {
                val layouts = mutableListOf<androidx.compose.ui.text.TextLayoutResult>()
                compose.onNodeWithText("第二部合成短剧的较长标题", useUnmergedTree = true)
                    .performSemanticsAction(SemanticsActions.GetTextLayoutResult) { check(it(layouts)) }
                org.junit.Assert.assertEquals(2, layouts.single().lineCount)
            }
            compose.waitForIdle()
            compose.runOnIdle {
                val view = compose.activity.findViewById<android.view.View>(android.R.id.content)
                val bitmap = Bitmap.createBitmap(view.width, view.height, Bitmap.Config.ARGB_8888)
                view.draw(android.graphics.Canvas(bitmap))
                org.robolectric.shadows.ShadowDialog.getLatestDialog()?.takeIf { it.isShowing }?.window?.let { window ->
                    val decor = window.decorView; val canvas = android.graphics.Canvas(bitmap)
                    if (window.attributes.flags and android.view.WindowManager.LayoutParams.FLAG_DIM_BEHIND != 0) {
                        canvas.drawColor(android.graphics.Color.argb((255 * window.attributes.dimAmount).toInt(), 0, 0, 0))
                    }
                    canvas.translate((view.width - decor.width) / 2f, (view.height - decor.height) / 2f)
                    decor.draw(canvas)
                }
                File(output, "$name.png").outputStream().use { bitmap.compress(Bitmap.CompressFormat.PNG, 100, it) }
                bitmap.recycle()
            }
            if (name == "profiles") {
                compose.onNodeWithText("启动时需要登录").performClick()
                compose.waitUntil(5000) { repo.store.forceLogin }
                compose.onNodeWithText("每次打开应用先解锁当前受保护用户").assertExists()
                compose.onNodeWithText("启动时需要登录").performClick()
                compose.waitUntil(5000) { !repo.store.forceLogin }
            }
            if (name == "discoverData") {
                compose.onNodeWithText("设置").performClick()
                compose.onNodeWithText("关于应用").assertExists()
                compose.onNodeWithText("发现").performClick()
                compose.waitUntil(10000) { compose.onAllNodes(androidx.compose.ui.test.hasText("第二部合成短剧的较长标题")).fetchSemanticsNodes().isNotEmpty() }
            }
        }
    }
}
fun auditData() = org.json.JSONObject(File("../tools/visual_audit_data.json").readText())
private fun auditScrollDramas(): List<org.json.JSONObject> {
    val sample = auditData().getJSONArray("dramas").objects()
    return (0 until 15).map { index ->
        val base = sample[index % sample.size]
        if (index < sample.size) base else base.copy().put("id", "hongguo:audit-scroll-$index").put("title", "滚动合成短剧 ${index + 1}")
    }
}

@Implements(value = NativeBridge::class, isInAndroidSdk = false)
class AuditNativeBridge {
    @Implementation fun createPlayer(surface: android.view.Surface, hardware: Boolean, lowMemory: Boolean): Long { playerCreations.incrementAndGet(); return 1L }
    @Implementation fun playerCommand(player: Long, arguments: Array<ByteArray>): Int { commands.add(arguments.map { it.toString(Charsets.UTF_8) }); return 0 }
    @Implementation fun playerGet(player: Long, property: ByteArray): ByteArray = "0".toByteArray()
    @Implementation fun playerSnapshot(player: Long): DoubleArray {
        check(!snapshotFailure) { "synthetic surface loss" }
        return doubleArrayOf(30.0, 120.0, 1920.0, 1080.0, 60.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0)
    }
    @Implementation fun destroyPlayer(player: Long) {}
    companion object {
        val commands = java.util.concurrent.ConcurrentLinkedQueue<List<String>>()
        val playerCreations = java.util.concurrent.atomic.AtomicInteger()
        @Volatile var snapshotFailure = false
        val catalogRequests = java.util.concurrent.atomic.AtomicInteger()
        var populated = false
        var longCatalog = false
        val feedWarmups = java.util.concurrent.atomic.AtomicInteger()
        @Volatile var onFeedWarmup: () -> Unit = {}
        @JvmStatic @Implementation fun __staticInitializer__() {
            ReflectionHelpers.setStaticField(NativeBridge::class.java, "INSTANCE", ReflectionHelpers.callConstructor(NativeBridge::class.java))
        }
    }
    @Implementation fun request(input: ByteArray, source: Boolean): ByteArray {
        val request = org.json.JSONObject(input.toString(Charsets.UTF_8))
        val action = request.text("action")
        if (source) {
            if (action == "catalog" || action == "search") catalogRequests.incrementAndGet()
            val fixture = auditData()
            val value = when (action) {
                "detail" -> obj("drama" to request.getJSONObject("payload").getJSONObject("drama"), "chapters" to fixture.getJSONArray("chapters"))
                "categories" -> obj("items" to org.json.JSONArray())
                "creator" -> fixture.getJSONObject("creator")
                "rankingBoards" -> obj("items" to fixture.getJSONArray("rankingBoards"))
                "rankings" -> fixture.getJSONObject("rankings")
                "comments" -> obj("items" to fixture.getJSONArray("comments"), "cursor" to "done", "total" to 2, "hasMore" to false)
                "catalog", "search" -> obj("items" to if (longCatalog) org.json.JSONArray(auditScrollDramas()) else fixture.getJSONArray("dramas"), "page" to 1, "hasMore" to false)
                else -> org.json.JSONObject()
            }
            return obj("ok" to true, "data" to obj("done" to true, "value" to value)).toString().toByteArray()
        }
        val data = when (action) {
            "resourceSettings", "saveResourceSettings" -> obj("proxyMode" to "auto", "proxyUrl" to "", "catalogConcurrency" to 3, "catalogIntervalMs" to 250, "downloadConcurrency" to 2, "downloadBySource" to false)
            "storage" -> obj("bytes" to 1610612736L, "free" to 21474836480L, "files" to 12, "directory" to "/storage/emulated/0/Android/data/com.real.drama/files/downloads")
            "downloadDirectory" -> obj("directory" to RuntimeEnvironment.getApplication().cacheDir.path)
            "downloads" -> obj("jobs" to if (populated) auditData().getJSONArray("jobs") else org.json.JSONArray())
            "sourceStatus", "cancelRead" -> org.json.JSONObject()
            "localPlayback", "release" -> org.json.JSONObject()
            "subscriptionPlan" -> obj("url" to "https://example.invalid/fixture.mp4", "session" to "feed-audit")
            "subscriptionPrefetch" -> {
                check(request.text("session").startsWith("compose-prefetch:") && request.optLong("sequence") > 0)
                feedWarmups.incrementAndGet()
                onFeedWarmup()
                request.getJSONObject("subscription").put("prefetchedBytes", 1024)
            }
            else -> error("Unexpected native request in visual fixture: $action")
        }
        return obj("ok" to true, "data" to data).toString().toByteArray()
    }
}
