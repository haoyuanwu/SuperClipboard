# 打包与 GitHub 发布

供人工操作、不同会话和不同 AI 共用。所有发布统一通过 `Scripts/publish_release.py` 完成。

## 环境

- macOS、Xcode 27+、Python 3、Git、GitHub CLI（gh）。
- GitHub 仓库由 origin 自动识别，当前为 haoyuanwu/SuperClipboard。
- 在 main 分支发布；工作区应只包含本次希望发布的源码及文档变更。
- 首次运行 `gh auth login`；若 gh 不在 PATH，可用 `~/.local/bin/gh auth login`。也支持 GH_TOKEN 环境变量。凭据由系统钥匙串或环境管理，不写入本项目。

## 发布命令

在仓库根目录：

```sh
python3 SuperClipboard/Scripts/publish_release.py --version 1.3.0
```

在包含 xcodeproj 的 SuperClipboard/ 目录：

```sh
python3 Scripts/publish_release.py --version 1.3.0
```

上面的版本号为示例；后续发布请递增版本号。在根目录 CHANGELOG.md 的“未发布”中先写好中文变更。脚本会用上海时区日期归档到新版本章节。

## 脚本自动处理

1. 检查认证、main 分支、origin、版本标签。
2. 更新营销版本与构建号、下载文件名和更新记录。
3. 构建 Debug，运行记事本、预览缓存、中转站/拖拽及窗口生命周期测试。
4. 构建 arm64 和 x86_64 Release，打包 DMG；检查架构、版本、临时签名和 DMG 校验。
5. 生成每个安装包的 SHA-256 和 manifest，缓存源文件与附件校验值。
6. 使用中文 Git 提交，推送 main 和版本标签。
7. 创建 GitHub Release 草稿，上传六个附件，核对远端大小后正式发布并设为 latest。

产物位于 SuperClipboard/dist/（从 Xcode 项目目录看是 dist/）。当前使用 ad-hoc 临时签名，尚未包含 Developer ID 签名与 Apple 公证；发布说明会明确标注。

## 只打包或失败重试

```sh
python3 Scripts/publish_release.py --version 1.3.0 --prepare-only
```

只更新版本、验证并打包，不提交或上传。正式发布时去掉 --prepare-only。

中断后运行同一个版本的同一命令。源文件和附件校验值一致时，脚本复用之前通过的结果，不再构建测试。源码有变化时自动重新验证打包。上传失败保留草稿，重试补齐附件。已正式发布的版本不覆盖，使用新版本号。

无需 AI 在脚本前后重复执行整套验证；以脚本退出状态和“发布完成”链接为准。只有失败时读取错误并修复，避免重复消耗时间。

## 常见问题

- 未登录/权限不足：用 gh auth login 登录有仓库 Contents 写入权限的账号或令牌；不要把令牌粘贴到聊天或文档。
- main 落后远端：先检查并合并远端改动，不要强制推送。
- 构建期间源文件变化：等待编辑结束，再运行原命令。
- 已有版本标签指向其他提交/版本已正式发布：递增版本号。
- 测试、签名或安装包校验失败：按脚本日志排查，不跳过验证继续上传。

## 应用名称

应用显示名为「口袋Cube」（原 SuperClipboard）；新安装包命名为 `PocketCube-版本-架构.dmg`，DMG 内为 `口袋Cube.app`。Xcode 工程和 Scheme 继续使用 SuperClipboard，发布仍使用上述统一脚本。Bundle ID 与 Application Support 目录保持原值，以保留历史、记事本与设置；已发布的旧版本附件不重命名。
