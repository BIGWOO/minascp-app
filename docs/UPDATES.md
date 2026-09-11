# 檢查更新與發佈

MinaSCP 使用 Sparkle 2.9.6 與 GitHub Releases。只在使用者選擇「MinaSCP → 檢查更新…」時連線，顯示目前版本、最新版本與更新說明。關閉更新視窗即稍後處理；「跳過此版本」是明確略過該版。選擇安裝後下載，完成後需點選「安裝並重新啟動」。

傳輸、衝突決策、遠端指令、跨站台複製或屬性操作尚未完成時，更新會延後。工作完成不會自動重啟，需再次點選選單的「安裝更新並重新啟動…」。更新準備完成後，一般結束 App 也不能繞過這項確認。

1.0.0 沒有更新框架，必須手動安裝一次支援更新的版本。本功能不改變站台、密碼與偏好設定格式。ad-hoc App 簽章與 Sparkle 更新簽章並非 Apple Developer ID 或公證，首次下載的 macOS 安全提示仍可能出現。

## 本機建置

一般開發：`./scripts/build-app.sh debug`。未提供公開金鑰時仍可開啟 App，但「檢查更新」會說明此開發包尚未設定。

打包需要 Python 3、Swift 工具鏈與 macOS 的 `codesign`、`ditto`、`hdiutil`。Sparkle 工具由鎖定的 SwiftPM 套件取得；保留 upstream framework 與 helper 的簽章、資源及符號連結，隨 App 附上 Sparkle 授權聲明，外層 App 使用 ad-hoc 簽章，未啟用需要同一 Team ID 的 Library Validation。

## 正式金鑰（需獨立授權）

下列指令是操作說明，不會由打包腳本自動建立或匯出金鑰：

```sh
swift package resolve
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account minascp-production
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account minascp-production -p
```

私鑰留在登入 Keychain；公開金鑰用於 `MINASCP_UPDATE_PUBLIC_KEY`。不得使用測試帳戶的金鑰發佈正式 App。經授權備份時，在受保護的目錄使用官方 `generate_keys --account minascp-production -x <備份檔>`，再存入既有加密備份；不要放入 repository、Release、日誌或聊天內容。妥善保管此私鑰：沒有 Developer ID 的 ad-hoc 發佈不能假設遺失金鑰後仍能無縫輪替，必要時只能由使用者重新手動安裝。

## 準備正式版本

先從最後一次正式 Release 的 App／appcast 確認 build number。初次導入以前一版 1.0.0 的 `260911` 為基準。版本為三段數字，build 為最多三段的遞增數字，例如 `260911.1`；同一天再發版增加最後一段。

```sh
export MINASCP_VERSION=1.1.0
export MINASCP_BUILD=260911.1
export MINASCP_PREVIOUS_BUILD=260911
export MINASCP_UPDATE_PUBLIC_KEY='<正式公開金鑰>'
export MINASCP_SIGNING_ACCOUNT=minascp-production
export MINASCP_RELEASE_NOTES=docs/RELEASE-1.1.0.md
./scripts/package-release.sh
```

腳本只準備本機產物，不提交、不推送、不上傳。輸出為 `dist/MinaSCP-<版本>-<build>-universal/`，包含 ZIP、DMG、appcast、已簽署 Markdown、`RELEASE-BODY.md` 及 `SHA256SUMS.txt`。GitHub Release 內文使用 `RELEASE-BODY.md`；兩份更新說明由同一份 Markdown 產生。簽署後不得直接編輯 appcast 或 Markdown，必須重新產生簽章。

缺少公開金鑰、Keychain 金鑰不符、更新說明不存在、build 未遞增或簽章驗證失敗，都停止準備。已有相同輸出目錄也停止，保留舊產物。打包會獨立驗證清單、ZIP 與更新說明的簽章及長度，不製作差分更新。

固定來源為 `https://github.com/BIGWOO/minascp-app/releases/latest/download/appcast.xml`。每版 ZIP／Markdown 指向 `releases/download/v<版本>/`；正式設定不接受其他來源。第一版清單只提供當前穩定版本，最低系統版本沿用 macOS 14。

## 發佈、讀回與撤回（需獨立授權）

1. 完成本機驗收、正式金鑰備份與版本核對，再準備正式產物。保留前版 App 與資料備份。
2. 經授權建立 tag／Release，先放齊所有資產與內文，最後才將穩定版設為 Latest。不要上傳 `MINASCP_UPDATE_TEST=1` 產物。
3. 從 GitHub 固定 Latest 網址獨立下載 appcast，確認版本、最低 OS、資產 URL、簽章與長度，再下載 ZIP／Markdown 比對雜湊及簽章。測試已安裝的前版能更新、重新開啟，設定仍在。
4. 發現問題時，將 Latest 指回包含有效 appcast 的安全版本，或發布已重新簽署、移除問題版本的清單。已更新者不強制降版；需要回復時結束 App，保留問題版副本並手動安裝保留的舊版。設定備份另行還原，避免覆蓋使用者最新資料。

## 隔離驗收

測試帳戶使用 `minascp-update-test-20260911`，與正式帳戶分離；測試私鑰只在 Keychain。`MINASCP_UPDATE_TEST=1` 只接受 loopback HTTP(S)，App bundle ID 與資料目錄改為 `com.mina.scp.update-test`，不讀寫正式設定。

```sh
export MINASCP_UPDATE_TEST=1
export MINASCP_FEED_URL=http://127.0.0.1:18765/appcast.xml
export MINASCP_SIGNING_ACCOUNT=minascp-update-test-20260911
# 先以 generate_keys --account <測試帳戶> 建立測試金鑰，-p 取得公開金鑰。
# 使用上述打包變數製作較新的測試版本，再以不同 build 製作舊版 App。
python3 -m http.server 18765 --bind 127.0.0.1 --directory '<測試產物目錄>'
```

測試範圍：新版／已是最新版、關閉稍後處理、下載與重啟、傳輸和指令忙碌、下載失敗、清單簽章及 ZIP 簽章錯誤、損壞 ZIP、不相容系統、唯讀 DMG。用伺服器紀錄確認未手動檢查及未確認下載時不取得 ZIP。完成後停止測試伺服器。

```sh
swift test --filter UpdateTests
MINASCP_DOCKER=1 MINASCP_DOCKER_TEST=1 swift test
```

Docker 整合測試使用專案既有的 loopback `22222`／`22224` 測試容器及 `.local-sftp/keys/id_ed25519`，不連線正式主機。Intel Universal slice 建置不等於 Intel 實機驗收；兩者分開記錄。

本次實際驗收範圍與限制見 [驗收紀錄](UPDATE-VALIDATION.md)。
