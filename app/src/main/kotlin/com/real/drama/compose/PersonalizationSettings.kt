package com.real.drama.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import kotlin.math.roundToInt

@Composable
fun SettingsDropdown(value: String, options: List<Pair<String, String>>, enabled: Boolean = true, filled: Boolean = true, label: String? = null, formField: Boolean = false, onChange: (String) -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        Box {
        Row((if (filled) Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceContainer, androidx.compose.foundation.shape.RoundedCornerShape(16.dp)) else Modifier).heightIn(min = if (label != null) { if (formField) 56.dp else 80.dp } else 48.dp).hapticClickable(enabled = enabled) { expanded = true }.padding(horizontal = if (filled) 16.dp else 0.dp, vertical = if (filled && label == null) 12.dp else 0.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(options.firstOrNull { it.first == value }?.second ?: options.first().second, if (filled) Modifier.weight(1f) else Modifier, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurface.copy(alpha = if (enabled) 1f else .38f))
            Spacer(Modifier.width(16.dp)); Glyph("arrow_drop_down", color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (label != null) Text(label, Modifier.padding(horizontal = 16.dp).offset(y = (-8).dp), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(expanded, { expanded = false }) { options.forEach { (key, label) -> DropdownMenuItem(text = { Text(label) }, onClick = hapticClick { expanded = false; onChange(key) }) } }
    }
}

@Composable
fun PersonalizationSettings() {
    val repo = LocalRepository.current; val action = rememberAction()
    fun save(key: String, value: Any?) = action { repo.store.set(key, value, true) }
    AppearanceSection("启动界面") {
        Column(Modifier.padding(start = 16.dp, top = 16.dp, end = 16.dp, bottom = 8.dp)) {
            Text("应用启动时打开", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Spacer(Modifier.height(8.dp))
            SettingsDropdown(repo.store.text("startupDestination", "discover", true), listOf("home" to "首页", "discover" to "发现", "following" to "收藏", "settings" to "设置")) { save("startupDestination", it) }
        }
        Text("下次打开应用时进入所选界面。", Modifier.padding(start = 16.dp, top = 4.dp, end = 16.dp, bottom = 12.dp), style = MaterialTheme.typography.bodyMedium)
    }
    Spacer(Modifier.height(16.dp))
    val modes = listOf("system", "light", "dark")
    AppearanceModes(modes.indexOf(repo.store.text("themeMode", "system", true)), { save("themeMode", modes[it]) })
    Spacer(Modifier.height(16.dp))
    val palette = listOf("coral", "orange", "blue", "green", "purple", "pink", "teal", "slate")
    AppearancePalette(repo.store.bool("dynamicColor", true, true), { save("dynamicColor", it) },
        palette.indexOf(repo.store.text("themeSeed", "coral", true)), { save("themeSeed", palette[it]) },
        appearanceSeeds.toMutableList().apply { this[0] = 0xFFFF664F },
        appearanceNames.toMutableList().apply { this[0] = "珊瑚红"; this[7] = "石板灰" })
    Spacer(Modifier.height(16.dp))
    AppearanceSection("交互与排版") {
        SwitchRow("震动反馈", repo.store.bool("hapticFeedback", true, true)) { save("hapticFeedback", it) }
    }
    Spacer(Modifier.height(16.dp))
    FontSizeSetting(repo.store.fontSizePercent / 100f) {
        save(FONT_SIZE_PERCENT, (it * 100).roundToInt().toString())
    }
    Spacer(Modifier.height(16.dp))
    FontWeightSetting(repo.store.text("fontWeightAdjustment", "", true).toIntOrNull()) {
        save("fontWeightAdjustment", it?.toString())
    }
}
