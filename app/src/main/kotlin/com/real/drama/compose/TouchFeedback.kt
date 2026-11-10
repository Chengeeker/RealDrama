package com.real.drama.compose

import android.view.HapticFeedbackConstants
import androidx.compose.foundation.clickable
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role

@Composable
internal fun rememberTouchFeedback(): () -> Unit {
    val view = LocalView.current
    val store = LocalRepository.current.store
    return remember(view, store) {
        { if (store.bool("hapticFeedback", true, global = true)) view.performHapticFeedback(HapticFeedbackConstants.VIRTUAL_KEY) }
    }
}

@Composable
internal fun hapticClick(action: () -> Unit): () -> Unit {
    val feedback = rememberTouchFeedback()
    return remember(feedback, action) { { feedback(); action() } }
}

@Composable
internal fun hapticToggle(action: (Boolean) -> Unit): (Boolean) -> Unit {
    val feedback = rememberTouchFeedback()
    return remember(feedback, action) { { value -> feedback(); action(value) } }
}

@Composable
internal fun Modifier.hapticClickable(enabled: Boolean = true, role: Role? = null, onClick: () -> Unit): Modifier =
    clickable(enabled = enabled, role = role, onClick = hapticClick(onClick))
