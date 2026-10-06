# 柔療髮浴 ROU SPA：嘉義頭療 SEO 更新報告

日期：2026-10-05

## 本次調整

目標是讓搜尋引擎及第一次到訪的顧客，清楚理解「柔療髮浴 ROU SPA 是嘉義市的頭療、頭皮養護、頭肩頸舒緩與髮浴門店」。沿用官網咖啡、米白與金色的視覺，增加有用的服務說明與公開網址。

### 1. 首頁

- Title：`嘉義頭療｜柔療髮浴 ROU SPA・頭皮養護與髮浴`。
- Description 自然說明地址、頭皮清潔、頭肩頸按摩、45／90／120分鐘療程與線上預約。
- 原主視覺標語及掃金動畫保留；H1 增加小字「嘉義頭療 · 柔療髮浴 ROU SPA」。
- 服務區 H2 改為「頭療與髮浴療程」，增加簡短選擇說明及「認識頭療服務與預約常見問題」連結。
- 裝飾性「五感療癒」改用一般文字，避免把裝飾誤當內容章節。
- 頁尾增加頭療服務、好物選、聯繫我們的可抓取連結。

### 2. 新增公開服務頁 `/services/`

首頁仍承擔療程菜單與預約操作；服務頁提供第一次到訪需要的解說：

- 嘉義頭療、頭皮清潔與養護、頭肩頸舒緩、髮浴的實際服務範圍。
- 45／90／120分鐘療程選擇說明。
- 當前已公開主要療程的名稱、時長、價格，讀取同一個 Supabase 公開目錄。
- 加購維持獨立分類，完整內容連至首頁的現行菜單。
- 常見問題：首次預約、姓名與手機號碼、指定技師、準備整理時間、加購諮詢。
- 地址、電話、LINE、營業資訊、預約及聯繫入口。

此頁的中文正文與 H1／H2／H3 在伺服器回傳 HTML 中就存在，不必等待 JavaScript 才能讀到核心服務說明。React 使用同一份文案產生畫面；即時價格與營業時間在取得目錄後補入。英文內容跟隨原有語言設定；正式可索引網址仍以中文為主，沒有另設英文網址或假造 hreflang。

沒有添加保證療效、虛構評分或醫療服務宣稱；不同療程的實際步驟仍以當前菜單為準。

### 3. Metadata 與結構化資料一致性

- 首頁、服務、商品、聯絡四頁分別具備 Title、Description、Canonical、OG 與 Twitter 分享資料。
- 建置和瀏覽器共用 `src/lib/seo-content.js`，避免修改一處卻留下另一份舊文字。
- 保留 `WebSite`、`DaySpa`／`HealthAndBeautyBusiness`，補入各頁 `WebPage`。
- 服務頁增加 `Service`、公開療程的 `OfferCatalog` 與 `BreadcrumbList`。
- 修正原本寫死的 `NT$1,100–NT$3,200`。價格範圍從已公開主療程計算，資料庫「分」除以100轉成新台幣「元」，加購、草稿、停用、隱藏項目不混入主要療程價格範圍。
- 每週營業時間由 `business_hours` 產生；10:00至翌日02:00正確表達為跨午夜營業。
- 當日休假／臨時营业時間由 `today_hours` 產生當日的特殊營業設定，日期以台灣時區計算。
- 初始 HTML 不再寫死可變動的價格與營業時間；瀏覽器取得目錄後補入。資料讀取失敗時不輸出猜測值。
- 切換語言或公開頁面時同步更新結構化資料；进入后台／会员／私人预约頁面會移除公開 JSON-LD，並設定 noindex。

`noindex` 是搜尋收錄設定；資料保護仍依現有驗證與資料庫權限，不以 robots.txt 代替存取控制。

### 4. Sitemap 與抓取

Sitemap 列出四個正式公開網址：

1. `https://www.rouspa.tw/`
2. `https://www.rouspa.tw/services/`
3. `https://www.rouspa.tw/shop/`
4. `https://www.rouspa.tw/contact/`

會員、後台、預約查詢、私人改期與評價連結不放入 Sitemap。`robots.txt` 繼續指向正式 Sitemap。預約入口維持首頁中的公開功能區，沒有另新增需要登入或含個資的索引頁。

新增 `/#services`／`/#booking` 的定位處理，從服務頁點選後會到達首頁正確區段。

本次不重複提交、刪除或重建 Search Console 設定。Search Console 的抓取及索引狀態需由 Google 更新，網站部署成功不等於該狀態已更新。

### 5. 圖片、手機與速度

- 首頁保留同一張照片、構圖與遮罩，使用 `<picture>` 按螢幕寬度選圖。
- 手機圖片：960×960，155,496 bytes，約152 KiB；桌面圖片：1920×1920，421,613 bytes，約412 KiB。原圖約1.6 MiB。
- 首屏圖片優先下載，明確宣告尺寸並提供中英文 alt。
- 商品圖片改為有商品名稱 alt 的 `<img>`，使用延遲載入及固定版面比例。
- 服務頁小螢幕改為單欄；連結和預約按鈕保留足夠的觸控高度。
- 重新產生中文精簡字體，覆蓋新增文案及所需字重，避免新字混用系統字體。

這是資產大小與排版改善，沒有將本機測試當作真實訪客的 Core Web Vitals 成績。網站仍有延遲載入的後台 Excel 匯出大檔，該檔不屬於首屏圖片。

## 主要檔案

| 檔案 | 用途 |
| --- | --- |
| `src/lib/seo-content.js` | 四頁 SEO 設定、公開主療程過濾與真實營業／價格 Schema |
| `src/lib/seo.js` | 路由 Metadata、語言更新、私人頁 noindex、公開 Schema 更新 |
| `src/lib/service-content.js` | 服務頁中英文共用文案、安全 HTML 轉義、即時療程表 |
| `src/Services.jsx`、`src/services.css` | 服務頁與手機版布局 |
| `src/App.jsx`、`src/public-theme.css` | 首頁文字層級、服務連結、圖片、跨頁區段定位 |
| `src/Shop.jsx`、`src/Contact.jsx` | 商品圖片 alt／文案、聯絡頁真實營業 Schema |
| `src/main.jsx`、`vite.config.js` | 服務頁路由與靜態 HTML 建置入口 |
| `scripts/build-seo-pages.mjs` | 共用設定產生各頁靜態 Metadata及服務頁正文 |
| `scripts/test-seo.mjs` | SEO及價格、時間資料對應檢查 |
| `public/sitemap.xml`、`public/hero-*.jpg`、`public/fonts/*` | 公開網址、圖片與字體資產 |

`services/index.html` 等頁面由建置產生，不手動編輯；要改服務介紹，修改 `src/lib/service-content.js`。療程價格、上架狀態及營業時間仍在原有後台修改。

## 驗證記錄

- `npm test` 通過：46項 SEO 檢查，並通過現有字體、目錄、日期、預約、資料庫、員工權限、登入及營運系統測試。
- `npm run build` 通過，產生四個公開 HTML 入口。
- SEO 檢查包含：四個 Canonical、公開 Sitemap、服務頁靜態正文、單一H1、價格分轉元、跨午夜營業、每週休假、今日休假、上／下架過濾、後台修改後的新數值、英文與HTML安全轉義。

瀏覽器驗證使用正式建置及真實公開 Supabase 目錄（未建立測試訂單）：

- 1440×1000桌面及390×844手機尺寸的服務頁通過；手機為單欄，頁面無橫向溢出。
- 服務頁顯示 `45分方子 NT$1,200`、`90分方子 NT$2,360`、`120分全息 NT$3,200`；Schema價格範圍一致。
- 首頁手機使用 `hero-960.jpg`，圖片 alt 完整。
- 「線上預約」從服務頁跳至 `/#booking`，定位在導覽列下方約16px；完整菜單連結跳至 `/#services`。
- 常見問題可以展開；切換英文後正文、Title、HTML語言及Canonical一致。
- 私人會員頁 `noindex, nofollow, noarchive`，移除Canonical及公開Schema；回到公開頁恢復索引設定。

### 正式部署驗證

- 功能提交：[339ce25](https://github.com/AshHuHK/rouspa-website/commit/339ce25)，已推送 `main`。
- GitHub的Vercel狀態：`success`，描述 `Deployment has completed`。
- [正式部署記錄](https://vercel.com/ashhuhks-projects/rouspa-website/BSAX35PC5j65SxQEpSBdu6zFT5Vp)。
- `/`、`/services/`、`/shop/`、`/contact/`均HTTP200，獨立Title與Canonical正確。
- `/services/`原始HTML包含服務正文與H1；正式站React取得目錄後顯示當前療程價格。
- `/sitemap.xml`：HTTP200，Content-Type `application/xml`，包含四個公開網址，直接訪問沒有轉址。
- `/robots.txt`：HTTP200，Content-Type `text/plain; charset=utf-8`，指向正式Sitemap。
- 手機及桌面JPEG資產均HTTP200，實際下載155,496及421,613 bytes。
- 正式站390px手機瀏覽器驗證：無橫向溢出、單一H1、目前三檔價格與Schema一致；「線上預約」跳至 `/#booking`，定位在導覽列下方16px。
- 以Googlebot User-Agent從本機檢查Sitemap也回傳HTTP200；這只验证该請求頭未被網站拒絕，不代表真實Googlebot或Search Console已抓取成功。

Search Console未重送或重建；Google帳戶內的抓取、索引、排名狀態不在本次驗證範圍。

## 後續觀察

Google 重新抓取後可能更新標題、索引與搜尋結果，但沒有可保證的排名或固定更新時間。使用 Search Console「成效」觀察實際查詢詞、曝光及點擊；可關注「嘉義頭療」「嘉義頭皮養護」「嘉義髮浴」等實際服務相關詞。門店名稱、地址與電話在 Google 商家資料及其他公開頁面也應保持一致。

本次未直接操作 Google 商家資料或 Search Console，也未確認使用者帳戶中的索引或排名結果。

## 官方參考

- [Google SEO 入門指南](https://developers.google.com/search/docs/fundamentals/seo-starter-guide)：描述性標題、內容層級、可抓取連結與圖片替代文字。
- [Google LocalBusiness 結構化資料](https://developers.google.com/search/docs/appearance/structured-data/local-business)：使用具體的商業類型及真實門店資訊、營業與休假設定。
- [Google JavaScript 結構化資料](https://developers.google.com/search/docs/appearance/structured-data/generate-structured-data-with-javascript)：頁面呈現的即時資料可產生 JSON-LD。
