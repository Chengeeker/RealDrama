package com.real.drama.compose

import com.it_nomads.fluttersecurestorage.FlutterSecureStorageConfig
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SecureStorageConfigTest {
    @Test fun explicitBooleanOptionsAreHonored() {
        val oldKeyReader = FlutterSecureStorageConfig(
            mapOf("resetOnError" to false, "migrateOnAlgorithmChange" to false, "migrateWithBackup" to true)
        )
        assertFalse(oldKeyReader.shouldDeleteOnFailure())
        assertFalse(oldKeyReader.shouldMigrateOnAlgorithmChange())
        assertTrue(oldKeyReader.shouldMigrateWithBackup())
    }

    @Test fun stringOptionsAndDefaultsRemainCompatible() {
        val defaults = FlutterSecureStorageConfig(emptyMap())
        assertFalse(defaults.shouldDeleteOnFailure())
        assertTrue(defaults.shouldMigrateOnAlgorithmChange())
        val custom = FlutterSecureStorageConfig(
            mapOf("resetOnError" to "true", "migrateOnAlgorithmChange" to "false")
        )
        assertTrue(custom.shouldDeleteOnFailure())
        assertFalse(custom.shouldMigrateOnAlgorithmChange())
    }
}
