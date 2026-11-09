package com.real.drama.compose

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shadow
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VideoAuthorPanel(drama: Drama, open: () -> Unit, modifier: Modifier = Modifier, glass: Boolean = false) {
    val repo = LocalRepository.current
    val followed = creatorFollowed(repo.store, drama)
    val action = rememberAction()
    val source = repo.source(drama.source)
    val name = drama.creator.ifEmpty { "查看作者" }
    val avatar = drama.json.text("creatorAvatar")
    val authorLink = Modifier.semantics { contentDescription = "查看${name}的个人主页" }.hapticClickable(onClick = open)
    val shadow = Shadow(Color.Black, blurRadius = 6f)
    var truncated by remember(drama.title) { mutableStateOf(false) }
    var more by remember(drama.title) { mutableStateOf(false) }
    Column(modifier) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(44.dp).clip(CircleShape).background(Color.White.copy(alpha = .24f)).then(authorLink),
                contentAlignment = Alignment.Center) {
                if (avatar.isEmpty()) Glyph("person_rounded", color = Color.White)
                else CompositionLocalProvider(LocalContentColor provides Color.White) { Cover(Drama(drama.json.copy().put("cover", avatar)), Modifier.matchParentSize(), avatar = true) }
            }
            Spacer(Modifier.width(10.dp))
            Column(Modifier.weight(1f, fill = false).then(authorLink)) {
                Text(name, color = Color.White, fontSize = 16.sp, fontWeight = appTextWeight(FontWeight.Bold), maxLines = 1,
                    overflow = TextOverflow.Ellipsis, style = LocalTextStyle.current.copy(shadow = shadow))
                val publicId = drama.json.text("creatorId")
                if (publicId.isNotEmpty()) Text(
                    "${if (source?.group == "bilibili") "UID" else "抖音号"}：$publicId",
                    color = Color.White.copy(alpha = .7f), fontSize = 12.sp, maxLines = 1, overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.width(8.dp))
            FilledTonalButton(
                hapticClick { action { repo.store.followCreator(drama) } },
                enabled = drama.creatorId.isNotEmpty() && "creator" in source?.capabilities.orEmpty(),
                modifier = Modifier.heightIn(min = 34.dp).then(if (glass) Modifier.playerGlass(CircleShape) else Modifier),
                contentPadding = PaddingValues(horizontal = 12.dp),
                colors = if (glass) ButtonDefaults.filledTonalButtonColors(
                    containerColor = Color.Transparent, contentColor = Color.White,
                    disabledContainerColor = Color.Transparent, disabledContentColor = Color.White.copy(alpha = .38f),
                ) else ButtonDefaults.filledTonalButtonColors(),
            ) { Text(if (followed) "已关注" else "关注") }
        }
        Spacer(Modifier.height(8.dp))
        Text(
            drama.title, Modifier.semantics { contentDescription = "进入短视频详情" }.hapticClickable(onClick = open),
            color = Color.White, fontSize = 14.sp, lineHeight = 19.6.sp, maxLines = 2, overflow = TextOverflow.Ellipsis,
            style = LocalTextStyle.current.copy(shadow = shadow), onTextLayout = { truncated = it.hasVisualOverflow },
        )
        if (truncated) Text("更多", Modifier.semantics { contentDescription = "显示完整文字内容" }.hapticClickable { more = true }.padding(vertical = 6.dp),
            color = Color.White.copy(alpha = .7f), fontSize = 13.sp)
    }
    if (more) {
        val height = LocalConfiguration.current.screenHeightDp.dp * .65f
        ModalBottomSheet(scrimColor = androidx.compose.ui.graphics.Color.Black.copy(alpha = .54f), onDismissRequest = { more = false }, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
            SelectionContainer {
                Text(drama.title, Modifier.fillMaxWidth().heightIn(max = height).verticalScroll(rememberScrollState())
                    .padding(start = 24.dp, top = 4.dp, end = 24.dp, bottom = 24.dp),
                    style = MaterialTheme.typography.bodyLarge)
            }
        }
    }
}
