# 玻璃介面視覺參考

以下兩張為實作前確認的 AI 視覺目標，不是 App 截圖：

- [明亮參考](light-reference.png)
- [深色參考](dark-reference.png)

實作沿用原生 macOS 工具列、側欄、NSTableView 與 NSMenu。原生選單外形交由 macOS 決定，保留既有命令、子選單、焦點及啟用條件。App 的透明度僅調整 NSVisualEffectView 上方的語意色遮罩，不調整視窗整體 alpha。

實際畫面請看 [明亮](../../images/glass-light-20260911.jpg)、[深色](../../images/glass-dark-20260911.jpg)、[外觀設定](../../images/glass-settings-20260911.jpg) 與 [驗收紀錄](../../glass-appearance-acceptance-20260911.md)。兩種來源分開保留，避免把設計稿視為已驗收效果。
