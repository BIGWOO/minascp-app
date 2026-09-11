# 本機 Docker SFTP 驗收

- 主機 `127.0.0.1`、連接埠 `22222`、使用者 `tester`。
- 私鑰：專案 `.local-sftp/keys/id_ed25519`；遠端路徑 `/data`。
- Finder 上傳素材：`.local-sftp/finder-upload`；下載目的地：`.local-sftp/finder-download`。
- 遠端檔案實際保存在 `.local-sftp/data`，包含中文檔名與 16 MiB 測試檔。
- 僅 loopback 發布，使用專用金鑰、禁止密碼登入與 SSH shell/forwarding。
- 主機私鑰持久保存於 `.local-sftp/keys`，容器重建不會變更指紋。主機公鑰已與容器直接讀回比對，登錄到 `~/.ssh/known_hosts` 的 `[127.0.0.1]:22222`。
- 所有測試金鑰／資料均由 `.gitignore` 排除。

在專案根目錄執行：

```sh
docker compose -f compose.sftp-test.yml up -d
docker compose -f compose.sftp-test.yml stop
```

停止不刪除測試資料。App 已保存「Docker 本機驗收」站台，重開後在側欄選取並連線即可。

已完成 CLI 真實 Docker SFTP 上下載與位元組比對；Finder 拖曳由使用者驗收。

## 0.2 登入驗收的額外本機 fixture

這次另建立 `minascp-auth-test`，只綁定 `127.0.0.1:22223`。帳號 `tester`，一次性測試密碼 `minascp-local-fixture`。加密私鑰副本為 `.local-sftp/keys/id_ed25519-encrypted`，測試密語 `minascp-encrypted-fixture`。這些是刻意建立的非正式 fixture，不能用於真實主機；未保存到 Keychain。

完成驗收後可停止額外容器：

```sh
docker stop minascp-auth-test
```

`.local-sftp/` 已忽略，不隨來源包交付。新一次執行可重新建立 fixture，不應把這些測試憑證當作產品預設。
