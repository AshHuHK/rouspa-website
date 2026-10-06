# ROU SPA 技術 SEO 上線說明

## 已建立的公開抓取文件

- `https://www.rouspa.tw/sitemap.xml`
- `https://www.rouspa.tw/robots.txt`

Sitemap 只列出可以公開索引的正式網址：

1. `https://www.rouspa.tw/`
2. `https://www.rouspa.tw/shop/`
3. `https://www.rouspa.tw/contact/`

商品與聯絡頁原本使用 `#shop`、`#contact`。網址片段不適合作為 Sitemap 頁面，因此已新增 `/shop/` 和 `/contact/` 正式網址；舊網址仍可開啟並會在瀏覽器內轉成正式網址。

## 不公開索引的功能

以下功能不放入 Sitemap，執行時也會設定 `noindex, nofollow, noarchive`：

- 管理後台
- 會員中心
- 姓名手機預約查詢
- 顧客私人改期／取消連結
- 顧客私人評價連結

`robots.txt` 也保留對應 Clean URL 的禁止規則。Hash 後面的內容不會傳送給伺服器，所以實際 Hash 私人頁由網站執行時的 Robots Meta 保護。

## 頁面 Metadata

首頁、商品頁和聯絡頁各自具備：

- 獨立 Title
- 獨立 Description
- Canonical URL
- `index, follow, max-image-preview:large`
- Open Graph 標題、說明、網址和圖片
- Twitter Large Image Card
- 正確的 `zh-Hant`／`en` 語言標記

網站切換語言、頁面或使用瀏覽器上一頁時，Metadata 會同步更新。

## LocalBusiness 結構化資料

首頁加入 Schema.org `DaySpa`／`HealthAndBeautyBusiness` 結構化資料，包含：

- 柔療髮浴 ROU SPA 名稱
- 嘉義市西區蘭井街421號
- `+886978918737`
- 公開聯絡信箱
- 正式網站與品牌圖片
- 新台幣價格範圍
- 每日 10:00 至翌日 02:00 的目前每週營業設定
- LINE 官方帳號

每日臨時休假仍由網站前台與預約系統即時顯示；結構化資料表示門店目前的固定每週營業設定。

## 社群分享圖片

新增 `public/og-image.jpg`，尺寸為 1200 × 630，使用網站原有頭療主視覺裁切。Facebook、LINE、Messenger 等支援 Open Graph 的服務可以讀取這張圖片。

## 驗證

自動檢查包含：

- Sitemap XML 格式正確。
- 只列出三個公開 Canonical URL。
- Sitemap 不含 `#`、後台、會員、查詢或私人連結。
- Robots 指向正式 Sitemap。
- Canonical、OG、Twitter Metadata 完整。
- LocalBusiness JSON-LD 可以解析且地址、電話、營業時間正確。
- Vercel 可以提供 `/shop/` 與 `/contact/`。
- 舊 Hash 路由和所有私人路由繼續可用。
- 中文精簡字體已重新產生，新增 SEO 文案不會缺字。

## Search Console 下一步

部署完成後先直接開啟：

1. `https://www.rouspa.tw/sitemap.xml`
2. `https://www.rouspa.tw/robots.txt`

確認都回傳 HTTP 200，再回 Google Search Console 的 Sitemap 頁面重新提交：

`https://www.rouspa.tw/sitemap.xml`

Google 的狀態更新不是即時的。網站能回傳 200 和有效 XML 後，Search Console 仍可能需要數小時到數天才從「無法抓取」更新為「成功」。
