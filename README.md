# RealDrama

An Android video app built with Jetpack Compose, a Go core, and libmpv.

- Content browsing, search, episodes, and full-screen playback.
- Downloads, favorites, viewing history, and WebDAV backup.
- Themes, dynamic colors, and font controls.
- Independently updatable content subscriptions.

Version 2.3.25 (4288) · Android 8.0+ · ARM64 · Android TV support

Version 2.3.25 accompanies a separately updated content subscription.

Version 2.3.23 aligns the landscape episode sidebar header and group selector in single rows, removes the close button, and avoids applying the screen's left safe inset inside the right-side panel.

Version 2.3.22 matches the landscape playback sidebar to the reference proportion and detail-page episode-cell sizing; all landscape playback menus share the responsive panel.

Version 2.3.21 makes landscape episode-picker positioning wait for the grid layout before scrolling to the current episode.

Version 2.3.20 removes repeated headings from playback menus and aligns episode actions with the panel title.

Version 2.3.19 removes the repeated episode count from the landscape picker while keeping its group, locate, and jump controls.

Version 2.3.18 extends landscape playback side drawers to the screen edge while keeping menu content clear of system bars and cutouts.

Version 2.3.17 keeps landscape playback side drawers full-height at two-thirds of their previous width, with adaptive menu content.

Version 2.3.16 matches playback episode cells to the compact detail-page sizing and uses edge-attached side drawers for landscape playback menus. Portrait sheets and TV dialogs retain their layouts.

Version 2.3.15 aligns the fullscreen portrait episode and playback controls with the lock control. Holding for speed boost keeps vertical swipes from changing brightness or volume until the finger is released.

The 2.3.12 development snapshot matches the source-switch overlay background to the Discover toolbar and removes the Douyin-specific three-consecutive-failures stop. Douyin source package 0.2.11 is updated separately in RealDrama-Subscription with AVC-first media selection, short-lived URL refresh, expired-link filtering and deduplicated fallback URLs. Search/history remains on a dedicated page and the pull-to-refresh indicator follows the actual request. The player waits for a video frame before reporting first playback; on-demand refresh is still supported. Source package import or publication and live playback verification are required; they are not guaranteed by the APK build.

Version 2.3.13 fixes legacy secure-storage initialization during source enablement and maintenance. Android boolean cipher-migration settings are now applied correctly, absent legacy keys do not start cipher migration, and unreadable old credentials are preserved rather than reset. Affected users are directed to re-enter the Douyin Cookie if the removed legacy cipher cannot decrypt it. Subscriptions, app data and old encrypted preferences are not cleared automatically. This fixes the local credential error path; actual Douyin network and playback availability remain separate checks.

Version 2.3.14 makes the Cookie entry visible in "启用与维护": an expanded "账号与 Cookie 管理" section lists all installed source groups that declare credential domains, showing a direct "填写 / 更新" action and whether a Cookie is saved. Enabled source cards also have a Cookie action. Sources without declared credential permissions remain isolated from account credentials.

Content sources are imported separately. Available features and playback depend on the imported subscriptions and their services.

[Subscription guide](https://github.com/Chengeeker/RealDrama-Subscription#usage) · [Build script](tools/build_release.py)


## 2026-11-27 播放器锁速与提示位置（正式发布 2.3.25）

- 长按期间垂直拖动锁定为倍速操作：向下至少 48dp，提示「松开锁定倍速」，松手后保持倍速；再次长按向上至少 48dp，提示「松开恢复原速」，松手后恢复用户选择速度。释放手指前不会调节亮度/音量。
- 速度、亮度、音量和拖动定位提示按画面顶部黑边空间放置，统一为紧凑胶囊；黑边至少 144dp 时居中显示在黑边安全区，否则放在视频视口上方四分之一处。提示最多 900ms，提前松手立即消失。
- `:app:assembleRelease` 成功，当前源码版本 `2.3.25+4288` ARM64 APK 12,849,761 字节，SHA-256 `8700e85545c2f8fa56c91fadc50f14e919154a4fbcd134eddd331296f9fb5f3f`。按项目约定本轮没有运行测试；没有连接设备，真实播放器手势仍未验收。

## 2026-11-27 长按锁速实现复核

- `detectPlaybackTaps` 将长按、移动回调和抬手恢复放在同一输入循环，并在加速期间消费手势；亮度/音量回调仅在未加速时执行。播放器手势与信息流倍速提示已同步到 2.3.25 正式版；静态核验不等于设备手势验收。
