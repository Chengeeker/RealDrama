package com.real.drama.compose

import android.view.Surface
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject

class NativeFailure(val code: String, message: String) : IllegalStateException(message)
object NativeBridge {
    init { System.loadLibrary("realdrama_jni") }
    external fun request(input: ByteArray, source: Boolean): ByteArray
    external fun createPlayer(surface: Surface, hardware: Boolean, lowMemory: Boolean): Long
    external fun playerCommand(player: Long, arguments: Array<ByteArray>): Int
    external fun playerGet(player: Long, property: ByteArray): ByteArray
    external fun destroyPlayer(player: Long)
    external fun playerSnapshot(player: Long): DoubleArray
    suspend fun call(input: JSONObject, source: Boolean = false): JSONObject = withContext(Dispatchers.IO) {
        val result = JSONObject(request(canonical(input).toByteArray(), source).toString(Charsets.UTF_8))
        if (!result.optBoolean("ok")) throw NativeFailure(result.text("code", "core_error"), result.text("error", "本地核心调用失败"))
        result.optJSONObject("data") ?: obj("value" to result.opt("data"))
    }
}
