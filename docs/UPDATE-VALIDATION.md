# 檢查更新驗收紀錄（2026-09-11）

本機 macOS 26.7、Apple Silicon，Sparkle 2.9.6。使用 loopback 更新來源與獨立測試金鑰，測試 App ID 為 `com.mina.scp.update-test`。未建立正式金鑰，未提交、推送或發布 GitHub Release。

## 已通過

- Debug App 與 arm64／x86_64 Universal Release 封裝、動態 framework 載入及巢狀 `codesign --verify --deep --strict`。
- Sparkle 官方工具獨立驗證 appcast、ZIP、Markdown 簽章及長度。
- 原生介面實測：選單在「關於 MinaSCP」之後；顯示新舊版本、日期與繁體中文 changelog，按鈕採繁體中文。
- 關閉新版提示後沒有下載 ZIP；HTTP 紀錄只有 appcast 與 Markdown 請求。再次手動檢查能重新顯示新版。
- 真實版本更新：測試 1.0.9（260911.1）分別更新至 1.1.0（260911.2／260911.3），完成下載、使用者確認、替換與重新啟動，獨立讀回 build number。
- 更新至 260911.3 後，`preferences-v1.json` 與 `workspace-v1.json` 的 JSON 內容與更新前完全一致；再次檢查顯示已是最新版。
- 準備安裝時按 Cmd-Q 會要求明確確認，不會藉一般結束 App 完成安裝。回到更新視窗點選「安裝並重新啟動」後成功更新。
- 原生介面失敗情境：來源無法連線、appcast 404、ZIP 404、竄改清單、錯誤 ZIP 簽章、有效簽章但內容損壞的 ZIP、不相容 macOS 99.0、較舊 build。皆顯示錯誤或不提供安裝；讀回原 App 仍為 260911.1。
- 唯讀 DMG 啟動：明確提示移到「應用程式」後再更新，未嘗試寫入唯讀映像檔。
- Docker 真實傳輸與 `sleep 3` 遠端命令整合測試：忙碌時延後；傳輸雜湊與命令成功結果均讀回；工作完成不會自行恢復安裝，需再次確認。
- 衝突決策測試：更新結束流程不會將傳輸改為暫停，待使用者略過衝突後才允許確認更新；取消確認仍保留待更新狀態。
- 確認安裝後新工作才開始的競態測試：再次延後結束並要求重新確認；錯誤清除舊回呼，下一輪可重新更新。

## 測試結果

- `MINASCP_DOCKER=1 MINASCP_DOCKER_TEST=1 swift test`：68 項，2 項略過，零失敗。
- 兩項略過為需額外啟用的強制斷線恢復與 1 GiB／1000 檔案壓力測試，與本次更新功能無直接關係。
- 最後修改重啟保護後，`MINASCP_DOCKER=1 swift test --filter UpdateTests`：5 項，零失敗。
- `python3 -m unittest discover -s scripts/tests`：3 項設定驗證測試，零失敗。
- 最終產物另完成 1.1.0（260911.3 → 260911.4）的同版號更新，讀回 build 260911.4；Sparkle 授權聲明與原始檔逐位元比對相同，簽章驗證通過。
- 最後封裝另包含 Sparkle 授權聲明。測試產物及工具輸出位於忽略追蹤的 `build/update-test/` 與 `dist/`，不得當作正式 Release 上傳。

## 尚未涵蓋

Intel 實機、macOS 14 實機與正式 GitHub HTTPS 來源端到端更新尚未驗收。Universal slice 與 deployment target 的建置證據不等於這些實機驗證。正式發布需要獨立授權建立及備份正式金鑰，並在發布後以實際 Latest URL 與已安裝舊版讀回驗證。
