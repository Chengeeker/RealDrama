package com.real.drama.compose

import android.graphics.BitmapFactory
import android.graphics.Bitmap
import android.os.Build
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFontFamilyResolver
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.*
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.*
import com.real.drama.R
import kotlinx.coroutines.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONObject
import android.util.LruCache

val LocalRepository = staticCompositionLocalOf<Repository> { error("Repository unavailable") }
val LocalNavigate = staticCompositionLocalOf<(Route) -> Unit> { error("Navigation unavailable") }
val LocalMessage = staticCompositionLocalOf<(String) -> Unit> { {} }
data class Route(val page: String, val drama: Drama? = null, val source: String = "", val payload: JSONObject = JSONObject())

private val LocalFontWeightAdjustment = compositionLocalOf { 0 }

private fun adjustedWeight(base: Int, adjustment: Int) = FontWeight((base + adjustment).coerceIn(100, 900))

@Composable
internal fun appTextWeight(base: FontWeight) = adjustedWeight(base.weight, LocalFontWeightAdjustment.current)

private fun appTypography(adjustment: Int): Typography {
    fun style(size: Int, line: Int, weight: Int = 400) =
        TextStyle(fontSize = size.sp, lineHeight = line.sp, letterSpacing = 0.sp, fontWeight = adjustedWeight(weight, adjustment))
    return Typography(
        displayLarge = style(57, 64), displayMedium = style(45, 52), displaySmall = style(36, 44),
        headlineLarge = style(32, 40), headlineMedium = style(28, 36), headlineSmall = style(24, 32),
        titleLarge = style(22, 28), titleMedium = style(16, 24, 500), titleSmall = style(14, 20, 500),
        bodyLarge = style(16, 24), bodyMedium = style(14, 20), bodySmall = style(12, 16),
        labelLarge = style(14, 20, 500), labelMedium = style(12, 16, 500), labelSmall = style(11, 16, 500),
    )
}

@Composable
fun televisionMode(): Boolean {
    val device = LocalContext.current
    return when (LocalRepository.current.store.text("displayMode", "auto", true)) {
        "television" -> true
        "standard" -> false
        else -> device.packageManager.hasSystemFeature("android.software.leanback")
    }
}

@Composable
fun ImmersiveBars(enabled: Boolean) {
    val context = LocalContext.current
    DisposableEffect(enabled) {
        val window = (context as? android.app.Activity)?.window?.takeIf { enabled }
        val controller = window?.let { androidx.core.view.WindowCompat.getInsetsController(it, it.decorView) }
        val bars = androidx.core.view.WindowInsetsCompat.Type.systemBars()
        controller?.hide(bars)
        onDispose { controller?.show(bars) }
    }
}

private class DramaFontDensity(val system: Density, private val scale: Float) : Density {
    override val density = system.density
    override val fontScale = system.fontScale * scale
    override fun TextUnit.toDp(): Dp = with(system) { this@toDp.toDp() } * scale
    override fun Dp.toSp(): TextUnit = with(system) { (this@toSp / scale).toSp() }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DramaTheme(store: LocalStore, content: @Composable () -> Unit) {
    val values = store.values
    val context = LocalContext.current
    val dark = when (values.text("themeMode", "system")) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
    val tokens = remember { JSONObject(context.assets.open("theme_tokens.json").bufferedReader().use { it.readText() }) }
    val key = values.text("themeSeed", "coral") + if (dark) ".dark" else ".light"
    val token = tokens.optJSONObject(key) ?: tokens.getJSONObject("coral.${if (dark) "dark" else "light"}")
    fun color(name: String) = Color(token.getLong(name).toInt())
    val scheme = if (Build.VERSION.SDK_INT >= 31 && values.optBoolean("dynamicColor", true)) {
        if (dark) dynamicDarkColorScheme(context) else dynamicLightColorScheme(context)
    } else (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = color("primary"), onPrimary = color("onPrimary"), primaryContainer = color("primaryContainer"), onPrimaryContainer = color("onPrimaryContainer"),
        secondary = color("secondary"), onSecondary = color("onSecondary"), secondaryContainer = color("secondaryContainer"), onSecondaryContainer = color("onSecondaryContainer"),
        tertiary = color("tertiary"), onTertiary = color("onTertiary"), tertiaryContainer = color("tertiaryContainer"), onTertiaryContainer = color("onTertiaryContainer"),
        background = color("surface"), onBackground = color("onSurface"), surface = color("surface"), onSurface = color("onSurface"),
        surfaceVariant = color("surfaceVariant"), onSurfaceVariant = color("onSurfaceVariant"), surfaceTint = color("primary"),
        error = color("error"), onError = color("onError"), errorContainer = color("errorContainer"), onErrorContainer = color("onErrorContainer"),
        outline = color("outline"), outlineVariant = color("outlineVariant"), scrim = color("scrim"),
        inverseSurface = color("inverseSurface"), inverseOnSurface = color("inverseOnSurface"), inversePrimary = color("inversePrimary"),
        surfaceDim = color("surfaceDim"), surfaceBright = color("surfaceBright"), surfaceContainerLowest = color("surfaceContainerLowest"),
        surfaceContainerLow = color("surfaceContainerLow"), surfaceContainer = color("surfaceContainer"), surfaceContainerHigh = color("surfaceContainerHigh"), surfaceContainerHighest = color("surfaceContainerHighest"))
    val customWeight = values.text("fontWeightAdjustment").toIntOrNull()
    val adjustment = customWeight ?: 0
    val typography = remember(adjustment) { appTypography(adjustment) }
    val fontResolver = if (customWeight != null) neutralFontWeightResolver() else LocalFontFamilyResolver.current
    val systemDensity = LocalDensity.current
    val percent = store.fontSizePercent
    val density = remember(systemDensity, percent) {
        if (percent == 100) systemDensity else DramaFontDensity(systemDensity, percent / 100f)
    }
    CompositionLocalProvider(LocalRippleConfiguration provides null, LocalFontWeightAdjustment provides adjustment,
        LocalFontFamilyResolver provides fontResolver, LocalDensity provides density) {
        MaterialTheme(colorScheme = scheme, typography = typography, shapes = Shapes(small = RoundedCornerShape(12.dp), medium = RoundedCornerShape(20.dp), large = RoundedCornerShape(20.dp), extraLarge = RoundedCornerShape(28.dp))) { ProvideTextStyle(typography.bodyMedium, content = content) }
    }
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSlider(value: Float, onValueChange: (Float) -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, valueRange: ClosedFloatingPointRange<Float> = 0f..1f, steps: Int = 0, onValueChangeFinished: (() -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    Slider(value.coerceIn(valueRange), onValueChange, modifier.fillMaxWidth().height(48.dp).padding(horizontal = 14.dp), enabled = enabled, valueRange = valueRange, steps = steps, onValueChangeFinished = onValueChangeFinished,
        thumb = { Surface(Modifier.size(20.dp), shape = androidx.compose.foundation.shape.CircleShape, color = if (enabled) colors.primary else colors.onSurface.copy(alpha = .38f), shadowElevation = 1.dp) {} },
        track = { state -> Canvas(Modifier.fillMaxWidth().height(4.dp)) {
            val y = size.height / 2; val fraction = (state.value - valueRange.start) / (valueRange.endInclusive - valueRange.start)
            drawLine(colors.primary.copy(alpha = .12f), androidx.compose.ui.geometry.Offset(0f, y), androidx.compose.ui.geometry.Offset(size.width, y), 4.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)
            drawLine(colors.primary, androidx.compose.ui.geometry.Offset(0f, y), androidx.compose.ui.geometry.Offset(size.width * fraction, y), 4.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round)
            if (steps > 0) for (tick in 0..steps + 1) {
                val position = tick.toFloat() / (steps + 1)
                drawCircle((if (position <= fraction) colors.onPrimary else colors.primary).copy(alpha = .54f), 1.dp.toPx(), androidx.compose.ui.geometry.Offset(size.width * position, y))
            }
        } })
}

@Composable
fun LegacyChip(selected: Boolean, onClick: () -> Unit, label: @Composable () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, leadingIcon: (@Composable () -> Unit)? = null) {
    val colors = MaterialTheme.colorScheme
    Box(modifier.heightIn(min = 48.dp), contentAlignment = Alignment.Center) {
        Surface(onClick = hapticClick(onClick), enabled = enabled,
            modifier = Modifier.semantics { this.selected = selected }, shape = RoundedCornerShape(12.dp),
            color = if (selected) colors.secondaryContainer else colors.surfaceContainerLow,
            contentColor = if (selected) colors.onSecondaryContainer else colors.onSurfaceVariant,
            border = BorderStroke(1.dp, colors.outlineVariant.copy(alpha = .55f))) {
            Row(Modifier.padding(horizontal = if (leadingIcon == null) 11.dp else 10.dp, vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                if (leadingIcon != null) { leadingIcon(); Spacer(Modifier.width(4.dp)) }
                ProvideTextStyle(MaterialTheme.typography.labelLarge) { label() }
            }
        }
    }
}

@Composable
fun legacyTextFieldColors() = OutlinedTextFieldDefaults.colors(
    focusedContainerColor = MaterialTheme.colorScheme.surfaceContainer, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainer,
    disabledContainerColor = MaterialTheme.colorScheme.surfaceContainer, errorContainerColor = MaterialTheme.colorScheme.surfaceContainer,
    focusedBorderColor = Color.Transparent, unfocusedBorderColor = Color.Transparent, disabledBorderColor = Color.Transparent, errorBorderColor = Color.Transparent)

@Composable
fun LegacyOutlinedButton(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, contentPadding: PaddingValues = ButtonDefaults.ContentPadding, content: @Composable RowScope.() -> Unit) {
    OutlinedButton(hapticClick(onClick), modifier, enabled = enabled, colors = ButtonDefaults.outlinedButtonColors(contentColor = MaterialTheme.colorScheme.primary), border = BorderStroke(1.dp, MaterialTheme.colorScheme.outline.copy(alpha = if (enabled) 1f else .12f)), contentPadding = contentPadding, content = content)
}
@Composable
fun LegacyCard(modifier: Modifier = Modifier, colors: CardColors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainerLow), content: @Composable ColumnScope.() -> Unit) {
    Card(modifier, colors = colors, content = content)
}
@Composable
fun Glyph(name: String, label: String? = null, modifier: Modifier = Modifier, color: Color = LocalContentColor.current, size: Int = 24) {
    val code = iconCodes[name] ?: iconCodes["help_outline_rounded"] ?: 0xe887
    val density = LocalDensity.current
    val glyphSize = if (density is DramaFontDensity) {
        val systemSize = with(density.system) { size.sp.toDp() }
        with(density) { systemSize.toSp() }
    } else size.sp
    Text(String(Character.toChars(code)), modifier.then(if (label == null) Modifier.clearAndSetSemantics {} else Modifier.semantics { contentDescription = label }),
        color = color, fontSize = glyphSize, lineHeight = glyphSize, fontWeight = FontWeight.Normal, letterSpacing = 0.sp, fontFamily = FontFamily(Font(R.font.material_icons)))
}
@Composable
fun IconAction(name: String, label: String, enabled: Boolean = true, action: () -> Unit) {
    IconButton(onClick = hapticClick(action), enabled = enabled) { Glyph(name, label) }
}
@Composable
fun rememberAction(): ((suspend () -> Unit) -> Unit) {
    val scope = rememberCoroutineScope(); val message = LocalMessage.current
    return { action -> scope.launch { try { action() } catch (cancel: CancellationException) { throw cancel } catch (error: Exception) { message(error.message ?: "操作失败，请重试") } } }
}
@Composable
fun StatusPanel(title: String, message: String = "", actionLabel: String = "重试", onRetry: (() -> Unit)? = null, icon: String = "movie_filter_outlined", secondaryAction: (@Composable () -> Unit)? = null) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Column(Modifier.padding(28.dp).verticalScroll(rememberScrollState()), horizontalAlignment = Alignment.CenterHorizontally) {
            Glyph(icon, color = MaterialTheme.colorScheme.primary, size = 56)
            Spacer(Modifier.height(20.dp)); Text(title, style = MaterialTheme.typography.titleLarge, textAlign = TextAlign.Center)
            if (message.isNotEmpty()) { Spacer(Modifier.height(12.dp)); Text(message, textAlign = TextAlign.Center, color = MaterialTheme.colorScheme.onSurfaceVariant) }
            if (onRetry != null) { Spacer(Modifier.height(24.dp)); Button(onClick = hapticClick(onRetry), contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) { Glyph("refresh_rounded", size = 18); Spacer(Modifier.width(8.dp)); Text(actionLabel) } }
            if (secondaryAction != null) { Spacer(Modifier.height(8.dp)); secondaryAction() }
        }
    }
}
@Composable
fun Loading() { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { LoadingRing() } }

@Composable
fun LoadingRing(modifier: Modifier = Modifier, size: Int = 32, color: Color = MaterialTheme.colorScheme.primary) {
    CircularProgressIndicator(modifier.size(size.dp).semantics { contentDescription = "加载中"; liveRegion = LiveRegionMode.Polite }, color = color)
}
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Page(title: String, back: () -> Unit, actions: @Composable RowScope.() -> Unit = {}, content: @Composable (PaddingValues) -> Unit) {
    Scaffold(topBar = { TopAppBar(title = { Text(title, Modifier.padding(start = 16.dp)) }, expandedHeight = 56.dp, navigationIcon = { IconAction("arrow_back_rounded", "返回", action = back) }, actions = actions,
        colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface)) }, content = content)
}
@Composable
fun SettingsColumn(padding: PaddingValues = PaddingValues(), embedded: Boolean = false, top: Int = if (embedded) 28 else 16, bottom: Int = 24, maxWidth: Int = 720, horizontal: Int = 16, content: @Composable ColumnScope.() -> Unit) {
    Box(Modifier.fillMaxSize().padding(padding), contentAlignment = Alignment.TopCenter) {
        Column(Modifier.widthIn(max = maxWidth.dp).fillMaxWidth().verticalScroll(rememberScrollState()).padding(start = horizontal.dp, end = horizontal.dp, top = top.dp, bottom = bottom.dp), content = content)
    }
}
@Composable
fun SettingsSection(title: String, fill: Boolean = true, center: Boolean = false, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().padding(bottom = 32.dp)) {
        Text(title, Modifier.padding(horizontal = 16.dp), style = MaterialTheme.typography.labelLarge.copy(fontWeight = appTextWeight(FontWeight.SemiBold)), color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.height(12.dp))
        Surface(shape = RoundedCornerShape(24.dp), color = MaterialTheme.colorScheme.settingsCardColor()) { Column(if (fill) Modifier.fillMaxWidth() else Modifier, horizontalAlignment = if (center) Alignment.CenterHorizontally else Alignment.Start, content = content) }
    }
}
@Composable
fun SettingRow(title: String, subtitle: String = "", icon: String? = null, enabled: Boolean = true, onClick: (() -> Unit)? = null, trailing: (@Composable () -> Unit)? = null, horizontal: Int = 16) {
    val click = if (onClick == null) Modifier else Modifier.hapticClickable(enabled = enabled, onClick = onClick)
    Row(Modifier.fillMaxWidth().then(click).heightIn(min = if (subtitle.isEmpty()) 56.dp else 72.dp).padding(horizontal = horizontal.dp), verticalAlignment = Alignment.CenterVertically) {
        if (icon != null) { Glyph(icon, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else .38f)); Spacer(Modifier.width(16.dp)) }
        Column(Modifier.weight(1f).padding(vertical = 8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else .38f))
            if (subtitle.isNotEmpty()) Text(subtitle, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else .38f))
        }
        Spacer(Modifier.width(16.dp))
        if (trailing != null) trailing() else if (onClick != null) Glyph("chevron_right_rounded", color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = if (enabled) 1f else .38f))
    }
}
@Composable
fun SwitchRow(title: String, checked: Boolean, subtitle: String = "", enabled: Boolean = true, icon: String? = null, horizontal: Int = 16, onChange: (Boolean) -> Unit) {
    SettingRow(title, subtitle, icon = icon, enabled = enabled, horizontal = horizontal, onClick = { onChange(!checked) }, trailing = { Switch(checked, hapticToggle(onChange), Modifier.padding(horizontal = 4.dp), enabled = enabled) })
}
@Composable
fun ChoiceRow(title: String, value: String, choices: List<Pair<String, String>>, onChange: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    SettingRow(title, choices.firstOrNull { it.first == value }?.second ?: value, onClick = { open = true })
    if (open) LegacyAlertDialog(onDismissRequest = { open = false }, title = { Text(title) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) { choices.forEach { (id, label) ->
            Row(Modifier.fillMaxWidth().hapticClickable { onChange(id); open = false }.padding(vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) { RadioButton(value == id, hapticClick { onChange(id); open = false }); Text(label) }
        } }
    }, confirmButton = { TextButton(hapticClick { open = false }) { Text("取消") } })
}
@Composable
fun ConfirmDialog(title: String, message: String, onDismiss: () -> Unit, confirmLabel: String = "确定", onConfirm: () -> Unit) {
    LegacyAlertDialog(onDismissRequest = onDismiss, title = { Text(title) }, text = { Text(message) }, dismissButton = { TextButton(hapticClick(onDismiss)) { Text("取消") } }, confirmButton = { Button(hapticClick(onConfirm)) { Text(confirmLabel) } })
}
@Composable
fun LegacyAlertDialog(
    onDismissRequest: () -> Unit,
    confirmButton: @Composable () -> Unit,
    title: (@Composable () -> Unit)? = null,
    text: (@Composable () -> Unit)? = null,
    dismissButton: (@Composable () -> Unit)? = null,
) {
    AlertDialog(
        onDismissRequest,
        confirmButton = { FlutterDialogDim(); confirmButton() },
        modifier = Modifier.padding(horizontal = 40.dp, vertical = 24.dp).widthIn(max = 560.dp),
        title = title,
        text = text?.let { content -> {
            CompositionLocalProvider(LocalContentColor provides MaterialTheme.colorScheme.onSurface) {
                ProvideTextStyle(MaterialTheme.typography.bodyMedium) { content() }
            }
        } },
        dismissButton = dismissButton,
        properties = androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false),
    )
}

@Composable
fun FlutterDialogDim() {
    val window = (LocalView.current.parent as? androidx.compose.ui.window.DialogWindowProvider)?.window
    SideEffect { window?.setDimAmount(.54f) }
}

private val coverSlots = Semaphore(3)
private val bitmaps = object : LruCache<String, Bitmap>(12 * 1024 * 1024) { override fun sizeOf(key: String, value: Bitmap) = value.byteCount }

internal suspend fun loadCoverBitmap(repo: Repository, drama: Drama): Bitmap? {
    if (drama.cover.isEmpty()) return null
    bitmaps.get(drama.cover)?.let { return it }
    return try {
        coverSlots.withPermit { withContext(Dispatchers.IO) {
            bitmaps.get(drama.cover)?.let { return@withContext it }
            val file = repo.cover(drama)
            val info = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeFile(file, info)
            val sample = Integer.highestOneBit((maxOf(info.outWidth, info.outHeight) / 512).coerceAtLeast(1))
            BitmapFactory.decodeFile(file, BitmapFactory.Options().apply { inSampleSize = sample })?.also { bitmaps.put(drama.cover, it) }
        } }
    } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { null }
}

@Composable
internal fun rememberCoverBitmap(drama: Drama): State<Bitmap?> {
    val repo = LocalRepository.current
    val bitmap = remember(drama.cover) { mutableStateOf(bitmaps.get(drama.cover)) }
    LaunchedEffect(repo, drama.cover) {
        if (bitmap.value == null) bitmap.value = loadCoverBitmap(repo, drama)
    }
    return bitmap
}

@Composable
fun Cover(drama: Drama, modifier: Modifier = Modifier, poster: Boolean = false, avatar: Boolean = false) {
    val bitmap by rememberCoverBitmap(drama)
    CoverImage(bitmap, modifier, poster, avatar)
}

@Composable
internal fun CoverImage(bitmap: Bitmap?, modifier: Modifier, poster: Boolean = false, avatar: Boolean = false) {
    val colors = MaterialTheme.colorScheme
    Box(modifier.then(if (poster) Modifier.background(androidx.compose.ui.graphics.Brush.linearGradient(listOf(colors.surfaceContainerHighest, colors.surfaceContainer))) else if (avatar) Modifier else Modifier.background(colors.surfaceContainerHighest)), contentAlignment = Alignment.Center) {
        if (bitmap != null) Image(bitmap.asImageBitmap(), null, Modifier.fillMaxSize(), contentScale = androidx.compose.ui.layout.ContentScale.Crop)
        else if (avatar) Glyph("person_rounded", size = 20)
        else Glyph(if (poster) "movie_creation_outlined" else "movie_filter_outlined", color = MaterialTheme.colorScheme.onSurfaceVariant, size = if (poster) 40 else 32)
    }
}
@Composable
fun DramaCover(drama: Drama, modifier: Modifier = Modifier, radius: Int = 14,
    cover: @Composable (Modifier) -> Unit = { Cover(drama, it, poster = true) },
) {
    val repo = LocalRepository.current
    Box(modifier.clip(RoundedCornerShape(radius.dp))) {
        cover(Modifier.matchParentSize())
        Box(Modifier.matchParentSize().background(androidx.compose.ui.graphics.Brush.verticalGradient(0f to Color.Transparent, .5f to Color.Transparent, 1f to Color.Black.copy(alpha = .78f))))
        if ((repo.source(drama.source)?.kind ?: "drama") == "drama" && drama.json.optInt("episodes") > 0) Text("共 ${drama.json.optInt("episodes")} 集", Modifier.align(Alignment.BottomStart).padding(9.dp), color = Color.White, fontSize = 12.sp)
        if (drama.json.optBoolean("vip")) Text("VIP", Modifier.align(Alignment.TopStart).padding(8.dp).background(Color(0xFFF6C86B), RoundedCornerShape(6.dp)).padding(horizontal = 7.dp, vertical = 3.dp), color = Color(0xFF40300D), fontSize = 11.sp, fontWeight = appTextWeight(FontWeight.ExtraBold))
    }
}
fun formatPosition(seconds: Double): String { val value = if (seconds.isFinite()) seconds.toInt().coerceAtLeast(0) else 0; return "${value / 60}:${(value % 60).toString().padStart(2, '0')}" }
fun formatBytes(bytes: Long) = when { bytes < 1024 -> "$bytes B"; bytes < 1024 * 1024 -> "%.1f KB".format(bytes / 1024.0); bytes < 1024 * 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024)); else -> "%.2f GB".format(bytes / (1024.0 * 1024 * 1024)) }
