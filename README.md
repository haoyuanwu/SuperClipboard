# 口袋Cube

原名 SuperClipboard。应用现已更名为「口袋Cube」，安装包前缀为 `PocketCube`，已有历史与设置继续保留。

一个小巧的 macOS 剪贴板历史工具。通过菜单栏快速搜索和再次复制，在主页面查看原始内容、筛选类型与管理记录。

<img src="SuperClipboard/SuperClipboard/Assets.xcassets/AppLogo.imageset/AppLogo.png" width="128" alt="口袋Cube">

## 下载与安装

在 [Releases](https://github.com/haoyuanwu/SuperClipboard/releases) 下载与你的 Mac 匹配的 DMG：

| 安装包 | 适用设备 |
| --- | --- |
| `PocketCube-1.3.3-arm64.dmg` | Apple Silicon，包括 M 系列芯片 |
| `PocketCube-1.3.3-x86_64.dmg` | Intel Mac |

系统要求：macOS 14 或更高版本。打开 DMG，将应用拖入 Applications，再从“应用程序”启动。应用默认尝试注册开机启动，可以在设置中关闭；系统要求批准时，请前往“系统设置 → 通用 → 登录项”。

当前发布包使用临时签名，尚未进行 Developer ID 签名和 Apple 公证。macOS 可能阻止首次打开。确认安装包来自本仓库后，可以在“系统设置 → 隐私与安全性”中按系统提示允许打开。不要关闭系统整体安全保护。

## 功能

- 自动记录文字、图片、文件与视频文件；历史保存在本机。
- 文字保留复制时提供的字体、颜色、段落和背景样式。
- 菜单栏弹窗直接展示卡片；支持搜索、单击再次复制与右键菜单。
- 重复内容合并计数，支持按最近复制或复制次数排序；主页面与弹窗共用排序。
- 弹窗打开期间再次复制不会打乱位置，下次打开时再重新排序。
- 图片显示预览和名称，视频文件生成封面，详情中支持播放和拖动进度。
- 文件详情显示完整路径，点击可在访达中定位。
- 支持文字、图片、文件、视频筛选，置顶、删除与清空未置顶记录。
- 记事本独立保存文字、富文本、图片、文件和视频，删除源文件或清空历史后仍可读取。
- 主页面与弹窗均提供记事本图标入口，设置支持更改保存目录并迁移。
- 悬浮中转站始终置顶，支持拖入/拖出文字、图片、文件和视频；关闭后按设置时间自动清空。
- 中转内容默认不写入历史，可在设置开启；自身拖回与重复内容不会重复添加。
- 状态栏弹窗采用液态玻璃界面，提供中转入口和带玻璃确认浮层的退出按钮。
- 提供浅色、深色与跟随系统模式，支持开机启动设置。

详细操作及限制见 [功能介绍](SuperClipboard/docs/FEATURES.zh-CN.md)，版本变更见 [更新记录](CHANGELOG.md)。

## 构建

跨会话和 AI 协作约定见 [AGENTS.md](AGENTS.md)，完整发布与重试方法见 [发布指南](SuperClipboard/docs/RELEASING.zh-CN.md)。

使用 Xcode 27 或更高版本打开 `SuperClipboard/SuperClipboard.xcodeproj`。项目使用 SwiftUI、AppKit、AVKit 和 ServiceManagement；SPM 会解析 MediaToolSwift 2.1.0。

```sh
# 首次配置 GitHub 登录
~/.local/bin/gh auth login

# 更新版本、运行验证、构建双架构 DMG、中文提交、推送并发布
python3 SuperClipboard/Scripts/publish_release.py --version 1.2.0
```

之后每次发布都运行 `publish_release.py --version 新版本号`。脚本自动递增构建号、整理“未发布”更新记录、执行记事本/预览/中转站测试，生成 Apple Silicon 与 Intel 安装包、SHA-256 和构建清单；上传到草稿后确认附件齐全再正式发布。提交记录使用中文，本地 Xcode 窗口状态不参与提交。

DMG 输出到 `SuperClipboard/dist/`。脚本根据源文件和安装包校验值缓存成功结果；同一版本重试上传时自动复用，不重复构建和测试。源文件有变化则重新验证和打包。只打包暂不上传可加 `--prepare-only`。运行中断后重新执行同一命令即可继续；已正式发布的版本不可覆盖。构建使用临时签名，不包含 Apple 公证流程。

## 开源依赖

视频封面使用 [MediaToolSwift](https://github.com/starkdmi/MediaToolSwift) 2.1.0，许可证为 MPL-2.0。发布包内附第三方许可说明和许可证原文。
