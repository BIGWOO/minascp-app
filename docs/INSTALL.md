# MinaSCP 1.0.0 (260911) 安裝

需求：macOS 14 或更新，Apple Silicon 或 Intel Mac。Universal 安裝包不需要另裝 Swift、Homebrew 或 Docker。

1. 使用有權限的 GitHub 帳號登入 https://github.com/BIGWOO/minascp-app/releases/tag/v1.0.0 。
2. 下載 `MinaSCP-1.0.0-260911-universal.dmg`，開啟後將 MinaSCP 拖到 Applications；也可解壓 ZIP 後移入 Applications。
3. 開啟 MinaSCP。此版使用 ad-hoc 簽章，尚未經 Apple Developer ID 簽署及公證；若 macOS 阻擋，先嘗試開啟一次，再到「系統設定 → 隱私權與安全性 → 仍要打開」，依系統提示確認。

若系統仍不允許開啟，先核對下載檔 SHA-256 與同一 Release 的 `SHA256SUMS.txt`。確認來源與雜湊後，可只移除這份 App 的下載隔離標記：

```sh
xattr -dr com.apple.quarantine /Applications/MinaSCP.app
open /Applications/MinaSCP.app
```

這不會關閉整台 Mac 的 Gatekeeper。公司管理的 Mac 可能仍需 IT 核准。

站台、金鑰及密碼不包含於安裝包。各工作電腦自行設定連線；設定儲存在 `~/Library/Application Support/com.mina.scp/`，新主機首次連線需核對主機指紋。刪除 App 不會移除上述設定。

更新或回復前先結束 App、保留舊 App 副本，並備份上述設定目錄。此版不含自動更新。
