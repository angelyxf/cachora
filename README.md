# Cachora · 轻盘

<img src="PureMac/Assets.xcassets/BetaIcon.appiconset/beta_128@2x.png" width="96" alt="Cachora recovery tray icon">

A native Mac cache cleaner with a way back.

先看清，再清理。轻盘把选中的缓存移入本地恢复区，需要时可以放回原处。

**免费源码内测 · 0.1.0-beta.1 · MIT**

本项目基于 [PureMac](https://github.com/momenbasel/PureMac) 独立开发，保留原 MIT 许可与作者信息。当前是源码内测，尚无经过我们自己 Apple Developer ID 签名、公证的公开安装包。

## 这个版本能做什么

- 手动扫描应用缓存、Node 包管理器缓存及 Homebrew 下载缓存。
- 显示实际路径、隐藏文件占用，以及无法读取的位置；读失败不当作零占用。
- 复核选择后移入恢复区，记录原位置和操作状态。
- 恢复时拒绝覆盖同名文件，保留双方并允许处理冲突后重试。
- 永久删除恢复副本前再次确认。

恢复副本仍占磁盘空间。移入恢复区不等于已经释放空间；恢复区也不是独立备份。永久删除无法撤销。

内测版不提供系统优化、应用卸载、文档清理、模型或对话历史清理、废纸篓清空及自动清理。仓库中的历史工具不代表当前产品支持范围。

## 先用测试文件体验

在仓库根目录执行：

```sh
python3 scripts/build-local-app.py
python3 scripts/create-demo-workspace.py
python3 scripts/build-local-app.py --package-only --fixture-root "$(cat build-local/gui-workspace.txt)"
```

- `build-local/CachoraFixture.app`：只操作刚生成的测试文件，配置无效时停用，不回退到真实主目录。
- `build-local/Cachora.app`：正常主目录版本。只有手动扫描、复核并确认后才移动文件；首次评估请先使用测试版。

本地构建是临时签名开发包，不能标为 Apple 已公证。脚本目前生成 Apple Silicon 版本；编译目标是 macOS 13，其他系统和芯片的支持以实际验证为准。

## 开发与验证

```sh
python3 scripts/build-local-app.py --tests-only
python3 scripts/prepare-beta.py --check
python3 scripts/sign-notarize.py --preflight
```

完整 Xcode 环境也可使用 `project.yml` 或现有 `PureMac.xcodeproj`。模块名与历史目录仍保留 PureMac，以方便审查来源和合并上游。

本轮验证结果与尚未完成的发行条件见 [发布状态](docs/RELEASE-STATUS.md)。详细流程见 [内测发布说明](docs/BETA-RELEASE.md)。不要求关闭 Gatekeeper 或扩大系统权限来体验源码。

## 隐私和反馈

没有账号、广告、分析 SDK、付款或自动上传。扫描结果、日志与恢复记录留在本机。只有主动检查更新时会访问本项目的 GitHub Releases API。[隐私说明](PRIVACY.md)

遇到问题请到 [Issues](https://github.com/angelyxf/cachora/issues) 提交系统版本、芯片类型和使用测试样本复现的步骤。截图和日志请先遮盖私人路径，不上传实际文档、密钥或恢复副本。

## 后续方向

先验证基础流程的安全性和易用性。自定义规则、空间变化报告和更便捷的批量管理属于后续候选，尚未实现；当前没有收费入口，也没有订阅或终身更新承诺。

## 来源与许可

固定源码基线：PureMac `b86aa61948f78ae9f17b42b624b20357a3ca9ffe`。保留 [MIT 许可](LICENSE)，新增独立图标和界面说明；详见 [第三方说明](THIRD-PARTY-NOTICES.md)。本项目不代表原作者或 Apple。

## English

Cachora is an independent, MIT-licensed PureMac derivative focused on recoverable cache cleanup. The free source beta exposes application, Node and Homebrew caches only. Review before moving files into local Recovery; restore never overwrites an existing destination. Retained copies still consume disk space, and permanent deletion is irreversible.

Use the generated fixture app first. Consumer signing/notarization, OS coverage and full upstream XCTest results are reported explicitly in the release status; source availability is not a safety guarantee. No paid features or consumer download are promised in this beta.
