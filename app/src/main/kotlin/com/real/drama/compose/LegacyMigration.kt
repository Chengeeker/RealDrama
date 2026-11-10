package com.real.drama.compose

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.security.MessageDigest

suspend fun migrateLegacyFiles(context: Context, target: File) = withContext(Dispatchers.IO) {
    val complete = File(target, "flutter-files-imported.json")
    if (complete.exists()) return@withContext
    val legacy = context.filesDir.canonicalFile
    val location = File(legacy, "download-location.json")
    val oldDownloads = if (location.exists()) {
        require(location.length() <= 65536) { "原下载目录配置过大，原文件已保留" }
        File(JSONObject(location.readText()).getString("directory")).also { require(it.isAbsolute) }
    } else File(legacy, "downloads")
    val destination = File(target, "downloads").apply { mkdirs() }.canonicalFile
    require(destination.path.startsWith(target.canonicalPath + File.separator))
    var copied = 0L
    if (oldDownloads.exists()) {
        require(oldDownloads.isDirectory && !Files.isSymbolicLink(oldDownloads.toPath()))
        val originalRoot = oldDownloads.canonicalFile
        require(!destination.path.startsWith(originalRoot.path + File.separator))
        val entries = originalRoot.walkTopDown().onEnter { dir -> require(!Files.isSymbolicLink(dir.toPath())); true }.filter { it.isFile }.toList()
        val bytes = entries.sumOf { it.length() }
        val already = destination.walkTopDown().filter { it.isFile }.sumOf { it.length() }
        require(destination.usableSpace > (bytes - already).coerceAtLeast(0L) + 64 * 1024 * 1024) { "保留 Flutter 下载文件需要额外 ${formatBytes(bytes - already)} 空间；原文件未移动，可释放空间后重试" }
        for (file in entries) {
            currentCoroutineContext().ensureActive()
            require(!Files.isSymbolicLink(file.toPath()) && file.canonicalPath.startsWith(originalRoot.path + File.separator))
            val relative = file.relativeTo(originalRoot).path
            val output = File(destination, relative).canonicalFile
            require(output.path.startsWith(destination.path + File.separator))
            output.parentFile!!.mkdirs()
            fun digest(value: File): ByteArray {
                val hash = MessageDigest.getInstance("SHA-256")
                value.inputStream().use { input -> val buffer = ByteArray(256 * 1024); while (true) { val count = input.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) } }
                return hash.digest()
            }
            if (!output.exists() || output.length() != file.length() || !MessageDigest.isEqual(digest(output), digest(file))) {
                val temporary = File(output.path + ".compose-copy")
                val expected = file.length()
                file.inputStream().use { input -> temporary.outputStream().use { out -> input.copyTo(out, 256 * 1024); out.fd.sync() } }
                require(file.length() == expected && temporary.length() == expected && MessageDigest.isEqual(digest(file), digest(temporary))) { "原下载文件发生变化，请重新启动迁移" }
                check(temporary.renameTo(output)) { "无法保存迁移后的下载文件" }
            }
            copied += output.length()
        }
        val index = File(destination, "index.json")
        if (index.exists()) {
            require(index.length() <= 32 * 1024 * 1024)
            val rows = JSONArray(index.readText())
            rows.objects().forEach { if (it.text("state") in setOf("queued", "downloading", "removing")) it.put("state", "paused").put("error", "迁移后已暂停，确认后继续") }
            atomicWrite(index, canonical(rows).toByteArray())
        }
    }
    for (name in listOf("resource-settings.json", "lan-identity.json")) {
        val file = File(legacy, name); val out = File(target, name)
        if (file.exists() && !out.exists()) { require(file.length() <= 65536 && !Files.isSymbolicLink(file.toPath())); atomicWrite(out, file.readBytes()) }
    }
    atomicWrite(complete, obj("version" to 1, "bytes" to copied, "originalRetained" to true).toString().toByteArray())
}
