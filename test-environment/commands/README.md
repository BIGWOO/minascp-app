# 獨立 SSH 命令驗收容器

此容器只綁 `127.0.0.1:22224`，不修改原本 `compose.sftp-test.yml` 的 SFTP-only 設定。先依 `../sftp/README.md` 建立 `.local-sftp/keys/id_ed25519` 與公鑰。

在專案根目錄執行：

```sh
mkdir -p .local-sftp/advanced/data .local-sftp/advanced/hostkeys
docker compose -f compose.commands-test.yml up -d --build
```

使用 tester／22224／同一把本機測試金鑰。遠端目錄 `/data`；不開啟密碼、root、轉送、Agent forwarding。容器安裝 POSIX shell、touch、zip、unzip、tar、Python 3。主機金鑰放 `.local-sftp/advanced/hostkeys/`，與原容器獨立；先透過 `docker compose -f compose.commands-test.yml exec -T commands cat /hostkeys/ssh_host_ed25519_key.pub` 讀回公鑰，再與 App 提示或 ssh-keyscan 比對，不能直接信任掃描值。

```sh
MINASCP_DOCKER=1 MINASCP_DOCKER_TEST=1 swift test
MINASCP_DOCKER=1 MINASCP_DISCONNECT_TEST=1 swift test --filter AdvancedTests.testCrossSiteBothEndpointDisconnectsAndResume
```

斷線測試會先後停止、啟動兩個 Docker 容器，請先讓 App 的 loopback 工作完成。測試只建立 `/data` 內帶 UUID 的驗收檔；不連正式站台。1 GiB 壓力測試另依原 SFTP 文件明確啟用。
