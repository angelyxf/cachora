# Cachora 源码编译与样本验证

适用于 `0.1.0 / Build 18`。普通应用名为 Cachora；内部模块、工程与部分测试文件沿用 PureMac。当前公开源码，不公开安装包。

## 环境要求

| 项目 | 要求与验证范围 |
| --- | --- |
| 机器 | Apple Silicon Mac。当前脚本固定生成 `arm64`，不生成 Intel 或 Universal 应用。 |
| 系统 | 编译目标为 macOS 13。已在 macOS 27.0.1 本机完成构建和图形样本验证；GitHub Actions 在 `macos-15` 运行构建及样本检查，不能据此宣称所有系统的界面均已实测。 |
| Apple 开发工具 | 可用的 Swift 编译器与兼容 macOS SDK，可来自 Command Line Tools 或完整 Xcode。脚本使用 Swift 5 语言模式。 |
| Python | Python 3，脚本仅使用标准库，无需 `pip install`。 |
| 签名 | 本地构建使用临时签名，无需付费 Apple 开发者账号；这不包含 Developer ID 签名或公证。 |

Homebrew 不是编译或基本清理功能的依赖。XcodeGen 也不是下述脚本构建方式的依赖。

先检查工具：

```sh
python3 --version
git --version
xcrun --find swiftc
xcrun --show-sdk-path
```

如缺少 Apple 命令行工具，可运行 `xcode-select --install`，按系统提示安装后再检查。若已安装完整 Xcode，请先完成它的首次启动配置。Python 3 需能够通过上述命令调用。

## 构建普通应用

```sh
git clone https://github.com/angelyxf/cachora.git
cd cachora
python3 scripts/build-local-app.py
```

脚本依次运行扫描、恢复存储、完整源码清理恢复集成和发布规则检查，共 92 项；通过后编译应用、打包图标及本地化文件，最后执行临时签名和签名完整性检查。

成功时输出 `Built and signature-verified: .../build-local/Cachora.app`。这句话只代表本地签名完整性通过，不代表 Apple 公证。

```sh
open build-local/Cachora.app
```

普通应用会读取本机磁盘和应用状态，文件移动需要手动复核。脚本不会复制到 `/Applications`，也不会申请管理员清理权限。只想体验文件操作时，使用下一节的隔离样本应用。

## 只用测试文件体验

先完成上面的普通应用构建，再在同一仓库运行：

```sh
python3 scripts/create-demo-workspace.py --temporary
fixture_root="$(cat build-local/gui-workspace.txt)"
python3 scripts/build-local-app.py --package-only --fixture-root "$fixture_root"
open "$(dirname "$(dirname "$fixture_root")")/CachoraFixture.app"
```

样本生成器在 `/private/tmp/cachora-fixture-…/` 创建独立目录，包含虚构应用、缓存、重复文档、图片和备份；不会复制用户文件。构建命令会打印样本应用的完整路径。

窗口会显示“Cachora 测试版”和测试横幅，表示同一 Build 18 启用了隔离路径。样本清理、恢复和移入废纸篓都在该临时目录内进行；不会使用真实废纸篓。系统状态页仍会读取本机状态，因此对外截图只选样本文件页面。

可按以下步骤验证：

1. 在“用户缓存”扫描后清空选择，只选 `01-Round-trip`，确认路径属于刚生成的临时目录，再移入恢复区。
2. 打开左侧“清理恢复”，找到该记录并恢复，确认状态变为“已恢复”。恢复会拒绝覆盖已有同名文件。
3. 在“重复文件”扫描样本的 `home/Documents/Sample Files`。搜索 `Nested` 后点击“全选筛选结果”，只应选中一份副本；复核页面同时显示保留路径，可取消而不移动。
4. 在“应用卸载”选择 `Sample Editor` 查看关联文件。未确认前不会卸载；该样本只是生成的应用结构，不是真实编辑器。

样本目录中的 `baseline.json` 记录初始文件摘要、权限和扩展属性，`outside-home/preserve.txt` 是范围外保护样本。首页截图额外生成了两组中文文档用于展示搜索与批量选择；默认样本已足够验证同一流程。

测试完成后退出样本应用即可；普通入口仍是 `build-local/Cachora.app`。不要把临时样本目录或恢复副本提交到仓库。

## 单独运行检查

```sh
# 92 项 Swift 样本检查，不生成应用包
python3 scripts/build-local-app.py --tests-only

# 23 项打包与公证状态检查；Apple 响应使用模拟，不向 Apple 提交应用
python3 -m unittest discover -s scripts/tests -v

# 检查允许公开的源码文件范围与敏感内容
python3 scripts/prepare-beta.py --check
```

GitHub Actions 的 [Cachora checks](https://github.com/angelyxf/cachora/actions/workflows/build.yml) 运行普通应用构建及以上 Python、公开源码检查。通过不代表完整上游 XCTest、Intel 或每个系统版本都已验证，具体范围见 [验证与发行状态](RELEASE-STATUS.md)。

## 日志和常见问题

日志保存在 `build-local/`，失败时脚本会显示对应日志路径：

| 日志 | 内容 |
| --- | --- |
| `scan-regressions.log`、`recovery-store-tests.log` | 扫描与恢复样本结果 |
| `cleanup-recovery-integration.log`、`release-readiness.log` | 完整源码集成、更新、重复文件及边界检查 |
| `app-build.log` | 应用编译诊断 |
| `codesign.log`、`codesign-verify.log` | 本地临时签名与完整性检查 |

- **找不到 Swift 或 SDK**：先修复开发工具安装，重新执行环境检查；保留错误文本反馈，无需调整系统安全保护。
- **SwiftUI 宏插件或 SDK 不兼容**：脚本优先使用已安装的 CLT `MacOSX26.5.sdk`，否则使用 `xcrun --show-sdk-path`。本机的 CLT 27 SDK 曾缺少所需 SwiftUI 宏插件，已使用 26.5 SDK 验证。可选择本机已安装、与编译器兼容的 SDK，例如 `python3 scripts/build-local-app.py --sdk "$(xcrun --show-sdk-path)"`；这条命令使用当前默认 SDK，本身不会安装或修复 SDK。
- **`Sources changed or were not built`**：`--package-only` 要求二进制与当前源码及 SDK 匹配。先重新运行普通构建；换目录、改 Swift 源码或切换 SDK 后不要复用旧包。构建和后续打包必须使用相同的 `--sdk` 选择。
- **扫描报权限不足或文件变化**：这是运行时复核结果。先检查提示路径，等待文件停止变化后重新扫描；不要把这些项目当作已清理。

现有 `PureMac.xcodeproj` 和 `project.yml` 供工程开发参考；本页验证的是脚本构建路线，不把 Xcode IDE 全量测试或 Intel 构建标为已通过。

## 公开源码与安装包

`prepare-beta.py` 使用明确的文件清单，包含首页、编译说明与这次样本截图，不包含本机扫描报告、临时样本、恢复记录或安装包。`--source-archive` 只在本地导出源码压缩包，不自动上传。

当前不发布 DMG / ZIP。后续 Developer ID 签名、公证、装订与安装包评估是独立步骤，见 [构建与发布说明](BETA-RELEASE.md) 和 [macOS 安装包说明](MACOS-DISTRIBUTION.md)。
