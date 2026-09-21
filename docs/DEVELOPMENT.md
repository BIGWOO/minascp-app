# 開發與驗證

[← 返回首頁](../README.md)

## 本機建置

需要 macOS 14+ 與 Xcode Command Line Tools。使用 SwiftUI、AppKit 與系統 OpenSSH，無第三方 Swift 套件。

```sh
./scripts/build-app.sh
open build/debug/MinaSCP.app
swift test
```

## 整合測試

```sh
MINASCP_DOCKER=1 MINASCP_DOCKER_TEST=1 swift test
MINASCP_DOCKER_TEST=1 MINASCP_STRESS_TEST=1 swift test
```

Docker 測試只使用 loopback：SFTP-only `127.0.0.1:22222` 與 SSH 命令 `127.0.0.1:22224`。壓力測試傳送 1 GiB 與 1,000 個小檔；一般測試使用 macOS 本機 `sftp-server` 子程序。

- [SFTP 測試環境](../test-environment/sftp/README.md)
- [SSH 命令測試環境](../test-environment/commands/README.md)
- [1.0.0 發佈驗證](RELEASE-1.0.0.md)

## 打包

```sh
./scripts/package-release.sh
```

產生 Release 最佳化的 Apple Silicon + Intel Universal App、DMG、ZIP 與 SHA-256 清單，放在 `dist/`。App 與 AskPass helper 使用 ad-hoc 簽章，尚未經 Apple 公證。安裝與回復方式見 [安裝說明](INSTALL.md)。

## 建置 App 保留原則

每種建置設定只保留最新的 `MinaSCP.app`。新 App 完成簽章檢查後才替換舊 App，替換失敗時還原；成功後不再留下 `MinaSCP-previous-*.app`。需要歷史版本時，使用 GitHub Release 的 ZIP／DMG，不依賴散落的建置副本。
