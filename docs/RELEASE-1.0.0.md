# MinaSCP 1.0.0 (260911)

採用水藍與薄荷綠「蜷貓守護」App logo，套用 Finder／Dock／關於視窗與側欄。提供 macOS 14+、Apple Silicon／Intel Universal 的 DMG 與 ZIP。

## 安裝

[GitHub Release](https://github.com/BIGWOO/minascp-app/releases/tag/v1.0.0) 為私人 repo，需登入有權限的帳號。建議下載 DMG 並拖入 Applications，詳細首次啟動步驟見 [INSTALL.md](INSTALL.md)。

使用 ad-hoc 簽章，尚未經 Developer ID 簽署或 Apple 公證；其他 Mac 可能需要手動允許開啟。此版無自動更新，不包含使用者站台、金鑰、密碼或測試資料。

## 發佈前驗證（2026-09-11）

- 一般基線測試：55 項，13 項略過，0 失敗。
- Docker SFTP／SSH 整合：排除單獨執行的 AskPass 測試後共 54 項，2 項略過，0 失敗；略過為需額外啟用的斷線與壓力測試。
- AskPass 測試獨立執行：1 項通過。第一次整批執行曾停在 Foundation `Process.waitUntilExit`；保留診斷後中止，未把該次算通過，也未改動登入邏輯。
- Release 最佳化雙架構建置通過；App 與 AskPass 均讀回 `x86_64 arm64`。
- Bundle 的 `CFBundleShortVersionString=1.0.0`、`CFBundleVersion=260911`、最低 macOS 14.0 已讀回。
- App 與內含 helper 的 ad-hoc 簽章深度／嚴格驗證通過，動態依賴為系統函式庫。
- 實際開啟 Release App，目視確認側欄 logo 與「About」圖示／版本 `1.0.0 (260911)`。
- DMG checksum 驗證、掛載、複製 App、逐檔內容比對及複製後簽章驗證通過。
- 從 DMG 複製出的 AskPass helper 實際完成 Unix socket 問答與正確結束碼驗證，使用一次性測試內容。

Intel 與最低版本 macOS 14 尚未在實體機啟動驗證；目前實際啟動驗證為本機 Apple Silicon。既有功能與限制見 README，各歷史驗收文件不代表每項操作都在本次重做。

## 重建與回復

執行 `./scripts/package-release.sh`。同名發佈檔存在時拒絕覆蓋；重新建置 App 會保留上一份 App。回復時結束 App、換回保留的舊 App；使用者設定另行備份與回復。
