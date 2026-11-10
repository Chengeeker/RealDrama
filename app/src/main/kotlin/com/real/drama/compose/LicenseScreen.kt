package com.real.drama.compose

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.real.drama.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray

@Composable
fun LicenseScreen(back: () -> Unit) {
    val context = LocalContext.current
    var licenses by remember { mutableStateOf<Map<String, List<String>>>(emptyMap()) }
    var selected by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(Unit) {
        try { licenses = withContext(Dispatchers.IO) {
            val result = sortedMapOf<String, MutableList<String>>(String.CASE_INSENSITIVE_ORDER)
            JSONArray(context.assets.open("licenses.json").bufferedReader().use { it.readText() }).objects().forEach { row -> row.array("packages").strings().forEach { name -> result.getOrPut(name) { mutableListOf() }.add(row.getString("text")) } }
            result.mapValues { it.value.distinct() }
        } } catch (cancel: kotlinx.coroutines.CancellationException) { throw cancel } catch (_: Exception) { error = "许可资料读取失败" }
    }
    BackHandler(selected != null) { selected = null }
    Page(selected ?: "许可证", { if (selected != null) selected = null else back() }) { padding ->
        LazyColumn(Modifier.fillMaxSize().padding(padding)) {
            if (selected == null) {
                item { Column(Modifier.fillMaxWidth().padding(24.dp), horizontalAlignment = androidx.compose.ui.Alignment.CenterHorizontally) { Text("RealDrama", style = MaterialTheme.typography.headlineSmall); Text(BuildConfig.VERSION_NAME); Spacer(Modifier.height(18.dp)); Text("开源软件") } }
                if (error != null) item { Text(error!!, Modifier.padding(24.dp)) }
                items(licenses.entries.toList(), key = { it.key }) { (name, texts) -> SettingRow(name, "${texts.size} 个许可证", onClick = { selected = name }) }
            } else {
                licenses[selected].orEmpty().forEach { text -> items(text.split("\n\n")) { paragraph -> Text(paragraph, Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 8.dp), style = MaterialTheme.typography.bodySmall) } }
            }
        }
    }
}
