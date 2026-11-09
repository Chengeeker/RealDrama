package com.real.drama.compose

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable
fun TelevisionNavigationButton(label: String, icon: String, selected: Boolean = false, autofocus: Boolean = false, fill: Boolean = true, enabled: Boolean = true, onClick: () -> Unit) {
    var focused by remember { mutableStateOf(false) }; val focus = remember { FocusRequester() }; val colors = MaterialTheme.colorScheme
    LaunchedEffect(Unit) { if (autofocus) focus.requestFocus() }
    Surface(onClick = hapticClick(onClick), enabled = enabled, modifier = (if (fill) Modifier.fillMaxWidth().padding(bottom = 14.dp) else Modifier).focusRequester(focus).onFocusChanged { focused = it.isFocused },
        shape = RoundedCornerShape(14.dp), color = if (selected || focused) colors.primaryContainer else androidx.compose.ui.graphics.Color.Transparent,
        border = BorderStroke(3.dp, if (focused || selected) colors.primary else androidx.compose.ui.graphics.Color.Transparent)) {
        Row(Modifier.padding(horizontal = 16.dp, vertical = 14.dp)) { Glyph(icon, size = 22); Spacer(Modifier.width(8.dp)); Text(label, fontSize = 17.sp) }
    }
}
