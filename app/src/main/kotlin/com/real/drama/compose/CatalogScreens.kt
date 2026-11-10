package com.real.drama.compose

import android.content.pm.ActivityInfo
import android.content.res.Configuration
import androidx.activity.compose.LocalActivity
import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.*
import androidx.compose.foundation.lazy.grid.*
import androidx.compose.foundation.pager.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.material3.pulltorefresh.PullToRefreshDefaults
import androidx.compose.material3.pulltorefresh.rememberPullToRefreshState
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.*
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.first
import org.json.JSONArray
import org.json.JSONObject

@Composable
fun DramaGrid(items: List<Drama>, modifier: Modifier = Modifier, more: Boolean = false, loading: Boolean = false, onMore: () -> Unit = {},
    onOpen: (Drama) -> Unit = { }, onAction: ((Drama) -> Unit)? = null, creatorIds: Set<String> = emptySet(), badge: (Drama) -> String = { "" }, subtitle: (Drama) -> String = { it.json.text("category") }, endLabel: String = "", selected: Set<String>? = null, topPadding: Int = 8, headerInset: Dp = 0.dp) {
    val grid = rememberLazyGridState()
    val television = televisionMode()
    val titleSize = if (television) 17.sp else 14.sp
    val subtitleSize = if (television) 14.sp else 12.sp
    val titleHeight = with(LocalDensity.current) { titleSize.toDp() * 2.6f }
    val subtitleHeight = with(LocalDensity.current) { subtitleSize.toDp() * 1.3f }
    BoxWithConstraints(modifier.fillMaxSize()) {
        val inset = if (maxWidth < 600.dp) 16.dp else 24.dp
        val gridWidth = maxWidth - inset * 2
        val columns = if (gridWidth < 600.dp) 3 else (gridWidth.value / 180).toInt().coerceIn(4, 9)
        val spacing = if (gridWidth < 600.dp) 10.dp else 18.dp
        val background = MaterialTheme.colorScheme.surface
        LazyVerticalGrid(GridCells.Fixed(columns),
            modifier = Modifier.frostedCatalogBackdrop(headerInset, background) { grid.firstVisibleItemIndex > 0 || grid.firstVisibleItemScrollOffset > 0 },
            state = grid, contentPadding = PaddingValues(start = inset, end = inset, top = topPadding.dp + headerInset, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(spacing), verticalArrangement = Arrangement.spacedBy(22.dp)) {
            items(items, key = { it.id }) { drama ->
                Column(Modifier.combinedClickable(
                    hapticFeedbackEnabled = false,
                    onClick = hapticClick { onOpen(drama) },
                    onLongClick = if (onAction == null) null else hapticClick { onAction(drama) },
                )) {
                    Box {
                        if (drama.id in creatorIds) Box(Modifier.fillMaxWidth().aspectRatio(2f / 3f).background(MaterialTheme.colorScheme.surfaceContainerHighest, RoundedCornerShape(14.dp)), contentAlignment = Alignment.Center) { Cover(drama, Modifier.size(76.dp).clip(androidx.compose.foundation.shape.CircleShape)) }
                        else DramaCover(drama, Modifier.fillMaxWidth().aspectRatio(2f / 3f))
                        if (selected != null) Box(Modifier.align(Alignment.TopEnd).padding(6.dp).size(32.dp).background(if (drama.id in selected) MaterialTheme.colorScheme.primary else Color.Black.copy(alpha = .64f), androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) { Glyph(if (drama.id in selected) "check_rounded" else "circle_outlined", color = if (drama.id in selected) MaterialTheme.colorScheme.onPrimary else Color.White, size = 22) }
                        else if (onAction != null) Box(Modifier.align(Alignment.TopEnd).padding(2.dp).size(44.dp, 40.dp).hapticClickable { onAction(drama) }, contentAlignment = Alignment.Center) { Box(Modifier.size(36.dp, 32.dp).background(Color.Black.copy(alpha = .64f), androidx.compose.foundation.shape.CircleShape), contentAlignment = Alignment.Center) { Glyph(if (drama.id in creatorIds) "person_remove_alt_1_rounded" else "more_horiz_rounded", "${drama.title} · 更多操作", color = Color.White, size = 20) } }
                        if (badge(drama).isNotEmpty()) Text(badge(drama), Modifier.align(Alignment.BottomStart).fillMaxWidth().padding(6.dp).background(Color.Black.copy(alpha = .72f), RoundedCornerShape(6.dp)).padding(horizontal = 6.dp, vertical = 4.dp), color = Color.White, fontSize = 12.sp, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    }
                    Spacer(Modifier.height(9.dp))
                    Text(drama.title, Modifier.padding(horizontal = 2.dp).height(titleHeight)
                        .wrapContentHeight(Alignment.Top, unbounded = true), fontSize = titleSize, lineHeight = titleSize * 1.3f, fontWeight = appTextWeight(FontWeight.SemiBold), maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Spacer(Modifier.height(4.dp))
                    Text(subtitle(drama), Modifier.padding(horizontal = 2.dp).height(subtitleHeight)
                        .wrapContentHeight(Alignment.Top, unbounded = true), fontSize = subtitleSize, lineHeight = subtitleSize * 1.3f, maxLines = 1, overflow = TextOverflow.Ellipsis, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            if (loading) item(span = { GridItemSpan(maxLineSpan) }) { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator(Modifier.size(24.dp)) } }
            else if (!more && endLabel.isNotEmpty()) item(span = { GridItemSpan(maxLineSpan) }) { Text(endLabel, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = androidx.compose.ui.text.style.TextAlign.Center) }
        }
        val nearEnd by remember(grid, items.size) { derivedStateOf { grid.isScrollInProgress && (grid.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: -1) >= items.size - 6 } }
        LaunchedEffect(nearEnd, more, loading, items.size) { if (nearEnd && more && !loading) onMore() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiscoverScreen(compact: Boolean, onSelectionChanged: (Boolean) -> Unit, bodyModifier: Modifier = Modifier, headerVisible: Boolean = true) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    val packages by repo.subscriptions.installed.collectAsState()
    val sources = repo.available()
    var sourceId by rememberSaveable { mutableStateOf(repo.store.text("source")) }
    val source = sources.firstOrNull { it.id == sourceId } ?: sources.firstOrNull()
    val groupSources = sources.filter { it.catalogGroup == source?.catalogGroup }
    val taxonomy = if (source?.catalogGroup == "hongguo" && groupSources.size == 1) repo.recommendations.groups else emptyList()
    val catalogTools = groupSources.all { "catalogTools" in it.capabilities }
    var categories by remember { mutableStateOf(emptyList<JSONObject>()) }
    var category by rememberSaveable { mutableStateOf("") }
    var format by rememberSaveable { mutableStateOf("all") }
    var suggestions by remember { mutableStateOf(emptyList<String>()) }
    var query by rememberSaveable { mutableStateOf("") }
    var searchText by remember { mutableStateOf(androidx.compose.ui.text.input.TextFieldValue(query)) }
    val suggestionCache = remember(source?.id) { linkedMapOf<String, List<String>>() }
    LaunchedEffect(query) { if (searchText.text != query) searchText = androidx.compose.ui.text.input.TextFieldValue(query, androidx.compose.ui.text.TextRange(query.length)) }
    var submitted by rememberSaveable { mutableStateOf("") }
    var search by rememberSaveable { mutableStateOf(false) }
    var sourceMenu by remember { mutableStateOf(false) }
    var sortMenu by remember { mutableStateOf(false) }
    var catalogView by remember { mutableStateOf(repo.store.json("catalogView")) }
    var rows by remember { mutableStateOf(emptyList<Drama>()) }
    var page by remember { mutableIntStateOf(1) }
    var more by remember { mutableStateOf(false) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var selected by remember { mutableStateOf(setOf<String>()) }
    var selection by remember { mutableStateOf(false) }
    var chosen by remember { mutableStateOf<Drama?>(null) }
    val scope = rememberCoroutineScope()
    var request by remember { mutableStateOf<Job?>(null) }
    var generation by remember { mutableIntStateOf(0) }
    var displayOffset by remember { mutableIntStateOf(0) }
    val sourcePages = remember { mutableMapOf<String, Catalog>() }
    val categoryRequests = remember { mutableMapOf<String, Map<String, String>>() }
    fun submit(value: String) {
        query = value; submitted = value.trim()
        if (submitted.isNotEmpty()) action { repo.store.set("recentSearches", JSONArray((listOf(submitted) + repo.store.list("recentSearches").strings().filter { normalizedSearchText(it) != normalizedSearchText(submitted) }).take(20))) }
    }
    fun load(next: Int, force: Boolean = false) {
        val current = source ?: return
        request?.cancel(); val token = ++generation; loading = true; error = null
        request = scope.launch {
            try {
                val fetchedPages = if (next == 1) linkedMapOf<String, Catalog>() else sourcePages.toMutableMap()
                val targets = if (catalogView.optBoolean("allSources")) sources else groupSources
                val failures = mutableListOf<String>()
                for (target in targets) {
                    if (submitted.isEmpty() && categoryRequests[category]?.containsKey(target.id) == false) continue
                    val requests = if (submitted.isNotEmpty()) listOf("") else if (target.id == "hongguo" && category == "app:recommendations") (if (format == "all") contentFormats.values.toList() else listOfNotNull(contentFormats[format]))
                    else listOf(if (target.id == "hongguo" && category.isEmpty() && format != "all") contentFormats[format].orEmpty() else if (category.startsWith("taxonomy")) "" else categoryRequests[category]?.get(target.id) ?: if (groupSources.size == 1) category else "")
                    for (requestedCategory in requests) {
                        val requestKey = "${target.id}:$requestedCategory"; val previous = fetchedPages[requestKey]
                        if (next > 1 && previous?.more == false) continue
                        try {
                            val cached = if (next == 1 && submitted.isEmpty()) repo.cached(target.id, requestedCategory) else null
                            if (!force && cached != null) { fetchedPages[requestKey] = cached; continue }
                            if (submitted.isNotEmpty() && "search" !in target.capabilities) {
                                val local = repo.cached(target.id)?.items.orEmpty().filter { matchesDramaQuery(it, submitted) }
                                fetchedPages[requestKey] = Catalog(local, false, 1)
                            } else {
                                val requestedPage = if (next == 1) 1 else (previous?.page ?: 0) + 1
                                val result = repo.catalog(target.id, requestedPage, requestedCategory, submitted, force)
                                val base = if (category.startsWith("taxonomy")) cached?.items.orEmpty() + previous?.items.orEmpty() else if (next == 1) emptyList() else previous?.items.orEmpty()
                                fetchedPages[requestKey] = result.copy(items = (base + result.items).distinctBy { it.id })
                                if (result.warning.isNotEmpty()) failures.add(result.warning)
                            }
                        } catch (cancel: CancellationException) { throw cancel } catch (failure: Exception) { failures.add("${target.name}：${failure.message}") }
                    }
                }
                ensureActive()
                if (token == generation) { sourcePages.clear(); sourcePages.putAll(fetchedPages); rows = interleaveDramas(fetchedPages.values.map { it.items }); page = next; more = fetchedPages.values.any { it.more }; error = failures.takeIf { it.isNotEmpty() }?.joinToString("\n") }
            } catch (cancel: CancellationException) { throw cancel } catch (failure: Exception) { if (token == generation) { error = failure.message; more = false } }
            finally { if (token == generation) loading = false }
        }
    }
    LaunchedEffect(source?.id) {
        categories = emptyList(); category = ""; selected = emptySet()
        categoryRequests.clear()
        if (source != null) try {
            val menus = linkedMapOf<String, JSONObject>(); val requests = mutableMapOf<String, MutableMap<String, String>>()
            for (site in groupSources) repo.categories(site.id).filterNot { it.text("id") in setOf("recommend", "series:recommend", "vs:variety", "for-you") }.forEach { entry ->
                val key = if (groupSources.size == 1) entry.text("id") else "category:${entry.text("name").trim()}"
                menus.putIfAbsent(key, entry.copy().put("id", key)); requests.getOrPut(key) { mutableMapOf() }[site.id] = entry.text("id")
            }
            categoryRequests.putAll(requests); categories = menus.values.toList()
        } catch (cancel: CancellationException) { throw cancel } catch (e: Exception) { error = e.message }
    }
    LaunchedEffect(source?.id, category, format, submitted, catalogView.optBoolean("allSources")) { rows = emptyList(); displayOffset = 0; load(1) }
    LaunchedEffect(query, search, source?.id, searchText.composition) {
        suggestions = emptyList()
        val site = groupSources.firstOrNull { "suggestions" in it.capabilities }
        if (search && searchText.composition == null && query.trim().length in 1..100 && query.trim() != submitted && site != null) {
            delay(300)
            try { val key = query.trim(); suggestions = suggestionCache[key] ?: repo.runtime.execute(site.id, "suggestions", obj("query" to key)).array("items").strings().distinct().take(10).also { suggestionCache[key] = it; while (suggestionCache.size > 32) suggestionCache.remove(suggestionCache.keys.first()) } }
            catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { }
        }
    }
    DisposableEffect(Unit) { onDispose { request?.cancel() } }
    if (sources.isEmpty()) {
        Box(Modifier.fillMaxSize().then(bodyModifier).background(MaterialTheme.colorScheme.surface)) {
            StatusPanel("暂无可用站源", "请先导入订阅并启用站源", "站源管理", { nav(Route("sourceManagement")) })
        }
        return
    }
    SideEffect { onSelectionChanged(selection) }
    DisposableEffect(Unit) { onDispose { onSelectionChanged(false) } }
    fun cancelSelection() { selection = false; selected = emptySet() }
    androidx.activity.compose.BackHandler(selection) { cancelSelection() }
    val selectionAction = {
        nav(Route("batchDownloads", payload = obj("dramas" to JSONArray(rows.filter { it.id in selected }.map { it.json }))))
        cancelSelection()
    }
    val frosted = compact && !selection
    val overlap = frosted && !search && category != "app:recommendations" && rows.isNotEmpty() && error == null
    val searchControls: @Composable () -> Unit = {
        OutlinedTextField(searchText, { searchText = it; query = it.text }, Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), singleLine = true, placeholder = { Text("搜索${if (catalogView.optBoolean("allSources")) "全部站源" else source?.name.orEmpty()}") }, trailingIcon = { IconAction("search_rounded", "搜索") { submit(query) } }, shape = RoundedCornerShape(16.dp), keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(imeAction = androidx.compose.ui.text.input.ImeAction.Search), keyboardActions = androidx.compose.foundation.text.KeyboardActions(onSearch = { submit(query) }), textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors())
        val recent = repo.store.list("recentSearches").strings()
        if (query.isEmpty() && recent.isNotEmpty()) LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(recent) { value -> InputChip(false, hapticClick { submit(value) }, label = { Text(value) }) }
            item { IconAction("delete_outline_rounded", "清空搜索记录") { action { repo.store.set("recentSearches", JSONArray()) } } }
        }
        if (suggestions.isNotEmpty()) LazyColumn(Modifier.heightIn(max = 240.dp)) { items(suggestions) { value -> SettingRow(value, icon = "search_rounded", onClick = { suggestions = emptyList(); submit(value) }) } }
    }
    val header: @Composable ColumnScope.() -> Unit = {
        Row(Modifier.fillMaxWidth().height(if (selection) 56.dp else 44.dp).padding(start = 12.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
            if (selection) Text("选择短剧", Modifier.weight(1f), style = MaterialTheme.typography.titleLarge, maxLines = 1, overflow = TextOverflow.Ellipsis)
            else Box(Modifier.weight(1f)) {
                Row(Modifier.height(44.dp).hapticClickable(enabled = sources.distinctBy { it.catalogGroup }.size > 1) { sourceMenu = true }, verticalAlignment = Alignment.CenterVertically) { Text(if (catalogView.optBoolean("allSources")) "全部站源" else source?.catalogName.orEmpty(), maxLines = 1, style = MaterialTheme.typography.titleLarge, fontWeight = appTextWeight(FontWeight.ExtraBold)); if (sources.distinctBy { it.catalogGroup }.size > 1) Glyph("expand_more_rounded") }
                DropdownMenu(sourceMenu, { sourceMenu = false }) {
                    sources.distinctBy { it.catalogGroup }.forEach { item -> DropdownMenuItem(text = { Text(item.catalogName) }, trailingIcon = { if (source?.catalogGroup == item.catalogGroup) Glyph("check_rounded", size = 20) }, onClick = hapticClick { sourceId = item.id; sourceMenu = false; catalogView = catalogView.copy().put("allSources", false); action { repo.store.set("source", item.id); repo.store.set("catalogView", catalogView) } }) }
                }
            }
            if (selection) {
                TextButton(hapticClick { selected = emptySet() }, enabled = selected.isNotEmpty()) { Text("清空") }
                TextButton(hapticClick(::cancelSelection)) { Text("取消") }
            }
            else {
                if (catalogTools && category != "app:recommendations") IconAction("sort_rounded", "排序与筛选") { sortMenu = true }
                if (catalogTools && sources.any { "rankings" in it.capabilities }) IconAction("leaderboard_outlined", "榜单") { nav(Route("rankings", source = source?.catalogGroup.orEmpty())) }
                if (catalogTools && category != "app:recommendations" && repo.store.canDownload && source?.capabilities?.contains("download") == true) IconAction("checklist_rounded", "多选下载") { selection = true }
                if (groupSources.any { "search" in it.capabilities }) IconAction(if (search) "search_off_rounded" else "search_rounded", if (search) "收起搜索" else "搜索") { search = !search; if (!search) { query = ""; submitted = "" }; if (category == "app:recommendations") category = "" }
                if (androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 400 && category != "app:recommendations") IconAction("refresh_rounded", "更新剧库", !loading) { load(1, true) }
            }
        }
        if (search && !frosted) searchControls()
        CatalogCategoryBar(categories, category, taxonomy, format, { category = it }, { format = it }, trailing = { if (groupSources.any { it.id == "huangdou" }) IconAction("workspace_premium_rounded", if (repo.store.bool("hideVip", true)) "VIP：隐藏" else "VIP：显示") { action { repo.store.set("hideVip", !repo.store.bool("hideVip", true)) } } })
        if (!selection && !frosted) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .55f))
    }
    val body: @Composable (Dp) -> Unit = { headerInset -> Column(Modifier.fillMaxSize()) {
        if (search && frosted) searchControls()
        if (category == "app:recommendations") Text("公开推荐 · 已加载 ${rows.size} 部", Modifier.padding(start = 16.dp, bottom = 12.dp), style = MaterialTheme.typography.bodySmall)
        if (error != null) Row(Modifier.fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) { Text(error!!, Modifier.weight(1f), color = MaterialTheme.colorScheme.error); TextButton(hapticClick { load(page) }) { Text("重试") } }
        Box(Modifier.weight(1f)) {
            if (rows.isEmpty()) {
                if (loading) Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        LoadingRing()
                        Spacer(Modifier.height(18.dp))
                        Text("正在加载剧集")
                    }
                } else StatusPanel("暂无内容", onRetry = { load(1, true) })
            }
            else {
                val visible = rows.filterNot { it.source == "huangdou" && repo.store.bool("hideVip", true) && it.json.optBoolean("vip") }.filter { taxonomyMatches(it, category, repo.recommendations) }
                val ordered = if (category == "app:recommendations") visible else sortCatalog(visible, catalogView)
                val offset = if (ordered.isEmpty()) 0 else displayOffset % ordered.size
                val display = ordered.drop(offset) + ordered.take(offset)
                val refreshState = rememberPullToRefreshState()
                PullToRefreshBox(
                    isRefreshing = false,
                    onRefresh = { if (!loading) { displayOffset = 0; load(1, true) } },
                    state = refreshState,
                    indicator = {
                        PullToRefreshDefaults.Indicator(refreshState, isRefreshing = false,
                            modifier = Modifier.align(Alignment.TopCenter).offset(y = headerInset),
                            containerColor = MaterialTheme.colorScheme.surface, color = MaterialTheme.colorScheme.primary)
                    },
                ) {
                    DramaGrid(display, more = more && error == null, loading = loading, onMore = { load(page + 1) }, onOpen = { drama -> if (selection) { if (drama.id in selected) selected = selected - drama.id else if (selected.size < 50) selected = selected + drama.id } else nav(Route("playback", drama)) }, onAction = { drama -> chosen = drama }, badge = { drama -> repo.store.json("followStates").optJSONObject(drama.id)?.let { followLabels[it.text("status")].orEmpty() + followUpdateLabel(it).takeIf(String::isNotEmpty)?.let { label -> " · $label" }.orEmpty() }.orEmpty() }, endLabel = "已经看到这里的全部剧集", selected = if (selection) selected else null, topPadding = 16, headerInset = headerInset)
                }
            }
        }
    } }
    Column(Modifier.fillMaxSize()) {
        Box(Modifier.weight(1f)) {
            FrostedCatalog(frosted, overlap, header, bodyModifier, headerVisible, body)
        }
        if (selection) {
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            BoxWithConstraints(Modifier.fillMaxWidth().windowInsetsPadding(
                WindowInsets.navigationBars.union(WindowInsets(left = 16.dp, top = 12.dp, right = 16.dp, bottom = 12.dp)),
            )) {
                val count = selected.size
                val summary: @Composable () -> Unit = {
                    Column(Modifier.semantics { liveRegion = LiveRegionMode.Polite }) {
                        Text(if (count == 0) "点选要下载的短剧" else "已选 $count 部", style = MaterialTheme.typography.titleSmall.copy(fontWeight = appTextWeight(FontWeight.SemiBold)))
                        Spacer(Modifier.height(4.dp))
                        Text(if (count == 0) "最多 50 部" else "下一步选择分集和画质", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
                val next: @Composable (Modifier) -> Unit = { modifier ->
                    Button(hapticClick(selectionAction), modifier.defaultMinSize(minWidth = 96.dp, minHeight = 48.dp), enabled = count > 0) { Text("下一步") }
                }
                val largeText = with(androidx.compose.ui.platform.LocalDensity.current) { 14.sp.toDp() > 21.dp }
                if (maxWidth < 320.dp || largeText) Column {
                    summary()
                    Spacer(Modifier.height(12.dp))
                    next(Modifier.fillMaxWidth())
                } else Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.weight(1f)) { summary() }
                    Spacer(Modifier.width(16.dp))
                    next(Modifier)
                }
            }
        }
    }
    if (sortMenu) {
        var draft by remember { mutableStateOf(catalogView.copy()) }
        ModalBottomSheet(scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), onDismissRequest = { sortMenu = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true), containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
            Column(Modifier.verticalScroll(rememberScrollState()).padding(start = 16.dp, end = 16.dp, bottom = 20.dp)) {
                Text("排序与筛选", style = MaterialTheme.typography.titleMedium); Spacer(Modifier.height(16.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { catalogSortLabels.forEach { (id, name) -> LegacyChip(draft.text("sort", "source") == id, { draft = draft.copy().put("sort", id) }, label = { Text(name) }) } }
                Spacer(Modifier.height(24.dp)); Text("剧集状态"); Spacer(Modifier.height(8.dp))
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) { catalogReleaseLabels.forEach { (id, name) -> LegacyChip(draft.text("release") == id, { draft = draft.copy().put("release", id) }, label = { Text(name) }) } }
                Spacer(Modifier.height(16.dp))
                Text("排序和筛选作用于已加载的剧集；缺少排序资料的条目排在最后。", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.height(20.dp)); Button(hapticClick { catalogView = draft; sortMenu = false; action { repo.store.set("catalogView", draft) } }, Modifier.fillMaxWidth()) { Text("应用") }
            }
        }
    }
    chosen?.let { drama -> DramaActionsDialog(drama, onSelect = { selection = true; selected = setOf(drama.id) }) { chosen = null } }
}

internal fun feedOrientationRequest(full: Boolean, aspectRatio: Double, returnOrientation: Int?): Int? =
    if (full) when {
        aspectRatio > 1.0 -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        aspectRatio > 0.0 -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_PORTRAIT
        else -> null
    } else when (returnOrientation) {
        Configuration.ORIENTATION_LANDSCAPE -> ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
        Configuration.ORIENTATION_PORTRAIT -> ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        else -> null
    }

@Composable
fun FeedScreen(active: Boolean, full: Boolean, clean: Boolean, onClean: (Boolean) -> Unit, onBoost: (Boolean) -> Unit = {},
    commentsProgress: State<Float>? = null, commentsVideoHeight: Dp = 0.dp, onComments: (Drama) -> Unit = {}, onFullScreen: (Boolean) -> Unit,
) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val packages by repo.subscriptions.installed.collectAsState()
    var rows by remember { mutableStateOf(emptyList<Drama>()) }
    var loading by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var refresh by remember { mutableIntStateOf(0) }
    var pageControls by remember { mutableStateOf<Pair<String, PlayerActions>?>(null) }
    var boostingDramaId by remember { mutableStateOf<String?>(null) }
    val activity = LocalActivity.current
    DisposableEffect(activity, active) {
        val window = activity?.window?.takeIf { active }
        val previous = window?.attributes?.rotationAnimation
        if (window != null) window.attributes = window.attributes.apply {
            rotationAnimation = android.view.WindowManager.LayoutParams.ROTATION_ANIMATION_ROTATE
        }
        onDispose { if (window != null && previous != null) window.attributes = window.attributes.apply { rotationAnimation = previous } }
    }
    val screenOrientation = LocalConfiguration.current.orientation
    val television = televisionMode()
    var returnOrientation by remember { mutableStateOf<Int?>(null) }
    var videoAspect by remember { mutableStateOf<Pair<String, Double>?>(null) }
    fun setFullscreen(enabled: Boolean) {
        if (enabled == full) return
        if (enabled && returnOrientation == null) returnOrientation = screenOrientation
        onFullScreen(enabled)
    }
    ImmersiveBars(active && (full || clean))
    val pages = remember { mutableMapOf<String, Int>() }; val finished = remember { mutableSetOf<String>() }
    val hiddenSources = repo.store.text("hiddenSources", "[]")
    val rawPreference = repo.store.text("homeFeedPreferences", "{}")
    val preference = remember(rawPreference) { JSONObject(rawPreference) }
    val enabled = remember(packages, hiddenSources, rawPreference, repo.store.epoch) {
        repo.available().filter { it.kind != "live" && ("catalog" in it.capabilities || "recommendations" in it.capabilities) && preference.optJSONObject(it.id)?.optBoolean("enabled") == true }
    }
    val pager = rememberPagerState { rows.size }
    val pageIndex = pager.settledPage
    suspend fun awaitScrollIdle() {
        if (pager.isScrollInProgress) snapshotFlow { pager.isScrollInProgress }.first { !it }
    }
    val scope = rememberCoroutineScope()
    val preparation = remember(repo, scope) { FeedPlaybackPreparation(repo, scope) }
    DisposableEffect(preparation) { onDispose { preparation.retain(emptySet(), emptySet()) } }
    var generation by remember { mutableIntStateOf(0) }
    var feedJob by remember { mutableStateOf<Job?>(null) }
    var emptyAttempts by remember { mutableIntStateOf(0) }
    var consecutiveUnavailable by remember { mutableIntStateOf(0) }
    var batchRevision by remember { mutableIntStateOf(0) }
    var retryAt by remember { mutableLongStateOf(0L) }
    var firstPlayback by remember { mutableStateOf(false) }
    var readyForPreload by remember(active) { mutableStateOf<String?>(null) }
    var openedForPreload by remember(active, generation) { mutableStateOf<String?>(null) }
    var batchCursor by rememberSaveable { mutableIntStateOf(0) }
    val sessionUnavailable = remember { mutableSetOf<String>() }
    val batches = remember(enabled, rawPreference) { feedCategoryBatches(enabled.associate { it.id to feedRequestCategories(it.id, preference.optJSONObject(it.id) ?: JSONObject()) }) }
    val playbackPreferences = repo.store.text("playback", "{}")
    val playback = remember(playbackPreferences) { JSONObject(playbackPreferences) }
    val lowMemory = playback.optBoolean("lowMemory")
    val radius = if (lowMemory) 0 else 2
    val homeQuality = playback.optInt("homeQuality")
    suspend fun append() {
        val token = generation
        try {
            val order = batches.indices.map { (batchCursor + it) % batches.size }
            val unrequested = order.filter { index -> batches[index].any { (source, category) -> "$source:$category" !in pages && "$source:$category" !in finished } }
            val pending = (unrequested.ifEmpty { order.filter { index -> batches[index].any { (source, category) -> "$source:$category" !in finished } } })
                .take(if (pages.isEmpty()) 2 else 1)
            val failures = mutableListOf<String>()
            suspend fun publish(source: String, items: List<Drama>) {
                if (items.isEmpty()) return
                val config = preference.optJSONObject(source) ?: JSONObject()
                val names = feedExcludedCategories(source, config)
                val existing = rows.map { it.id }.toHashSet()
                val hideVip = repo.store.bool("hideVip", true)
                val candidates = items.filterNot {
                    it.id in existing || it.id in sessionUnavailable || it.source == "huangdou" && it.json.optBoolean("vip") && hideVip
                }
                if (candidates.isEmpty()) return
                val ranked = repo.recommendations.rank(candidates, repo.store, refresh, excludeRecent = true, excludedCategories = names)
                if (token != generation || !repo.store.allowed(source)) return
                rows = (rows + ranked.filterNot { it.id in sessionUnavailable }).distinctBy { it.id }
            }
            for (batch in pending) {
                batchCursor = (batch + 1) % batches.size
                for ((source, category) in batches[batch]) {
                    val key = "$source:$category"
                    if (key in finished) continue
                    val douyin = repo.source(source)?.group == "douyin"
                    try {
                        val next = (pages[key] ?: 0) + 1
                        if (next == 1) repo.cached(source, category)?.let { publish(source, it.items) }
                        val page = repo.catalog(source, next, category, force = refresh > 0 && next == 1)
                        currentCoroutineContext().ensureActive()
                        if (token != generation) return
                        publish(source, page.items)
                        val seconds = feedRetrySeconds(page.warning, douyin)
                        if (seconds != null) {
                            retryAt = System.currentTimeMillis() + seconds * 1000L
                            break
                        }
                        pages[key] = page.page
                        if (!page.more || page.page < next) finished.add(key)
                    } catch (cancel: CancellationException) {
                        throw cancel
                    } catch (failure: Exception) {
                        if (token != generation) return
                        val message = failure.message.orEmpty()
                        val seconds = feedRetrySeconds(message, douyin)
                        if (seconds != null) {
                            retryAt = System.currentTimeMillis() + seconds * 1000L
                            break
                        }
                        failures.add(message.ifEmpty { "目录加载失败" })
                        finished.add(key)
                    }
                }
                if (retryAt > System.currentTimeMillis()) break
            }
            currentCoroutineContext().ensureActive(); if (token != generation) return
            if (rows.isNotEmpty()) emptyAttempts = 0
            else if (retryAt == 0L) emptyAttempts += pending.size
            error = if (rows.isNotEmpty()) null else failures.takeIf { it.isNotEmpty() }?.take(3)?.joinToString("；")
                ?: if (emptyAttempts >= 8) "已检查多个目录批次，暂时没有可播放内容。点击刷新重新尝试。" else null
        } finally {
            if (token == generation) {
                loading = false
                batchRevision++
            }
        }
    }
    fun unavailable(drama: Drama) {
        if (!sessionUnavailable.add(drama.id)) return
        val removed = rows.indexOfFirst { it.id == drama.id }
        if (removed < 0) return
        val selectedPage = pager.settledPage
        val nextPage = selectedPage - if (removed < selectedPage) 1 else 0
        consecutiveUnavailable++
        rows = rows.filterNot { it.id == drama.id }
        if (rows.isNotEmpty()) pager.requestScrollToPage(nextPage.coerceIn(0, rows.lastIndex))
        repo.recommendations.forget(drama)
        if (consecutiveUnavailable >= 20 && rows.isEmpty()) error = "已跳过 20 部暂不可用内容，点击刷新继续加载。"
        val expected = repo.store.epoch
        scope.launch {
            try {
                if (expected != repo.store.epoch) return@launch
                val now = System.currentTimeMillis(); val old = repo.store.json("unavailableFeedDramas")
                val saved = old.keys().asSequence().filter { old.optLong(it) > now }.map { it to old.optLong(it) }.toMap().toMutableMap()
                saved["${drama.source}:${drama.id}"] = now + 12 * 60 * 60 * 1000
                repo.store.set("unavailableFeedDramas", JSONObject(saved.entries.sortedByDescending { it.value }.take(500).associate { it.key to it.value }))
            } catch (cancel: CancellationException) { throw cancel } catch (_: Exception) { repo.diagnostics.record("feed_unavailable_save_failed", JSONObject()) }
        }
    }
    LaunchedEffect(rawPreference, hiddenSources, repo.store.epoch, packages, refresh) {
        feedJob?.cancel(); generation++; loading = false; emptyAttempts = 0; consecutiveUnavailable = 0
        firstPlayback = false; retryAt = 0; error = null
        readyForPreload = null
        pageControls = null
        preparation.retain(emptySet(), emptySet())
        rows = emptyList(); pages.clear(); finished.clear()
        pager.requestScrollToPage(0)
    }
    LaunchedEffect(pageIndex, repo.store.json("feedRecommendation").toString(), repo.recommendations.revision) {
        val queue = rows
        val first = minOf(queue.size, pageIndex + 6); val end = minOf(queue.size, first + 60)
        if (first < end) {
            val ranked = repo.recommendations.rank(queue.subList(first, end), repo.store, refresh)
            if (rows === queue) rows = queue.take(first) + ranked + queue.drop(end)
        }
    }
    val currentDrama = rows.getOrNull(pageIndex)
    val boost = active && boostingDramaId != null && boostingDramaId == currentDrama?.id
    LaunchedEffect(boost) { onBoost(boost) }
    val manageOrientation = active && !television && returnOrientation != null
    DisposableEffect(activity, manageOrientation) {
        val previous = activity?.requestedOrientation
        onDispose { if (manageOrientation && previous != null) activity.requestedOrientation = previous }
    }
    val aspectRatio = videoAspect?.takeIf { it.first == currentDrama?.id }?.second ?: 0.0
    SideEffect {
        if (manageOrientation && activity != null) {
            val target = feedOrientationRequest(full, aspectRatio, returnOrientation)
            if (target != null && activity.requestedOrientation != target) activity.requestedOrientation = target
        }
    }
    LaunchedEffect(active, full, screenOrientation, returnOrientation) {
        if (!active) {
            if (full) setFullscreen(false)
            returnOrientation = null
        } else if (!full && screenOrientation == returnOrientation) {
            returnOrientation = null
        }
    }
    DisposableEffect(currentDrama?.id, active) {
        val started = System.currentTimeMillis(); val epoch = repo.store.epoch
        onDispose { if (active && currentDrama != null && currentDrama.id !in sessionUnavailable && epoch == repo.store.epoch && !repo.store.locked.value) repo.recommendations.signal(currentDrama, leavingFeedValue((System.currentTimeMillis() - started) / 1000, repo.store.watch(currentDrama), started)) }
    }
    LaunchedEffect(currentDrama?.id, active) {
        if (active && currentDrama != null) {
            repo.recommendations.expose(currentDrama)
            try { repo.store.saveExposures(repo.recommendations.recent.toList()) }
            catch (cancel: CancellationException) { throw cancel }
            catch (_: Exception) { repo.diagnostics.record("feed_exposure_save_failed", JSONObject()) }
        }
    }
    LaunchedEffect(pageIndex, rows.size, active, generation, batchRevision, retryAt, firstPlayback) {
        if (!active || batches.isEmpty() || loading || consecutiveUnavailable >= 20) return@LaunchedEffect
        val wait = retryAt - System.currentTimeMillis()
        if (wait > 0) delay(wait)
        if (retryAt != 0L) retryAt = 0
        val needMore = if (rows.isEmpty()) emptyAttempts < 8 else firstPlayback && rows.size - pageIndex <= maxOf(3, (rows.size + 1) / 2)
        if (needMore && batches.any { batch -> batch.any { (source, category) -> "$source:$category" !in finished } }) {
            loading = true
            feedJob = scope.launch { append() }
        }
    }
    val controls = pageControls?.takeIf { it.first == currentDrama?.id }?.second
    val currentSource = currentDrama?.let { repo.source(it.source) }
    val lifecycleState by LocalLifecycleOwner.current.lifecycle.currentStateFlow.collectAsState()
    val canPreload = active && !lowMemory && lifecycleState.isAtLeast(Lifecycle.State.STARTED)
    val afterCurrent = (pageIndex + 1).coerceAtMost(rows.size)
    val nextDrama = rows.getOrNull(afterCurrent)
    fun isDouyin(drama: Drama) = repo.source(drama.source)?.group == "douyin"
    fun canWarm(drama: Drama) = !isDouyin(drama) || !repo.runtime.douyinCoolingDown
    val upcoming = if (canPreload) feedUpcomingPreloads(
        rows.subList(afterCurrent, (afterCurrent + feedLookahead).coerceAtMost(rows.size)), currentSource?.group == "douyin", ::isDouyin,
    ) else emptyList()
    val previous = rows.subList((afterCurrent - 1 - radius).coerceAtLeast(0), (afterCurrent - 1).coerceAtLeast(0))
    LaunchedEffect(generation, currentDrama?.id, upcoming, radius, readyForPreload) {
        if (currentDrama == null || readyForPreload != currentDrama.id) return@LaunchedEffect
        val visibleNeighbors = rows.subList(afterCurrent, (afterCurrent + radius).coerceAtMost(rows.size)).toSet()
        for (drama in upcoming) {
            if (drama in visibleNeighbors || !canWarm(drama)) continue
            awaitScrollIdle()
            if (canWarm(drama)) loadCoverBitmap(repo, drama)
        }
    }
    var retainedPlayers by remember(generation, homeQuality, lowMemory) { mutableStateOf(emptySet<String>()) }
    val warmNext = currentDrama != null && openedForPreload == currentDrama.id && nextDrama != null && nextDrama in upcoming && canWarm(nextDrama)
    val playerIds = if (active) feedRetainedPlayers(rows.map { it.id }, pageIndex, retainedPlayers, warmNext, lowMemory) else emptySet()
    SideEffect { if (retainedPlayers != playerIds) retainedPlayers = playerIds }
    LaunchedEffect(active, generation, currentDrama?.id, upcoming.map { it.id }, previous.map { it.id }, homeQuality, readyForPreload, radius) {
        val forward = listOfNotNull(currentDrama) + upcoming
        val nearby = forward + previous.asReversed()
        preparation.retain(
            if (active) nearby.map { it.id }.toSet() else emptySet(),
            if (active && radius > 0) forward.map { it.id }.toSet() else emptySet(),
        )
        if (!active) return@LaunchedEffect
        currentDrama?.let { preparation.detail(it) }
        nextDrama?.takeIf { it in upcoming && canWarm(it) }?.let { preparation.detail(it) }
        if (currentDrama == null || readyForPreload != currentDrama.id) return@LaunchedEffect
        for (drama in upcoming) {
            if (drama.id == nextDrama?.id || drama.id in retainedPlayers || !canWarm(drama)) continue
            awaitScrollIdle()
            val detail = preparation.detail(drama).await().getOrNull() ?: continue
            val episode = detail.episodes.getOrNull(feedResumeIndex(detail.episodes, repo.store.watch(drama))) ?: continue
            awaitScrollIdle()
            if (canWarm(drama)) preparation.warm(detail.drama, episode, homeQuality)
        }
    }
    val danmaku by repo.danmaku.collectAsState()
    val canDanmaku = "danmaku" in currentSource?.capabilities.orEmpty()
    val canChooseEpisodes = currentSource?.kind == "drama"
    val danmakuButton: @Composable () -> Unit = {
        IconButton(hapticClick { repo.danmaku.value = !danmaku }, Modifier.semantics { contentDescription = if (danmaku) "关闭弹幕" else "开启弹幕" }) {
            Text(if (danmaku) "弹" else "弹×", fontSize = 18.sp, color = if (full) Color.White else MaterialTheme.colorScheme.onSurface)
        }
    }
    val boostHint: @Composable () -> Unit = {
        Text("倍速播放中 · 松开恢复", Modifier.background(Color.Black.copy(alpha = .42f), RoundedCornerShape(20.dp)).padding(horizontal = 14.dp, vertical = 7.dp),
            color = Color.White, style = MaterialTheme.typography.labelLarge.copy(fontWeight = appTextWeight(FontWeight.SemiBold)))
    }
    androidx.activity.compose.BackHandler(active && (full || clean)) {
        if (clean) onClean(false) else setFullscreen(false)
    }
    BoxWithConstraints(Modifier.fillMaxSize().background(Color.Black)) {
    val feedWidth = if (!full && maxWidth > 560.dp) 520.dp else maxWidth
    val landscape = maxWidth > maxHeight
    Column(Modifier.fillMaxSize()) {
        if (!full) Box(Modifier.fillMaxWidth().height(56.dp).background(if (clean || boost || commentsProgress != null) Color.Black else MaterialTheme.colorScheme.surfaceContainerLow), contentAlignment = Alignment.Center) {
            if (boost) boostHint()
            else if (!clean && commentsProgress == null) {
                Row(Modifier.width(feedWidth).fillMaxHeight().padding(start = 16.dp, end = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("推荐", Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurface, fontSize = 17.sp, fontWeight = appTextWeight(FontWeight.Bold))
                    IconAction("refresh_rounded", "刷新推荐") { refresh++ }
                    IconAction("visibility_off_rounded", "清屏") { onClean(true) }
                    if (canDanmaku) danmakuButton()
                    IconAction("fullscreen_rounded", "全屏播放") { setFullscreen(true) }
                    if (canChooseEpisodes) IconAction("grid_view_rounded", controls?.let { "选集 · 第 ${it.episode} 集" } ?: "选集", controls != null) { controls?.episodes?.invoke() }
                }
                HorizontalDivider(Modifier.align(Alignment.BottomCenter), thickness = .5.dp, color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = .24f))
            }
        }
        Box(Modifier.weight(1f).fillMaxWidth().then(if (commentsProgress != null && !full) Modifier.graphicsLayer {
            translationY = -56.dp.toPx() * commentsProgress.value
        } else Modifier), contentAlignment = Alignment.Center) {
        if (rows.isEmpty()) {
            if (loading) LoadingRing(color = Color.White)
            else Column(Modifier.padding(horizontal = 16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                val needsPreferences = batches.isEmpty()
                val detail = if (needsPreferences) "请先在“设置 → 播放与信息流 → 站源管理”导入并开启订阅，再在“首页偏好”选择来源和分类。红果细分类只在已开启的真人剧、漫剧或AI剧中生效。" else error
                Glyph("live_tv_outlined", color = Color.White.copy(alpha = .7f), size = 44)
                Spacer(Modifier.height(12.dp))
                Text(if (needsPreferences) "先选择首页推荐内容" else if (error == null) "暂时没有可播放内容" else "推荐内容暂时不可用", color = Color.White)
                detail?.let {
                    Spacer(Modifier.height(8.dp))
                    Text(it, Modifier.width(280.dp), color = Color.White.copy(alpha = .7f), maxLines = 3,
                        overflow = TextOverflow.Ellipsis, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
                }
                Spacer(Modifier.height(16.dp))
                Button(hapticClick { if (needsPreferences) nav(Route("homePreferences")) else refresh++ }, contentPadding = PaddingValues(start = 16.dp, end = 24.dp)) {
                    Glyph(if (needsPreferences) "tune_rounded" else "refresh_rounded", size = 18)
                    Spacer(Modifier.width(8.dp))
                    Text(if (needsPreferences) "设置首页偏好" else "重新加载")
                }
            }
        }
        else VerticalPager(pager, modifier = Modifier.width(feedWidth).fillMaxHeight(), beyondViewportPageCount = radius,
            userScrollEnabled = commentsProgress == null, key = { rows.getOrNull(it)?.id ?: it },
        ) { index ->
            val drama = rows.getOrNull(index)
            if (drama != null) {
                var detail by remember(drama.id, generation) { mutableStateOf<Detail?>(null) }
                var failed by remember(drama.id, generation) { mutableStateOf(false) }
                val previewBitmap by rememberCoverBitmap(drama)
                val preview: @Composable (Modifier) -> Unit = { modifier ->
                    DramaCover(drama, modifier) { CoverImage(previewBitmap, it, poster = true) }
                }
                val pageActive = active && index == pageIndex
                val keepPlayer = pageActive || drama.id in playerIds
                LaunchedEffect(drama.id, generation, keepPlayer) {
                    if (!keepPlayer || detail != null || failed) return@LaunchedEffect
                    val result = preparation.detail(drama).await()
                    awaitScrollIdle()
                    detail = result.getOrNull()
                    failed = result.isFailure
                }
                LaunchedEffect(failed, detail, pageActive, commentsProgress) {
                    if (pageActive && commentsProgress == null && (failed || detail?.episodes?.isEmpty() == true)) {
                        awaitScrollIdle()
                        if (rows.getOrNull(pager.settledPage)?.id == drama.id) unavailable(drama)
                    }
                }
                Box(Modifier.fillMaxSize()) {
                    val ready = detail
                    when {
                        ready != null && ready.episodes.isNotEmpty() && keepPlayer -> PlayerPane(ready, initialIndex = feedResumeIndex(ready.episodes, repo.store.watch(drama)), active = pageActive, feed = true, modifier = Modifier.fillMaxSize(), externalFull = full && pageActive, externalClean = clean, onClean = onClean, feedPreview = preview,
                            commentsProgress = commentsProgress.takeIf { pageActive }, commentsVideoHeight = commentsVideoHeight,
                            takeFeedPlan = { target, episode, quality, canOpen ->
                                if (warmNext && index == afterCurrent && !canOpen()) {
                                    preparation.prepare(target, episode, quality) { !canOpen() }
                                }
                                preparation.take(target, episode, quality, canOpen)
                            },
                            warmFeed = warmNext && index == afterCurrent,
                            onMediaOpened = {
                                if (rows.getOrNull(pager.settledPage)?.id == drama.id) openedForPreload = drama.id
                            },
                            onVideoAspectRatio = { ratio ->
                                if (rows.getOrNull(pager.settledPage)?.id == drama.id) videoAspect = drama.id to ratio
                            },
                            onBoost = { boosting ->
                                if (boosting && rows.getOrNull(pager.settledPage)?.id == drama.id) boostingDramaId = drama.id
                                if (!boosting && boostingDramaId == drama.id) boostingDramaId = null
                            },
                            onControls = { value ->
                                if (value != null && rows.getOrNull(pager.settledPage)?.id == drama.id) pageControls = drama.id to value
                                else if (value == null && pageControls?.first == drama.id) pageControls = null
                            }, onFullScreen = ::setFullscreen,
                            onUnavailable = { failed = true },
                            onAvailable = {
                                if (rows.getOrNull(pager.settledPage)?.id == drama.id) {
                                    firstPlayback = true
                                    readyForPreload = drama.id
                                    consecutiveUnavailable = 0
                                    error = null
                                }
                            }, onComments = { if (pageActive && !pager.isScrollInProgress) onComments(drama) }, onCreator = { nav(Route("creator", drama)) }, onNext = {
                                scope.launch {
                                    val selected = pager.settledPage
                                    if (!pager.isScrollInProgress && rows.getOrNull(selected)?.id == drama.id && selected + 1 < rows.size) {
                                        pager.animateScrollToPage(selected + 1)
                                    }
                                }
                            })
                        else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                            preview(Modifier.matchParentSize())
                            if (pageActive && ready == null && !failed) LoadingRing(color = Color.White)
                        }
                    }
                    if (clean) FeedCleanExit { onClean(false) }
                }
            }
        }
        if (clean && rows.isEmpty()) FeedCleanExit { onClean(false) }
        if (full && boost) Box(Modifier.align(Alignment.TopCenter).windowInsetsPadding(WindowInsets.displayCutout.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(top = 8.dp)) { boostHint() }
        if (full && !clean && !boost && commentsProgress == null) {
            val position = Modifier.align(if (landscape) Alignment.TopStart else Alignment.TopEnd)
                .windowInsetsPadding(WindowInsets.displayCutout.only(WindowInsetsSides.Top + WindowInsetsSides.Horizontal)).padding(top = 8.dp, start = 8.dp, end = 12.dp)
            val cleanButton: @Composable () -> Unit = {
                IconButton(hapticClick { onClean(true) }) { Glyph("visibility_off_rounded", "清屏", color = Color.White) }
            }
            val exitButton: @Composable () -> Unit = {
                IconButton(hapticClick { setFullscreen(false) }) { Glyph("fullscreen_exit_rounded", "退出全屏", color = Color.White) }
            }
            if (landscape) Column(position) {
                cleanButton()
                if (canDanmaku) danmakuButton()
                Spacer(Modifier.height(4.dp))
                exitButton()
            } else Row(position) {
                cleanButton()
                if (canDanmaku) danmakuButton()
                Spacer(Modifier.width(4.dp))
                exitButton()
            }
        }
        }
    }
    }
}

@Composable
internal fun BoxScope.FeedCleanExit(onClick: () -> Unit) {
    Box(Modifier.matchParentSize().semantics { contentDescription = "退出清屏模式" }.hapticClickable(onClick = onClick))
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(history: Boolean, padding: PaddingValues = PaddingValues(), back: () -> Unit = {}) {
    val repo = LocalRepository.current; val nav = LocalNavigate.current; val action = rememberAction()
    var query by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf("all") }
    var status by rememberSaveable { mutableStateOf("") }
    var clear by remember { mutableStateOf(false) }
    var chosen by remember { mutableStateOf<Drama?>(null) }
    val installed by repo.subscriptions.installed.collectAsState()
    val sources = remember(installed) { installed.flatMap { it.sources }.associateBy { it.id } }
    val dramas = if (history) {
        val historyRows = repo.store.history()
        remember(historyRows) { historyRows.map { Drama(it.getJSONObject("drama")) } }
    } else repo.store.favorites()
    val creators = if (history) emptyList() else repo.store.list("followedCreators").objects().filter { repo.store.allowed(it.text("source")) }
    val kinds = if (history) emptySet() else dramas.map { sources[it.source]?.kind ?: "drama" }.toSet()
    val followStates = repo.store.text("followStates", "{}")
    val states = remember(followStates) { JSONObject(followStates) }
    val filtered = if (query.isBlank() && filter == "all") dramas else dramas.filter { matchesDramaQuery(it, query) && (filter == "all" || (sources[it.source]?.kind ?: "drama") == filter) && (filter != "drama" || status.isEmpty() || if (status == "updates") followUpdateLabel(states.optJSONObject(it.id)).isNotEmpty() else states.optJSONObject(it.id)?.text("status") == status) }
    val creatorRows = if (history || filter !in setOf("all", "creator")) emptyList() else creators.filter { row -> val text = normalizedSearchText(listOf("name", "creatorId", "creatorSecUid", "source").joinToString(" ") { row.text(it) }); query.trim().split(Regex("\\s+")).map(::normalizedSearchText).all(text::contains) }
    val creatorMap = creatorRows.associateBy { "creator:${it.text("id")}" }
    val display = filtered + creatorRows.map { row -> Drama(obj("id" to "creator:${row.text("id")}", "source" to row.text("source"), "title" to row.text("name"), "cover" to row.text("avatar"))) }
    val searchBar: @Composable () -> Unit = {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp), verticalAlignment = Alignment.CenterVertically) {
            OutlinedTextField(query, { query = it }, Modifier.weight(1f).padding(top = if (history) 0.dp else 8.dp, bottom = if (history) 12.dp else 8.dp), placeholder = { Text(if (history) "搜索观看记录" else "搜索收藏") }, singleLine = true, shape = RoundedCornerShape(16.dp), leadingIcon = { Glyph("search_rounded") }, trailingIcon = if (query.isEmpty()) null else { { IconAction("close_rounded", "清空搜索") { query = "" } } }, textStyle = MaterialTheme.typography.bodyLarge, colors = legacyTextFieldColors())
        }
    }
    val results: @Composable (Dp) -> Unit = { headerInset ->
        if (display.isEmpty()) StatusPanel(if (dramas.isEmpty() && creators.isEmpty()) { if (history) "还没有观看记录" else "还没有收藏" } else "没有匹配的记录", if (dramas.isEmpty() && creators.isEmpty()) "在发现页收藏作品，或关注感兴趣的创作者。" else "可以更换搜索词或筛选条件。", icon = if (history) "history_rounded" else "bookmark_border_rounded")
        else DramaGrid(display, creatorIds = creatorMap.keys, onOpen = { drama -> val creator = creatorMap[drama.id]; if (creator != null) nav(Route("creator", Drama(creator.getJSONObject("anchor")))) else nav(Route("playback", drama)) }, onAction = { drama -> val creator = creatorMap[drama.id]; if (creator != null) action { repo.store.followCreator(Drama(creator.getJSONObject("anchor"))) } else chosen = drama },
            badge = { drama -> states.optJSONObject(drama.id)?.let { state -> (if (state.optBoolean("manuallyWatched")) "已看 · 手动标记" else followLabels[state.text("status")].orEmpty()) + followUpdateLabel(state).takeIf { it.isNotEmpty() }?.let { " · $it" }.orEmpty() }.orEmpty() },
            subtitle = { drama ->
                val source = sources[drama.source]
                val watch = repo.store.watch(drama)
                val kind = source?.kind ?: "drama"
                when {
                    drama.id in creatorMap -> "${source?.name.orEmpty()} · 本地关注"
                    watch == null -> "${when (kind) { "video" -> "视频"; "live" -> "直播"; else -> "剧集" }} · ${source?.name.orEmpty()}"
                    kind == "drama" -> "第 ${watch.optInt("episode")} 集 · ${formatPosition(watch.optDouble("position"))}"
                    else -> "播放至 ${formatPosition(watch.optDouble("position"))}"
                }
            }, headerInset = headerInset)
    }
    if (history) {
        FrostedCatalog(frosted = true, overlap = display.isNotEmpty(), header = {
            TopAppBar(title = { Text("最近观看 · ${dramas.size}", Modifier.padding(start = 16.dp)) }, expandedHeight = 56.dp,
                navigationIcon = { IconAction("arrow_back_rounded", "返回", action = back) },
                actions = { if (dramas.isNotEmpty()) IconAction("delete_outline_rounded", "清空观看记录") { clear = true } },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent))
            searchBar()
        }, content = results)
    } else Column(Modifier.fillMaxSize().padding(padding)) {
        searchBar()
        LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            item { LegacyChip(filter == "all", { filter = "all" }, label = { Text("全部") }) }
            items(listOf("drama" to "剧集", "video" to "视频", "live" to "直播").filter { it.first in kinds }) { (id, label) -> LegacyChip(filter == id, { filter = id }, label = { Text(label) }) }
            if (creators.isNotEmpty()) item { LegacyChip(filter == "creator", { filter = "creator" }, label = { Text("作者") }) }
        }
        if (filter == "drama") LazyRow(contentPadding = PaddingValues(horizontal = 16.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            items(listOf("" to "全部状态", "planned" to "想看", "watching" to "在看", "watched" to "已看", "updates" to "有更新")) { (id, label) -> LegacyChip(status == id, { status = id }, label = { Text(label) }) }
        }
        results(0.dp)
    }
    if (clear) ConfirmDialog("清空观看记录？", "这会删除当前用户的观看进度；作品收藏、作者关注和手动已看标记会保留。", { clear = false }) { action { repo.store.clearHistory(); clear = false } }
    chosen?.let { drama -> DramaActionsDialog(drama, history) { chosen = null } }
}
