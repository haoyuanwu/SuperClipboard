# SuperClipboard

一个小巧的 macOS 剪贴板历史工具。通过菜单栏快速搜索和再次复制，在主页面查看原始内容、筛选类型与管理记录。

<img src="SuperClipboard/SuperClipboard/Assets.xcassets/AppLogo.imageset/AppLogo.png" width="128" alt="SuperClipboard">

## 下载与安装

在 [Releases](https://github.com/haoyuanwu/SuperClipboard/releases) 下载与你的 Mac 匹配的 DMG：

| 安装包 | 适用设备 |
| --- | --- |
| `SuperClipboard-1.1.0-arm64.dmg` | Apple Silicon，包括 M 系列芯片 |
| `SuperClipboard-1.1.0-x86_64.dmg` | Intel Mac |

系统要求：macOS 14 或更高版本。打开 DMG，将 SuperClipboard 拖入 Applications，再从“应用程序”启动。应用默认尝试注册开机启动，可以在设置中关闭；系统要求批准时，请前往“系统设置 → 通用 → 登录项”。

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
- 提供浅色、深色与跟随系统模式，支持开机启动设置。

详细操作及限制见 [功能介绍](SuperClipboard/docs/FEATURES.zh-CN.md)，版本变更见 [更新记录](CHANGELOG.md)。

## 构建

使用 Xcode 27 或更高版本打开 `SuperClipboard/SuperClipboard.xcodeproj`。项目使用 SwiftUI、AppKit、AVKit 和 ServiceManagement；SPM 会解析 MediaToolSwift 2.1.0。

```sh
python3 SuperClipboard/Scripts/package_release.py --version 1.1.0 --arch arm64
python3 SuperClipboard/Scripts/package_release.py --version 1.1.0 --arch x86_64
```

DMG 与 SHA-256 校验文件输出到 `SuperClipboard/dist/`。构建脚本默认使用临时签名，不包含 Apple 公证流程。

## 开源依赖

视频封面使用 [MediaToolSwift](https://github.com/starkdmi/MediaToolSwift) 2.1.0，许可证为 MPL-2.0。发布包内附第三方许可说明和许可证原文。
