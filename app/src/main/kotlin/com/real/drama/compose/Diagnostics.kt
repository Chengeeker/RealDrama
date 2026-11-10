package com.real.drama.compose

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.RandomAccessFile
import java.time.Instant
import com.real.drama.BuildConfig

class Diagnostics(private val root: File) {
    private val mutex = Mutex()
    private val fields = setOf("time", "level", "event", "source", "operation", "code", "httpStatus", "host", "stage", "exceptionType", "scriptLine", "attempt", "client", "protocol", "responseType", "fetchMode", "fetchDest")
    private fun safe(row: JSONObject) = JSONObject().apply { row.keys().forEach { key -> if (key in fields && row.opt(key) != JSONObject.NULL) put(key, row.get(key)) } }
    suspend fun record(event: String, values: JSONObject) = mutex.withLock { withContext(Dispatchers.IO) {
        runCatching {
            val file = File(root, "logs/client.log"); file.parentFile!!.mkdirs()
            if (file.length() > 512 * 1024) { val backup = File(file.path + ".1"); atomicWrite(backup, file.readBytes()); atomicWrite(file, byteArrayOf()) }
            file.appendText(canonical(safe(values).put("time", Instant.now().toString()).put("event", event)) + "\n")
        }; Unit
    } }
    suspend fun export(): ByteArray = mutex.withLock { withContext(Dispatchers.IO) {
        val events = mutableListOf<JSONObject>()
        for (name in listOf("app.log.2", "app.log.1", "app.log", "client.log.1", "client.log")) {
            val file = File(root, "logs/$name")
            if (!file.isFile) continue
            val text = RandomAccessFile(file, "r").use { input -> val size = minOf(input.length(), 1024 * 1024L).toInt(); input.seek(input.length() - size); ByteArray(size).also(input::readFully).toString(Charsets.UTF_8) }
            text.lineSequence().forEach { line -> runCatching { safe(JSONObject(line)) }.getOrNull()?.let(events::add) }
        }
        obj("app" to "RealDrama", "version" to BuildConfig.VERSION_NAME, "exportedAt" to Instant.now().toString(), "events" to JSONArray(events.takeLast(5000))).toString().toByteArray()
    } }
}
