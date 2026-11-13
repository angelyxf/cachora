# 轻盘 macOS 安装包

当前为免费本机稳定版本 0.1.0（Build 18），保留清理复核与恢复流程。DMG 使用“拖入 Applications”的方式安装，同时准备 ZIP 作为应用更新包。当前仅打包已验证的 Apple Silicon / arm64 应用。

## 先完成本地安装验证

```sh
python3 scripts/sign-notarize.py --prepare
```

这会生成文件名带 `local-preview` 的 DMG 和 ZIP，保留在 `build-local/installer-preview/` 的独立目录。报告位置见 `build-local/installer-preview-latest.json`。

脚本实际校验 ZIP 解压、DMG 校验和、只读挂载、Applications 快捷入口、安装说明、复制后的应用内容/权限和代码签名。复制目标是本次独有的临时 Applications 目录，不修改系统的 `/Applications`，也不启动扫描或清理。

本地验证包使用临时签名，未获 Apple 公证，`distribution_ready` 始终为 `false`，不自动上传或作为正式下载。验证过程不绕过 Gatekeeper。

## 你需要完成的 Apple 设置

1. 没有开发者账号时，先在 [Apple Developer Program](https://developer.apple.com/programs/enroll/) 注册并加入。官方年费为 99 美元，支持当地货币时以 Apple 页面为准。登录、身份验证、协议和付款由账号持有人本人操作。[官方报名说明](https://developer.apple.com/help/account/membership/program-enrollment)
2. 成为有效会员后，在这台 Mac 的“钥匙串访问 → 证书助理 → 从证书颁发机构请求证书”中生成 CSR，保存到本机。私钥留在钥匙串。
3. 到 [Certificates](https://developer.apple.com/account/resources/certificates/list) 创建 **Developer ID Application** 证书，上传 CSR、下载 `.cer` 并双击安装。证书必须有对应私钥。创建此证书通常需要 Account Holder 权限。DMG 路线不需要额外的 Developer ID Installer 证书。[官方证书说明](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
4. 为公证创建 App 专用密码，并在你自己的终端保存到本机钥匙串。Team ID 可在 Apple 开发者账号的会员信息中找到。

```sh
xcrun notarytool store-credentials Cachora-notary \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID"
```

命令会交互式请求 App 专用密码；不要把密码写进命令、源码、GitHub 或聊天。也不需要导出证书私钥或把 `.p12`、`.p8` 交给本项目。配置名 `Cachora-notary` 本身不是密码。[Apple 钥匙串配置说明](https://developer.apple.com/documentation/technotes/tn3147-migrating-to-the-latest-notarization-tool)

完成后只需告知“证书和公证配置已就绪”；多张有效证书时，再明确选择本产品使用的身份。

## 发行签名与公证

```sh
python3 scripts/sign-notarize.py --preflight
python3 scripts/sign-notarize.py --run --notary-profile Cachora-notary
```

只有一张有效 Developer ID Application 证书时自动选择；多张时使用 `--identity` 提供完整证书名称或指纹。脚本只引用已有钥匙串身份，不导出密码和私钥，不使用上游作者身份。

处理顺序：验证应用版本、正常包标识和构建摘要；创建独立发行副本；开启 hardened runtime、使用安全时间戳签名；提交应用公证；装订应用票据；生成并签名 DMG；提交并装订 DMG；最后验证 Gatekeeper、ZIP 解压和 DMG 安装复制。应用和外层 DMG 分别完成公证和装订，便于离线验证。

Apple 尚在处理时退出码为 `3`，打印待恢复目录。沿用同一个目录继续：

```sh
python3 scripts/sign-notarize.py --resume "build-local/release/VERSION-buildN/attempt-ID"
```

提交 ID 与文件摘要保存在本地 `state.json`。恢复时不重复上传已经提交的文件，文件变动则停止。提交结果不明确且没有收到 ID 时会停止自动重传，需要先通过 `notarytool history` 核查。Apple 拒绝时保留结果并下载错误日志；不会生成公开安装包。

只有应用与 DMG 的公证、票据、Gatekeeper 和安装检查全部通过，才会创建该次任务下的 `dist/`，其中包含 DMG、ZIP、`SHA256SUMS.txt` 和 `verification.json`。生成 `dist/` 不等于已发布到 GitHub；发布应核对相应提交和校验码后进行。

## 已执行与未执行

每次本地打包会保留独立的验证记录及 SHA256SUMS.txt。当前构建的实际检查结果见 [验证与发行状态](RELEASE-STATUS.md)。真实发行验证尚待自己的 Developer ID Application 证书和公证配置。

签名及公证状态控制采用模拟 Apple 响应的回归检查，覆盖待处理、恢复、拒绝、文件变动、身份选择、Gatekeeper 失败和最终输出门槛。模拟检查不等于 Apple 实际公证；真实 Apple 发行签名、公证与 Gatekeeper 接受仍待账号和证书就绪后完成。
