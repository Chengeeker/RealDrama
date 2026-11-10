package com.real.drama.compose

import android.app.Application
import android.content.Context
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import java.io.File
import java.util.TimeZone

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35], application = Application::class)
class LocalStoreUpgradeTest {
    private val context get() = RuntimeEnvironment.getApplication()
    private val legacy get() = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
    private val admin = obj("id" to "default", "name" to "管理员", "admin" to true, "sources" to JSONArray())
    private val drama = obj("id" to "hongguo:fixture", "source" to "hongguo", "title" to "合成测试")
    private val localTime = "2026-11-05T21:40:12.123456"
    private val utcTime = "2026-11-05T13:40:12.123456Z"
    private fun watch(time: String) = obj("drama" to drama, "episode" to 3, "position" to 17.5, "duration" to 90.0, "updatedAt" to time)
    private fun inShanghai(block: suspend () -> Unit) = runBlocking {
        val previous = TimeZone.getDefault()
        try {
            TimeZone.setDefault(TimeZone.getTimeZone("Asia/Shanghai"))
            block()
        } finally {
            TimeZone.setDefault(previous)
        }
    }

    @Test fun upgradesFlutterSnapshotAndKeepsProfilesAndPlaybackProgress() = inShanghai {
        val salt = "a".repeat(32)
        val profiles = JSONArray().put(admin.copy().put("salt", salt).put("pinHash", pinHash("sample-admin", salt)))
            .put(obj("id" to "guest", "name" to "测试用户", "admin" to false, "sources" to JSONArray(), "download" to false))
        val values = obj(
            "profiles" to profiles.toString(),
            "activeProfile" to "guest",
            "forceLogin" to true,
            "themeMode" to "dark",
            "history" to JSONArray().put(watch("2026-11-05T13:40:12.123Z")).toString(),
            "profile.guest.history" to JSONArray().put(watch(localTime)).toString(),
            "profile.guest.mediaHistory" to obj("local-video" to watch(localTime)).toString(),
            "profile.guest.favorites" to JSONArray().put(drama).toString(),
        )
        val raw = obj("version" to 1, "values" to values).toString()
        assertTrue(legacy.edit().putString("flutter.localSnapshot.v1", raw).commit())
        val store = LocalStore(context)
        store.open()
        assertNull(store.readError)
        assertEquals("guest", store.active)
        assertFalse(store.canDownload)
        assertEquals("dark", store.text("themeMode", global = true))
        assertEquals("2026-11-05T13:40:12.123Z", JSONArray(store.values.getString("history")).getJSONObject(0).getString("updatedAt"))
        assertEquals(utcTime, store.history().single().getString("updatedAt"))
        assertEquals(17.5, store.history().single().getDouble("position"), 0.0)
        assertEquals(utcTime, store.json("mediaHistory").getJSONObject("local-video").getString("updatedAt"))
        assertEquals("hongguo:fixture", store.favorites().single().id)
        assertEquals(raw, legacy.getString("flutter.localSnapshot.v1", null))
        assertEquals(raw, File(store.directory, "flutter-snapshot.original.json").readText())

        val reopened = LocalStore(context)
        reopened.open()
        assertNull(reopened.readError)
        assertEquals(utcTime, reopened.history().single().getString("updatedAt"))
        assertTrue(reopened.unlock("default", "sample-admin"))
    }

    @Test fun upgradesFlutterPreferencesWithoutSnapshot() = inShanghai {
        val history = JSONArray().put(watch(localTime)).toString()
        assertTrue(legacy.edit().putString("flutter.history", history).commit())
        val store = LocalStore(context)
        store.open()
        assertNull(store.readError)
        assertEquals("default", store.active)
        assertEquals(utcTime, store.history().single().getString("updatedAt"))
        assertEquals(history, legacy.getString("flutter.history", null))
    }

    @Test fun rejectsDamagedTimestampAndKeepsOriginalSnapshot() = inShanghai {
        val values = obj("profiles" to JSONArray().put(admin).toString(), "history" to JSONArray().put(watch("invalid-time")).toString())
        val raw = obj("version" to 1, "values" to values).toString()
        assertTrue(legacy.edit().putString("flutter.localSnapshot.v1", raw).commit())
        val store = LocalStore(context)
        store.open()
        assertNotNull(store.readError)
        assertTrue(store.locked.value)
        assertFalse(File(store.directory, "snapshot.json").exists())
        assertArrayEquals(raw.toByteArray(), store.rawConfiguration())
    }

    @Test fun importsFlutterBackupWithLocalProgressTimestamps() = inShanghai {
        val library = obj("history" to JSONArray().put(watch(localTime)), "mediaHistory" to obj("video" to watch(localTime)))
        val backup = obj("schema" to 1, "app" to "zhenguojian", "profiles" to JSONArray().put(admin), "libraries" to obj("default" to library))
        val values = LocalStore.decodeBackup(backup.toString().toByteArray())
        assertEquals(utcTime, JSONArray(values.getString("history")).getJSONObject(0).getString("updatedAt"))
        assertEquals(utcTime, org.json.JSONObject(values.getString("mediaHistory")).getJSONObject("video").getString("updatedAt"))
    }

    @Test fun fontSizeRoundTripsAndKeepsTheLegacySnapshotReadable() = runBlocking {
        val store = LocalStore(context)
        store.open()
        assertEquals(100, store.fontSizePercent)
        store.set(FONT_SIZE_PERCENT, "125", global = true)
        // Robolectric runs Android's File.renameTo on Windows, where it cannot replace the existing snapshot.
        val pending = File(store.directory, "snapshot.json.new")
        if (File.separatorChar == '\\' && pending.isFile) {
            java.nio.file.Files.move(pending.toPath(), File(store.directory, "snapshot.json").toPath(),
                java.nio.file.StandardCopyOption.REPLACE_EXISTING)
        }
        val raw = org.json.JSONObject(store.rawConfiguration().toString(Charsets.UTF_8))
        assertFalse(raw.getJSONObject("values").has(FONT_SIZE_PERCENT))
        assertEquals("125", raw.getString(FONT_SIZE_PERCENT))
        val reopened = LocalStore(context)
        reopened.open()
        assertNull(reopened.readError)
        assertEquals(125, reopened.fontSizePercent)
        val backup = reopened.exportBackup()
        val invalid = org.json.JSONObject(backup.toString(Charsets.UTF_8)).put(FONT_SIZE_PERCENT, 126)
        assertThrows(IllegalArgumentException::class.java) {
            LocalStore.decodeBackup(invalid.toString().toByteArray())
        }
        reopened.set(FONT_SIZE_PERCENT, "95", global = true)
        reopened.importBackup(backup)
        assertEquals(125, reopened.fontSizePercent)
    }

    @Test fun recentWatchIndexReusesRowsAndReflectsNewProgressAndHiddenSources() = runBlocking {
        val store = LocalStore(context)
        store.open()
        val item = Drama(drama)
        store.progress(item, 3, 17.5, 90.0, store.epoch)
        val first = store.history()
        assertSame(first, store.history())
        assertSame(first.single(), store.watch(item))
        store.progress(item, 3, 21.0, 90.0, store.epoch)
        assertEquals(21.0, store.watch(item)!!.getDouble("position"), 0.0)
        store.set("hiddenSources", JSONArray().put("hongguo"))
        assertTrue(store.history().isEmpty())
        assertNull(store.watch(item))
        store.set("hiddenSources", JSONArray())
        assertEquals(21.0, store.history().single().getDouble("position"), 0.0)
    }
}
