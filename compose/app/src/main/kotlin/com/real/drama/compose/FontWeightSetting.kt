package com.real.drama.compose

import android.content.res.Configuration
import android.os.Build
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.vector.PathParser
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.font.createFontFamilyResolver
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

@Composable
internal fun neutralFontWeightResolver(): androidx.compose.ui.text.font.FontFamily.Resolver {
    val context = LocalContext.current
    val configuration = LocalConfiguration.current
    return remember(context, configuration) {
        val fontContext = if (Build.VERSION.SDK_INT >= 31) {
            context.createConfigurationContext(Configuration(configuration).apply { fontWeightAdjustment = 0 })
        } else context
        createFontFamilyResolver(fontContext)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
internal fun FontWeightSetting(customWeight: Int?, onCommit: (Int?) -> Unit) {
    val configuration = LocalConfiguration.current
    val systemWeight = if (Build.VERSION.SDK_INT >= 31 && configuration.fontWeightAdjustment != Int.MAX_VALUE) {
        configuration.fontWeightAdjustment
    } else 0
    val committed = (customWeight ?: systemWeight).coerceIn(-300, 300)
    var draft by remember(customWeight, committed) { mutableFloatStateOf(committed.toFloat()) }
    val label = if (customWeight == null && draft == committed.toFloat()) "跟随系统" else
        listOf("极细", "细", "偏细", "默认", "中等", "偏粗", "加粗")[((draft + 300) / 100).roundToInt().coerceIn(0, 6)]
    val colors = MaterialTheme.colorScheme
    val density = LocalDensity.current
    fun style(size: Float, lineHeight: Float, baseWeight: Int, adjustment: Int = committed) = TextStyle(
        fontSize = (size * density.fontScale).sp,
        lineHeight = (lineHeight * density.fontScale).sp,
        fontWeight = FontWeight((baseWeight + adjustment).coerceIn(100, 900)),
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )
    CompositionLocalProvider(
        LocalDensity provides Density(density.density, 1f),
        LocalFontFamilyResolver provides neutralFontWeightResolver(),
        LocalMinimumInteractiveComponentSize provides 48.dp,
    ) {
        Column(Modifier.fillMaxWidth()) {
            Text("字体粗细", Modifier.padding(horizontal = 16.dp), style = style(15f, 21f, 600), color = colors.primary)
            Spacer(Modifier.height(12.dp))
            AppearanceCard {
                Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    val bold = remember { PathParser().parsePathString(boldIconPath).toPath() }
                    Canvas(Modifier.size(24.dp)) {
                        scale(size.width / 24f, size.height / 24f, pivot = Offset.Zero) { drawPath(bold, colors.primary) }
                    }
                    Spacer(Modifier.width(16.dp))
                    Column(Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(label, Modifier.weight(1f), style = style(16f, 24f, 600), color = colors.onSurface)
                            TextButton(onClick = hapticClick { onCommit(null) }, enabled = customWeight != null) {
                                Text("重置", style = style(14f, 20.02f, 600))
                            }
                        }
                        Slider(draft, { draft = it }, Modifier.semantics { contentDescription = "字体粗细" },
                            valueRange = -300f..300f, steps = 5,
                            onValueChangeFinished = { onCommit((draft / 100).roundToInt().coerceIn(-3, 3) * 100) })
                    }
                }
                Column(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp, bottom = 14.dp)
                    .background(colors.surfaceContainerHighest.copy(alpha = .3f), RoundedCornerShape(12.dp)).padding(12.dp)) {
                    Text("效果预览 ($label)", style = style(11.5f, 20.02f, 600), color = colors.primary)
                    Spacer(Modifier.height(4.dp))
                    Text("RealDrama 极简现代体验：这是一段用于预览字体粗细的示例文本。@开发者 #话题#",
                        style = style(14f, 19.6f, 400, draft.roundToInt()), color = colors.onSurface)
                }
            }
        }
    }
}

private const val boldIconPath = "M15.6 10.79c.97-.67 1.65-1.77 1.65-2.79 0-2.26-1.75-4-4-4H8c-.55 0-1 .45-1 1v12c0 .55.45 1 1 1h5.78c2.07 0 3.96-1.69 3.97-3.77.01-1.53-.85-2.84-2.15-3.44zM10 6.5h3c.83 0 1.5.67 1.5 1.5s-.67 1.5-1.5 1.5h-3v-3zm3.5 9H10v-3h3.5c.83 0 1.5.67 1.5 1.5s-.67 1.5-1.5 1.5z"
