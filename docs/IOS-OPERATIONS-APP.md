# 柔療營運 iOS App：建置、驗收與發布

本文件說明以 Capacitor 封裝的 **iPhone／iPad 門店後台 App**。App 名稱為「柔療營運」，Bundle ID 為 `tw.rouspa.operations`。它只載入受登入與權限保護的 `Admin` 後台；顧客首頁、預約、查詢及會員中心仍使用 [https://www.rouspa.tw](https://www.rouspa.tw)。

日常操作、角色權限、預約、排班、出勤、POS、薪資及問管家規則，以 [完整操作手冊](../ROU_SPA_OPERATING_MANUAL.md) 為唯一準則。本文件只維護 App 建置、發布及原生差異。

## 1. 架構與資料一致性

- `mobile/index.html` 與 `src/ios-main.jsx` 是獨立原生入口，只渲染 `Admin`，不把公開顧客路由當成 App 首頁。
- `vite.config.ios.js` 輸出到 `dist-ios/`；`capacitor.config.ts` 再把它同步到 Xcode 專案。設定沒有 `server.url`，正式 App 使用打包進安裝檔的程式，不遠端熱載入整個網站。
- App 與網站登入同一個 Supabase 專案，讀寫同一份門店資料、RPC、RLS、角色及稽核紀錄。不存在第二套 App 資料庫，也不需要把 App 資料另行「同步」回網站。
- 官網、顧客預約與私人連結一律指向 `https://www.rouspa.tw`。問管家從 App 呼叫正式站的 `/api/ask-steward`；伺服器及兩支員工帳號 Edge Function 只對白名單來源回應 CORS。
- 前景時沿用 Realtime 與事件驅動更新。iOS 將 App 放到背景後可能暫停網路；回到前景會重新啟動登入自動更新並觸發補讀。App 關閉時目前沒有 APNs 推播。

主要檔案：

| 檔案 | 用途 |
| --- | --- |
| `capacitor.config.ts` | App ID、名稱、原生來源、啟動畫面及狀態列 |
| `vite.config.ios.js` | 獨立 App 前端建置 |
| `mobile/index.html` | App HTML shell；禁止搜尋索引 |
| `src/ios-main.jsx` | 後台入口、生命週期、外部連結及啟動畫面 |
| `src/ios.css` | safe area、觸控尺寸與 iOS 表單字級 |
| `src/lib/native-platform.js` | 官網 URL、API URL、匯出及分享介面 |
| `src/lib/attendance.js` | 原生／瀏覽器定位打卡 |
| `ios/App/App/` | Xcode 專案、圖示、隱私聲明及原生殼 |

## 2. 開發環境與常用指令

需求：Node.js 22.12 以上、npm、Xcode 26.0 以上（Capacitor 8 的最低要求）。提交 App Store 或安裝真機另需 Apple Developer 帳號、簽名憑證與 provisioning profile。本專案使用 Capacitor Swift Package Manager，不以 CocoaPods 作為必要步驟。

```sh
npm ci
npm test
npm run build
npm run ios:verify
npm run ios:open
```

- `npm test`：網站及後台完整測試，包含 iOS 靜態發布契約。
- `npm run build`：Vercel 官網正式建置；不建立 iOS 安裝檔。
- `npm run build:ios`：只建立 `dist-ios/` 原生前端資源。
- `npm run ios:sync`：建置 iOS 資源並執行 `cap sync ios`。
- `npm run ios:verify`：iOS 契約檢查、原生前端建置及 Capacitor 同步。
- `npm run ios:open`：完成同步後開啟 Xcode。

CI 及無簽名本機檢查可執行：

```sh
xcodebuild \
  -project ios/App/App.xcodeproj \
  -scheme App \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /tmp/rouspa-ios-derived \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY='' \
  COMPILER_INDEX_STORE_ENABLE=NO \
  build
```

`dist-ios/`、`ios/App/App/public/`、DerivedData、archive 及 IPA 是產物，不提交。Xcode 專案、圖示、Privacy Manifest、Info.plist、Swift 原生殼及 Swift Package 設定要提交。

## 3. 權限、定位與隱私

- 店主用電子郵件及密碼；員工用店主建立的使用者名稱及密碼。App 不新增另一種帳號，也不繞過後端帳號啟用、角色、人員在職狀態或 `login_after` 檢查。
- 登入 session 保存在 App WebView 的既有 Supabase 儲存機制。App 進入背景時立即以原生遮罩隱藏營運畫面；回到前景先向伺服器刷新 session，失效時清除登入，通過後才移除遮罩並補讀營運資料。目前沒有另外實作 Keychain、Face ID 或 Touch ID；不要在商店說明中聲稱已有這些功能。
- 只有員工按「上班」或「下班」時，App 才要求「使用 App 期間」的精確定位。每次要求新的高精度位置，最久等待 15 秒，不沿用快取，不在背景持續追蹤。
- 拒絕權限、關閉定位、逾時或座標無效時不建立打卡；應開啟權限後重試，或送補打卡／工時更正申請。已取得合法座標但超出範圍或誤差過大，才按既有異常原因與審核流程處理。
- `Info.plist` 依 Capacitor Geolocation 8 的 iOS 整合要求同時提供 When-In-Use 與相容用途說明，但 App 程式只在使用者按打卡時要求 `location` 權限，沒有背景定位模式，也不持續定位。商品照片只有在有權人員主動選擇或系統提供拍攝選項時才讀取相片／相機。`PrivacyInfo.xcprivacy` 宣告 App 實際處理且與帳號連結的精確位置、帳號、姓名／電話／Email／地址、財務／購買記錄、商品照片、生日／任職等其他資料及使用者內容，全部只用於 App 功能，並宣告不追蹤；另依 Filesystem plugin 要求，以 `C617.1` 說明 App 建立、分享及清理匯出暫存檔時使用檔案時間戳。App Store Connect 的 App Privacy 回答、[隱私權說明](https://www.rouspa.tw/privacy/)和實際功能必須保持一致。
- 前端只能放 Supabase publishable／anon key。Kimi、Supabase service role、GitHub、Apple 私鑰及簽名資料不得寫入 App bundle、程式碼或 GitHub。

## 4. 原生操作差異

### 外部連結

後台裡所有 `http`／`https` 連結由 Capacitor Browser 開啟。查看官網、顧客會員中心、預約／評價私人連結、地圖及外站不會把 App 切換成顧客版。複製私人連結仍是 `https://www.rouspa.tw/#...`，可交給顧客在一般瀏覽器開啟。

### CSV、XLSX 與 JSON

網站版維持瀏覽器下載。App 版先在 iOS Cache 建立臨時檔，再打開系統分享表，讓使用者選擇「儲存到檔案」、郵件或其他允許目的地；分享流程不論完成、取消或失敗都會嘗試立即刪除 App 暫存檔，清理失敗會顯示錯誤並要求重開 App 後再繼續匯出。取消分享不會刪除或還原 Supabase 裡的營運紀錄。使用者自行保存或傳出的檔案可能含會員、財務或薪資資料，應只保存到門店核准位置並依門店資料政策刪除。

### 商品照片

商品照片使用系統檔案／相片選擇介面，仍執行網站相同的格式、大小、角色及 Storage 規則。若 iOS 在選擇介面提供拍攝選項，也只在使用者主動選擇後取用；選取不等於已保存，必須在商品表單正式儲存才完成資料關聯。App 可預覽 Supabase 或其他 HTTPS 圖片；iOS 平台安全限制可能拒絕不安全的 HTTP 圖片。上架前仍須以真機驗證相簿與相機兩條流程。

### 重設備份

「先儲存備份，再重設」會等待系統分享表關閉，並再次要求操作者確認檔案已實際保存；分享失敗、暫存檔清理失敗或操作者按取消都不會執行重設。這項確認只能防止未保存就誤刪，不能證明 JSON 已完成還原測試。

### 連線中斷

目前沒有離線寫入或背景重送佇列。暫時斷線時畫面可能保留最後一次成功資料，但任何新增、核准、結帳、改班或薪資操作都不能因此推定成功。恢復網路後回到前景、重新整理原模組並以伺服器結果核對；有操作編號的流程沿用既有冪等規則。

## 5. 發布前部署順序

1. 先按遷移順序部署這次版本所需 Supabase migrations，並部署 `staff-login`、`staff-accounts` 等變更的 Edge Functions。確認 `capacitor://localhost` 只在需要 App 存取的受保護端點白名單中。
2. 部署 Vercel 官網／API，確認 `/api/ask-steward` 對 App 原生來源完成精確 CORS，且沒有把模型密鑰交給瀏覽器。
3. 執行 `npm ci`、`npm test`、`npm run build`、`npm run ios:verify`。
4. 開啟 Xcode，設定自己的 Apple Development Team。Release 的 Bundle ID 保持 `tw.rouspa.operations`；增加 `CURRENT_PROJECT_VERSION`，對外版本才增加 `MARKETING_VERSION`。
5. 在至少一支實機和一個 Simulator 完成下方驗收。定位打卡的門店內／外判定必須以實機核對，不能只用 Simulator 當正式證據。
6. Archive → Validate App → 上傳 App Store Connect。先用 Internal TestFlight，再擴大門店測試；通過後才送 App Review 或發布。

App wrapper 本身沒有新增資料表；若同一發布另含 migrations，必須先部署相容的後端，再讓新 App 使用。資料與後端規則更新會即時被 App 讀到；原生入口、樣式、plugin 或 JavaScript 程式更新仍須重新建置及透過 TestFlight／App Store 發版。

## 6. 必做驗收清單

### 登入與權限

- [ ] 店主電子郵件登入、登出、重開 App 後 session 恢復。
- [ ] 員工使用者名稱登入；停用帳號、離職人員、舊密碼／舊 token 被後端拒絕。
- [ ] 店主看完整模組；員工只看既有授權模組與本人資料。直接呼叫受限 RPC 仍被拒絕。
- [ ] 「查看網站」及私人連結開到正式 `www.rouspa.tw`，不留在 `capacitor://localhost/#...`。

### 預約、排班與即時更新

- [ ] App 與另一瀏覽器同時登入：新增／改期／取消、技師實際指派、排班／休假及狀態更新在前景收到更新。
- [ ] App 背景停留後再回前景，能補讀最新狀態，不出現重複提交。
- [ ] 店主、員工各自的營運月曆、提醒數、下月班表及變更申請符合角色裁剪。

### 出勤

- [ ] 未上班時只可按上班；上班中只可按下班；讀取中、送出中或錯誤狀態兩個按鈕都不可誤按。
- [ ] 第一次打卡出現清楚的 When-In-Use 權限文字；允許後門店內正常打卡。
- [ ] 拒絕、關閉定位及逾時都不建立打卡；重新允許後可重試。
- [ ] 門店外或誤差過大須填異常原因，原始座標／誤差及店主審核與薪資工時連動正確。

### 匯出、商品與問管家

- [ ] 會員 CSV、薪資 XLSX、重設備份 JSON 都打開 iOS 分享表，中文檔名與內容可讀。
- [ ] 商品照片可選擇、預覽、保存；不合格式或超過 5 MiB 會被拒絕；一般員工不能繞過目錄權限。
- [ ] 問管家可詢問、可停止等待，回覆只含帳號有權資料；App bundle／網路回應不暴露模型密鑰。

### 裝置與介面

- [ ] iPhone SE 寬度、一般 iPhone、Max 及 iPad 沒有水平溢出；瀏海、Dynamic Island 與底部 Home Indicator 不遮住按鈕。
- [ ] 中文輸入不因小於 16px 自動縮放；主要按鈕觸控區至少 44pt；彈窗在短螢幕可滾動。
- [ ] 亮色模式下啟動畫面、狀態列、登入頁、主要後台、待辦及問管家風格一致。

## 7. App Store Connect 準備

發布人需自行提供或確認：Apple Developer Team、簽名、發行地區、年齡分級、[客服 URL](https://www.rouspa.tw/support/)、[隱私政策 URL](https://www.rouspa.tw/privacy/)、審核用非店主與店主測試帳號／說明、資料刪除與帳號管理說明、商店截圖，以及和 Privacy Manifest 一致的 App Privacy 回答。測試帳號不得是真實顧客或正式薪資資料帳號。

1024×1024 App Icon 必須是無透明通道的 RGB PNG；上傳前以 `scripts/test-ios-app.mjs` 與 App Store 驗證再檢查。正式版本不承諾 APNs 推播、離線操作、Face ID／Keychain、自動背景定位或 App 內自動更新，除非日後另行實作並同步更新手冊、隱私聲明與商店資訊。

## 8. 更新、回復與事故處理

- 後端先維持向後相容，再逐步放 TestFlight；不要先移除舊 App 仍會呼叫的 RPC／欄位。
- App 發布失敗可停止 TestFlight build 或在 App Store Connect 改回上一可用版本；資料庫回復仍依 migration 與備份方案，不能靠安裝舊 App 回復資料。
- 發現錯誤先保留請求編號、帳號角色、App 版本／build、iOS 版本、台灣時間、模組及畫面訊息。不要在回報貼顧客手機、密碼、私人連結、精確定位或密鑰。
- 每次涉及 iOS 入口、原生來源、定位、外部連結、匯出、生命週期、帳號或權限的改動，都要同步更新 [完整操作手冊](../ROU_SPA_OPERATING_MANUAL.md)，再執行 `node scripts/check-operating-manual.mjs --record`。
