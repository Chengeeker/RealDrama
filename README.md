# RealDrama

RealDrama 是一个 Flutter 视频客户端，源码仓库为 [Chengeeker/RealDrama](https://github.com/Chengeeker/RealDrama)。客户端提供目录浏览、播放器、本地资料和订阅管理；内容源程序由独立项目维护，并通过订阅导入。

> 客户端不托管视频或媒体文件，也不预装已启用的内容源。内容和播放能力取决于用户导入的订阅及其上游服务。

## 项目概览

| 项目 | 当前配置 |
| --- | --- |
| 应用名称 | RealDrama |
| Android 包名 | `com.real.drama` |
| 应用图标 | 由 `assets/icon12-source.png` 统一生成应用内、Android、iOS、Windows 与电视横幅资源 |
| 当前源码版本 | `0.16.10+2173` 修正浏览器媒体请求兼容性，开发快照待设备验收 |
| 最新安装包 | `RealDrama-0.16.10+2173-arm64-v8a.apk` |
| Android ABI | `arm64-v8a` |
| 主要技术 | Flutter、Dart、Go 原生核心、MediaKit / libmpv |

APK 和其他构建产物不纳入源码仓库。需要安装包时，请按下方说明自行构建。

## 功能

### 首页与内容浏览

- 竖屏视频流，支持上下切换、播放控制、喜欢、收藏和不感兴趣。
- 当前队列保持稳定：返回上一部会恢复播放进度，后续队列不会因每次滑动而重新抽取。
- 首页偏好可按导入的内容源和题材筛选；关闭的分类会过滤命中该分类的内容。
- 推荐根据本地行为信号调整候选顺序，可调整题材权重或切换随机模式。行为保存在本机，不上传推荐服务。
- 支持设置首页画质；当内容源不提供所选档位时，播放器使用可用档位。
- 视频流可展示作者资料与内容文字，并提供适用的只读互动信息。
- “站源管理”集中管理订阅、已导入来源、首页偏好、首页画质和推荐设置。

### 发现与搜索

- 依据已导入的订阅浏览目录和分类；不同来源仅展示其声明支持的筛选与搜索能力。
- 分类按订阅定义展示，支持分层分类、排序和筛选。
- 下拉刷新只在当前已加载内容中换一批；站源更新通过单独入口触发。
- 支持内容详情、章节列表、收藏及下载入口；具体能力由订阅声明。

### 详情播放器

- 独立的常规播放器操作：选集、进度、倍速、画质与全屏切换。
- 可选的播放器叠加信息由订阅能力声明控制；实际支持情况取决于导入内容源。
- 支持长按临时 2 倍速、播放进度保存和集间切换。
- 播放设置支持硬件解码、平台解码器选择和低内存模式，作用于首页与详情播放。低内存模式把每个播放器的前向缓存降至 2 MiB、关闭后向缓存和额外预取，不保留首页前后播放器；滑回时可能重新加载。
- 视频画面按原始比例完整显示；首页清屏模式使用完整视口铺满。
- 实际播放能力取决于订阅返回的媒体地址、网络状况和内容授权状态。

### 资料管理与设置

- 底栏“收藏”按剧集、视频、作者与直播分组；只在有数据的类别显示入口。
- 剧集收藏保留想看/在看/已看和更新提醒；视频与直播按作品收藏，不显示剧集状态。
- 作者关注作为独立的本地关系保存，不会调用源站账号关注接口；观看进度与收藏分别保存。
- 最近观看、下载任务和本地用户资料保存在设备上；配置备份包含收藏、作者关注和观看记录。
- 可配置主题、Material You 动态取色、字体粗细、震动反馈和启动页面。
- 网络设置支持自动、直连和手动 HTTP(S) / SOCKS5 代理，并提供连接诊断。
- 支持本地配置导出/恢复与 WebDAV 手动备份；WebDAV 口令保存在设备安全存储中，代理地址等敏感本地设置不写入配置备份。

## 内容源订阅

此客户端版本是通用播放与订阅客户端，不随安装包预置或启用具体内容源。目录、分类、详情、媒体解析等源程序由独立的[订阅项目](https://github.com/Chengeeker/RealDrama-Subscription)维护；用户可在“站源管理 → 站源订阅”导入仓库或订阅包，并在“当前站源”中管理启用状态。

订阅可独立检查、更新或回退，不要求每次源程序调整都重新安装客户端。登录资料保存在设备本地安全存储，不放入公开订阅包。客户端提供通用请求、媒体播放与资源管理能力；实际内容、栏目和播放结果由已导入的订阅及其上游服务决定。

## 构建

### 环境

- Flutter `3.47.x`、Dart `3.12+`
- Go `1.24.1+`、Python `3.10+`
- Android：JDK 17、Android SDK 36、NDK `28.2.13676358`
- Windows：Visual Studio C++ 桌面组件与 MinGW-w64 x64
- iOS：macOS、Xcode 与 CocoaPods

### Android

```sh
python3 scripts/build_android.py --abi arm64-v8a
```

Android APK 输出到项目根目录。构建脚本会执行原生核心与 Flutter Release 构建，并校验安装包；交付目录仅保留最新 ARM64 包。安装包不包含用户导入的订阅。

### Windows 与 iOS

```powershell
.\scripts\build_windows.ps1
.\scripts\build_windows.ps1 -AllSources
```

```sh
python3 scripts/build_ios.py
python3 scripts/build_ios.py --all-sources
```

Windows 输出位于 `dist/windows`，iOS 输出位于 `dist/ios`。iOS 包尚未签名，不能直接安装。

### Android 本地调试

```sh
python3 scripts/build_native.py --platform android --abi arm64-v8a
flutter pub get --enforce-lockfile
flutter run
```

本地调试会构建通用原生核心并启动 Flutter 客户端。播放表现仍需在目标设备上结合已导入订阅验证。

## 检查

```sh
python3 -m unittest discover -s scripts -p 'test_*.py'
dart format --output=none --set-exit-if-changed lib test integration_test test_driver
dart analyze --fatal-infos lib test integration_test test_driver
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
```

Go 核心测试：

```sh
cd native
go test -race ./...
```

Android 播放集成测试还需要连接并授权调试设备；静态检查和成功构建不代表已完成真机验收。

## 平台状态

| 平台 | 状态 |
| --- | --- |
| Android 8.0+ | ARM64 构建配置已接入；尚未对所有设备完成安装与播放验收 |
| Windows 10/11 x64 | 构建脚本已接入，需在目标设备验证播放和局域网功能 |
| Android TV | 共用 Flutter 工程，遥控器焦点与布局待电视设备验收 |
| iOS 15.1+ | 工程和构建脚本已接入，待 Xcode 构建及真机验收 |

## GitHub Actions

推送 `main` / `master`、提交 Pull Request 或手动运行 **Build app packages** 会执行检查与构建。工作流的 Release 步骤限定在上游仓库；本仓库的推送不会自动创建发行版。

Android 正式签名需在仓库 Secrets 配置 `ANDROID_KEYSTORE_BASE64`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS` 和 `ANDROID_KEY_PASSWORD`。未配置时只能生成 debug 签名包。

## 目录结构

| 目录 | 内容 |
| --- | --- |
| `lib/` | Flutter 页面、播放器、设置、本地资料与 FFI 调用 |
| `native/core/`、`native/bridge/` | 通用媒体、网络、下载、订阅运行环境与原生桥接 |
| `android/`、`windows/`、`ios/` | 平台工程和应用资源 |
| `assets/` | 应用图标与界面资源 |
| `scripts/`、`.github/workflows/` | 构建、签名与维护工具 |
| `test/`、`integration_test/` | 单元、界面与设备集成测试 |

## 当前客户端版本

当前源码版本为 `0.16.10+2173`。修正浏览器媒体请求的 User-Agent、平台提示及站点关系标记，并使诊断记录实际来源。相关订阅需要更新客户端才能取得此修复；原生媒体契约、凭据隔离与播放恢复定向回归通过，真实设备播放仍待验收。一个已迁移订阅的旧预览测试依赖已停用的自动令牌流程，历史失败记录保留；不为该测试恢复内置站源逻辑。ARM64 APK 构建、签名和 16 KB ZIP 对齐检查通过；这不代表上游账号或设备实播已验收。

构建成功仅表示代码与安装包构建完成，不代表所有订阅、账号或目标设备均已验收。设备兼容性和播放结果仍需结合实际订阅进行验证。
