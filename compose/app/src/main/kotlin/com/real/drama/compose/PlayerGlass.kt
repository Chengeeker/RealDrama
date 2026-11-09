package com.real.drama.compose

import androidx.compose.foundation.background
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape

internal fun Modifier.playerGlass(shape: Shape): Modifier =
    background(Color.Black.copy(alpha = .45f), shape)
