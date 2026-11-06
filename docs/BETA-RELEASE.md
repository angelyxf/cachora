# Cachora 免费内测发布

产品名称：轻盘 · Cachora。内测版本 `0.1.0-beta.1`，包标识 `io.github.angelyxf.cachora`。源码内部仍沿用 PureMac 的模块和目录名称；保留其 MIT 许可和作者信息。

## 本次开放范围

应用缓存、Node 包管理器缓存、Homebrew 下载缓存，以及恢复记录。所有扫描由用户手动启动，清理前查看路径，再将选中项目移入恢复区。恢复遇到同名冲突时保留双方，永久删除需要再次确认。恢复副本仍占磁盘空间。

内测界面不开放卸载、系统优化、模型/对话历史清理、文档清理、废纸篓清空、自动清理和上游 CLI。其他历史源码保留，但不作为此内测版的功能承诺。

## 构建和试用

```sh
python3 scripts/build-local-app.py
python3 scripts/create-demo-workspace.py
python3 scripts/build-local-app.py --package-only --fixture-root "$(cat build-local/gui-workspace.txt)"
```

主应用在 `build-local/Cachora.app`；只操作生成样本的版本在 `build-local/CachoraFixture.app`。首次试用优先使用测试版。测试版的目录标记、路径边界和无效配置停用均有检查。

恢复数据保存在 `~/Library/Application Support/Cachora/Recovery`。本次不会迁移或删除以前 PureMacLocal 的恢复数据。

## 发布准备

```sh
python3 scripts/prepare-beta.py --check
python3 scripts/prepare-beta.py --source-archive
python3 scripts/sign-notarize.py --preflight
```

公开源码包使用明确的文件范围，不含本机扫描报告、测试工作区、构建目录和本机验证日志。安装包只有完成自己的 Developer ID 签名、公证、装订和评估后才能标记为可向普通用户分发。临时签名不等于发行签名或公证。

已有自己的证书和钥匙串公证配置后运行：

```sh
python3 scripts/sign-notarize.py --run \
  --identity "Developer ID Application: YOUR NAME (TEAMID)" \
  --notary-profile YOUR_STORED_PROFILE
```

脚本通过已有钥匙串配置调用 Apple 服务，不把密钥、密码或证书内容写入仓库。缺少条件会停止并报告，不发布未公证安装包。源码可先用于开发者内测；安装包的分发状态要以构建记录为准。

## 内测反馈

首批建议 10–20 人，记录安装结果、系统和芯片版本、扫描遗漏、冲突提示、恢复结果。反馈前自行遮盖私人路径和内容。先处理阻止安全试用的问题，再验证新增高级功能的付费意愿。

当前免费，无付款入口。自定义规则、空间报告、团队管理等属于后续候选功能，尚未实现或承诺。完整上游 XCTest、跨卷移动和未实测系统不能写成已通过；最新实际结果见 `build-local/beta-validation.json`，该文件保留在本地。
