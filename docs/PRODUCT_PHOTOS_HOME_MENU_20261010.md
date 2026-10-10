# 商品照片與首頁療程菜單調整

日期：2026-10-10

## 改動

| 位置 | 結果 |
| --- | --- |
| 後台 → 服務・商品・庫存 → 商品與庫存 → 新增／編輯商品 | 可直接選 JPG、PNG、WebP 照片，預覽後按儲存；也可使用圖片網址 |
| 商品資訊 | 中英文名稱與介紹、分類、SKU、條碼、中英文規格／庫存單位；產品資訊支援換行 |
| 首頁療程菜單 | 移除重複的 45／90／120 分鐘分類標題，保留「45分方子、90分方子、120分方子」、價格與內容卡片 |
| 第四類服務 | 公開頁、後台、錯誤提示統一顯示「另外項目」，保留原 `add_on` 分類及預約規則 |
| 分隔線 | 「頭療與髮浴療程」「預約調理」下方使用細長實線 |

## 照片保存與資料連動

- 照片上限 5 MiB（5,242,880 bytes），檔案格式與檔頭須相符。
- 選擇檔案時只在本地預覽，儲存時先上傳、再寫入商品。
- 上傳失敗不保存商品；保存失敗保留表單與已上傳網址，重試同一張照片不重複上傳。上傳等待 45 秒會顯示提示，再試沿用原上傳。
- 專用 `product-media` 儲存區只存公開產品照片。上傳權限沿用有效帳號的 `catalog.manage`；不授予匿名或普通技師上傳權限。
- 使用唯一 UUID 路徑且禁止覆寫；移除照片只清除商品圖片關聯，不刪其他商品可能共用的舊圖片。
- 商品草稿、展示開關、庫存、售價、歷史訂單及抽成規則不因照片功能改變。
- `formula120` 只有舊名恰為「120分全息」時更新為「120分方子」；其他自訂名稱與歷史快照不改動。主資料供預約、POS、後台共用。

## 主要檔案

- [ProductEditor.jsx](../src/ProductEditor.jsx)、[product-editor.css](../src/product-editor.css)、[product-media.js](../src/lib/product-media.js)：商品表單、檔案檢查與保存流程。
- [BusinessOS.jsx](../src/BusinessOS.jsx)、[Shop.jsx](../src/Shop.jsx)：表單入口、名稱一致、商品照片與介紹顯示。
- [App.jsx](../src/App.jsx)、[catalog-presentation.js](../src/lib/catalog-presentation.js)、[service-content.js](../src/lib/service-content.js)：療程名稱、分隔線與服務說明。
- [202610100006_product_media.sql](../supabase/migrations/202610100006_product_media.sql)：專用儲存區與上傳權限。
- [202610100007_home_catalog_labels.sql](../supabase/migrations/202610100007_home_catalog_labels.sql)：目錄顯示名稱。
- [營運手冊](../ROU_SPA_OPERATING_MANUAL.md)：第 11 節更新操作、失敗重試、權限與公開照片規則，部署後供問管家閱讀。

## 驗證範圍

檔案檢查與重試測試、Storage RLS 權限測試、商品照片與介紹資料回讀、既有營運回歸測試、SEO／字體檢查及 production build；另以瀏覽器檢查首頁桌面／390px 手機版與商品表單。

正式部署驗收不建立虛構商品或顧客交易；表單的上傳／保存互動使用本地合成資料，正式環境核對儲存區限制、權限政策及目錄名稱。

驗收結果：`npm test`、`npm run build` 及差異格式檢查通過；照片 helper 31 項與 Storage／資料回讀 64 項檢查通過。正式 Supabase 已套用兩支 SQL，核對專用公開儲存區大小／格式限制正確、RLS 開啟、只有既定目錄管理 INSERT 政策。匿名公開目錄 HTTP 200，主療程名稱為 45／90／120 分方子，原「拳推按摩」仍保留在 `website_addons`。
