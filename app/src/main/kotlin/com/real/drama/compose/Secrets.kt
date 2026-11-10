package com.real.drama.compose

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import com.it_nomads.fluttersecurestorage.FlutterSecureStorage
import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import com.it_nomads.fluttersecurestorage.SecurePreferencesCallback
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

class Secrets(context: Context) {
    private val legacy = FlutterSecureStorage(context)
    private var legacyReady = false
    private val preferences = context.getSharedPreferences("compose.secrets", Context.MODE_PRIVATE)
    private val lock = Mutex()
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("realdrama.compose.credentials", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("realdrama.compose.credentials", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    suspend fun read(name: String): String = lock.withLock { withContext(Dispatchers.IO) {
        val encoded = preferences.getString(name, null) ?: return@withContext readLegacy(name)
        val bytes = Base64.decode(encoded, Base64.NO_WRAP)
        require(bytes.size >= 28) { "凭据存储损坏" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
        cipher.updateAAD(name.toByteArray())
        cipher.doFinal(bytes.copyOfRange(12, bytes.size)).toString(Charsets.UTF_8)
    } }
    private suspend fun readLegacy(name: String): String {
        val parts = name.split('.')
        val oldKey = if (parts.size == 3 && parts[0] == "cookie") {
            if (parts[1] in setOf("douyin", "bilibili")) "${parts[1]}.cookie.${parts[2]}" else "source.cookie.${parts[1]}.${parts[2]}"
        } else if (name == "webdav.password") "webdavBackup.password" else return ""
        if (!legacyReady) {
            suspendCancellableCoroutine<Unit> { continuation ->
                legacy.initialize(FlutterSecureStorageConfig(mapOf("resetOnError" to false, "migrateOnAlgorithmChange" to false)), object : SecurePreferencesCallback<Void> {
                    override fun onSuccess(value: Void?) { if (continuation.isActive) continuation.resume(Unit) }
                    override fun onError(error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
                })
            }
            legacyReady = true
        }
        return suspendCancellableCoroutine { continuation ->
            legacy.read(legacy.addPrefixToKey(oldKey), object : SecurePreferencesCallback<String> {
                override fun onSuccess(value: String?) { if (continuation.isActive) continuation.resume(value.orEmpty()) }
                override fun onError(error: Exception) { if (continuation.isActive) continuation.resumeWithException(error) }
            })
        }
    }
    suspend fun write(name: String, value: String) = lock.withLock { withContext(Dispatchers.IO) {
        require(value.length <= 65536)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key()); cipher.updateAAD(name.toByteArray())
        val encrypted = cipher.doFinal(value.toByteArray())
        check(preferences.edit().putString(name, Base64.encodeToString(cipher.iv + encrypted, Base64.NO_WRAP)).commit()) { "凭据保存失败" }
    } }
}
