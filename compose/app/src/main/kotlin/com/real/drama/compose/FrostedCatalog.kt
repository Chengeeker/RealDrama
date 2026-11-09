package com.real.drama.compose

import android.os.Build
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.draw.drawWithCache
import androidx.compose.ui.graphics.BlurEffect
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.SubcomposeLayout
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.dp
import kotlin.math.ceil

@Composable
internal fun FrostedCatalog(
    frosted: Boolean,
    overlap: Boolean,
    header: @Composable ColumnScope.() -> Unit,
    bodyModifier: Modifier = Modifier,
    headerVisible: Boolean = true,
    content: @Composable (Dp) -> Unit,
) {
    val colors = MaterialTheme.colorScheme
    val measuredHeader = remember { mutableIntStateOf(0) }
    SubcomposeLayout(Modifier.fillMaxSize().clipToBounds()) { constraints ->
        val bar = if (headerVisible) subcompose("header") {
            val tint = if (frosted) Modifier.background(
                Brush.verticalGradient(listOf(colors.surface, colors.surface.copy(alpha = .60f))),
            ) else Modifier
            Box(Modifier.fillMaxWidth().then(tint).pointerInput(Unit) {
                // Keep covered posters outside the hit path without intercepting the header controls.
                awaitPointerEventScope { while (true) awaitPointerEvent() }
            }) {
                Column(Modifier.fillMaxWidth(), content = header)
                if (frosted) HorizontalDivider(Modifier.align(Alignment.BottomCenter), thickness = .5.dp, color = colors.outlineVariant.copy(alpha = .24f))
            }
        }.single().measure(constraints.copy(minHeight = 0)) else null
        if (bar != null) measuredHeader.intValue = bar.height
        val headerHeight = measuredHeader.intValue.coerceAtMost(constraints.maxHeight)
        val bodyTop = if (overlap) 0 else headerHeight
        val bodyHeight = constraints.maxHeight - bodyTop
        val body = subcompose("body") {
            Box(Modifier.fillMaxSize().then(bodyModifier).background(colors.surface)) {
                content(if (overlap) headerHeight.toDp() else 0.dp)
            }
        }.single().measure(constraints.copy(minHeight = bodyHeight, maxHeight = bodyHeight))
        layout(constraints.maxWidth, constraints.maxHeight) {
            body.placeRelative(0, bodyTop)
            bar?.placeRelative(0, 0)
        }
    }
}

internal fun Modifier.frostedCatalogBackdrop(header: Dp, background: Color, scrollingUnderHeader: () -> Boolean): Modifier {
    // shortcut: Android 8–11 use the shared tint until a hardware backdrop effect is available.
    if (header <= 0.dp || Build.VERSION.SDK_INT < 31) return this
    return drawWithCache {
        val headerHeight = header.toPx().coerceAtMost(size.height)
        val sigma = 20.dp.toPx()
        val sample = obtainGraphicsLayer().apply { renderEffect = BlurEffect(sigma, sigma, TileMode.Clamp) }
        val content = obtainGraphicsLayer()
        val sampleSize = IntSize(ceil(size.width).toInt(), ceil((headerHeight + 3f * sigma).coerceAtMost(size.height)).toInt())
        onDrawWithContent {
            val hardware = drawContext.canvas.nativeCanvas.isHardwareAccelerated
            if (!hardware || !scrollingUnderHeader() || sampleSize.width == 0 || sampleSize.height == 0) {
                drawContent()
            } else {
                content.record { this@onDrawWithContent.drawContent() }
                drawLayer(content)
                sample.record(size = sampleSize) {
                    drawRect(background)
                    drawLayer(content)
                }
                clipRect(bottom = headerHeight) { drawLayer(sample) }
            }
        }
    }
}
