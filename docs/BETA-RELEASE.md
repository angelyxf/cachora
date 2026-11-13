# Cachora 构建与发布说明

产品名称：轻盘 · Cachora。本机稳定版本 `0.1.0`（Build 18），包标识 `io.github.angelyxf.cachora`。源码内部仍沿用 PureMac 的模块和目录名称；保留其 MIT 许可和作者信息。

## 本次开放范围

定时扫描默认关闭，可由用户手动启用；只在应用运行时检查文件，不自动清理。清理前查看路径，再将选中的可恢复项目移入恢复区。恢复遇到同名冲突时保留双方，永久删除恢复副本需要再次确认。恢复副本仍占磁盘空间。

卸载、疑似应用残留和文件比对工具使用系统废纸篓。移动失败会保留原文件，不重试管理员永久删除。定时扫描在轻盘运行时执行，文件移动需要用户复核。访达的轻盘服务进入卸载复核流程。

## 构建与样本验证

首次克隆、工具要求、隔离样本演示及常见错误，见 [源码编译与样本验证](BUILDING.md)。以下命令在仓库根目录运行。

```sh
python3 scripts/build-local-app.py
```

日常使用请打开 `build-local/Cachora.app`。开发验证可另外生成专用的样本应用。

```sh
python3 scripts/create-demo-workspace.py --temporary
python3 scripts/build-local-app.py --package-only --fixture-root "$(cat build-local/gui-workspace.txt)"
```

样本应用的构建命令会打印临时路径。样本应用的目录标记、路径边界和无效配置停用均有检查。

普通应用的恢复数据保存在 `~/Library/Application Support/Cachora/Recovery`。样本应用使用其临时目录中的独立恢复区。

## 发布准备

```sh
python3 scripts/prepare-beta.py --check
python3 scripts/prepare-beta.py --source-archive
python3 scripts/sign-notarize.py --preflight
python3 scripts/sign-notarize.py --prepare
```

公开源码包使用明确的文件范围，不含本机扫描报告、测试工作区、构建目录和本机验证日志。安装包只有完成自己的 Developer ID 签名、公证、装订和评估后才能标记为可向普通用户分发。临时签名不等于发行签名或公证。

`--prepare` 会生成并实际检查本地 DMG/ZIP 验证包，不修改实际 Applications，未公证时不能作为正式下载。账号申请、证书安装、交互式公证凭据配置和恢复流程见 [macOS 安装包说明](MACOS-DISTRIBUTION.md)。

已有自己的证书和钥匙串公证配置后运行：

```sh
python3 scripts/sign-notarize.py --run \
  --identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --notary-profile YOUR_STORED_PROFILE
```

脚本通过已有钥匙串配置调用 Apple 服务，不把密钥、密码或证书内容写入仓库。缺少条件会停止并报告，不发布未公证安装包。本机稳定包不等于通过 Apple 公证的公开下载包；安装包的分发状态要以构建记录为准。这些脚本不会自动发布源码或安装包。Build 18 源码已同步至 GitHub `main`；安装包仍只保留本地。

## 后续公开测试

首批建议 10–20 人，记录安装结果、系统和芯片版本、扫描遗漏、冲突提示、恢复结果。反馈前自行遮盖私人路径和内容。先处理阻止安全试用的问题，再验证新增高级功能的付费意愿。

当前免费，无付款入口。自定义规则、空间报告、团队管理等属于后续候选功能，尚未实现或承诺。本次本地验证结果见 `build-local/build18-stable-validation.json`。已验证范围见 [发布状态](RELEASE-STATUS.md)。
