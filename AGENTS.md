# SuperClipboard 项目协作约定

本文件适用于仓库全部目录。任何 AI 或新会话开始工作时都应先阅读本文件。

## 项目结构与产品约定

- 仓库根目录包含 README.md、CHANGELOG.md；Xcode 项目和源码位于 SuperClipboard/。
- 原生 macOS SwiftUI/AppKit 应用，最低 macOS 14；液态玻璃在 macOS 26 及以上启用，旧系统保留降级与无障碍支持。
- 主窗口、状态栏弹窗、中转站是三个独立使用场景。不要添加用于在三个场景间切换的分段控制器。
- 保持紧凑窗口、原生字体、液态玻璃风格；优先打磨使用频率最高的状态栏弹窗。
- 拖拽使用简洁的系统预览，不恢复复杂 Hero 叠层动画；中转站自身内容拖回不重复导入。
- 主页面单击查看详情；状态栏单击复制；向外拖拽不增加复制次数或改变排序。

## Git 与发布（用户明确约定）

- Git 提交信息使用中文。
- 每次打包上传都使用 `SuperClipboard/Scripts/publish_release.py`。不要临时拼装上传命令或另起一套发布流程。
- 脚本已有必要验证和缓存。正常发布直接运行脚本，不额外重复人工执行整套构建/测试/安装包校验；只有脚本报错或存在具体未解决风险时才针对性排查。
- 用户要求发布时才上传 GitHub；普通功能修改不自动发布。
- 发布方法、认证、重试说明见 `SuperClipboard/docs/RELEASING.zh-CN.md`。

### 从仓库根目录发布

```sh
python3 SuperClipboard/Scripts/publish_release.py --version 新版本号
```

### 从 Xcode 项目目录发布

```sh
python3 Scripts/publish_release.py --version 新版本号
```

- 新版本号应高于已发布版本；正式发布版本不可覆盖。
- 脚本自动更新版本号/构建号/下载文件名、整理更新记录、测试、双架构打包、中文提交、推送 main 和版本标签、上传草稿、确认附件后正式发布。
- 使用 GitHub CLI 登录/系统钥匙串或 GH_TOKEN。禁止把凭据写进代码、项目文档、Git 提交或日志。
- 不提交 xcuserdata、窗口状态、dist 安装包或其他本机生成文件。
