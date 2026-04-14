# 柔療髮浴 (Rou Spa) 網站開發記錄

## 專案概述
- **專案名稱**: 柔療髮浴官方網站
- **網址**: https://rouspa.tw
- **GitHub**: https://github.com/AshHuHK/rouspa-website
- **技術棧**: React + Vite + Supabase

---

## 修改歷史

### 2024/04/12 - 初始設置與基礎修改

#### 1. GitHub 推送設置
- 問題: GitHub 已不支援密碼認證
- 解決: 使用 Personal Access Token (PAT) 進行認證
- 分支: `main`

#### 2. Logo 更換
- 檔案: `public/logo2.png`
- 修改檔案: `src/App.jsx`
- 變更內容:
  ```jsx
  // 舊的 SVG Logo
  const SealLogo = ({ size = 44 }) => (
    <svg>...</svg>
  );
  
  // 新的圖片 Logo
  const SealLogo = ({ size = 44 }) => (
    <img src="/logo2.png" alt="柔療髮浴" style={{ width: size, height: size, objectFit: 'contain' }} />
  );
  ```

#### 3. 品牌名稱更改
- 舊名稱: 柔禾養生 / Rouhe Wellness
- 新名稱: 柔療髮浴 / ROU SPA
- 修改檔案:
  - `src/App.jsx`
  - `src/Admin.jsx`
  - `src/Contact.jsx`
  - `src/Shop.jsx`

#### 4. 聯繫資訊更新
- 地址: 嘉義市西區蘭井街421號
- 電話: 0978-918-737
- 營業時間: 每日 10:00 - 02:00（全年無休）

#### 5. 刪除服務項目小圖標
- 刪除 `icon: "☯"`、`icon: "🌿"`、`icon: "🔥"`、`icon: "✨"`
- 位置: `App.jsx` services.items 區塊

---

### 2024/04/13 - Hero 區塊重大改版

#### 1. Hero 背景圖片
- 新增檔案: `public/hero-bg.jpg`
- 遮罩效果:
  - 淺米白色線性漸層
  - 柔光放射漸層
  - 透明度約 20-30%

#### 2. 文案更新
**第一段:**
```
取東方養護之意，循舒緩調理之法，
由頭開始，漸入身心。
```

**五感療癒小標:**
- 左右細線裝飾
- 金色字體

**第二段:**
```
香和其息，音靜其神，觸柔其體，境緩其意，養歸於心。
```

#### 3. Logo 尺寸調整
- Hero 區塊 Logo: 200px (原 100px)
- Footer Logo: 150px (原 50px)
- 導航欄 Logo: 36px (保持不變)

---

### 2024/04/14 - 技師與服務區塊改版

#### 1. 技師介紹區塊
- 人數: 4位 → 6位
- 排列: 2排 × 3欄
- 新增技師:
  - 李靜怡 - 芳香療法 · 淋巴排毒
  - 吳俊霖 - 經絡推拿 · 拔罐理療

#### 2. 養生項目區塊改版

**45分方子 (原價1100):**
- 苦茶籽潔淨髮浴
- 溫熱生薑泥髮浴

**90分方子 (原價2360):**
- 森呼吸－深層淨化養髮
- 墨玉烏－全方位去角質固髮
- 薑暖陽－溫熱撥筋促髮

**120分全息 (原價3200):**
- 森呼吸－深層淨化養髮
- 墨玉烏－全方位去角質固髮
- 薑暖陽－溫熱撥筋促髮

#### 3. 預約流程簡化
- 服務選項改為橫向膠囊式按鈕
- 三選項: 45分方子 / 90分方子 / 120分全息

---

### 2024/04/15 - Hero 區塊最終優化

#### 結構重建
```jsx
// 新的統一容器結構
<section className="hero-section">
  {/* 背景遮罩 */}
  <div className="overlay-gradient" />
  <div className="overlay-radial" />
  
  {/* 主內容容器 - 統一中軸 */}
  <div className="hero-main-container">
    <SealLogo />
    <div className="hero-brand-sub">東方頭療・經絡養生</div>
    <h1>以柔養生</h1>
    <GoldDivider />
    <p className="hero-intro-1">
      取東方養護之意，循舒緩調理之法
      <span className="mobile-break"><br /></span>
      由頭開始，漸入身心。
    </p>
    <div className="hero-subtitle-wrap">
      <div className="hero-subtitle-line" />
      <h2>五感療癒</h2>
      <div className="hero-subtitle-line" />
    </div>
    <p className="hero-intro-2">
      香和其息，音靜其神，觸柔其體，
      <span className="mobile-break"><br /></span>
      境緩其意，養歸於心。
    </p>
    <button>預約體驗</button>
  </div>
</section>
```

#### 手機版斷行控制
```css
/* 預設隱藏斷行 */
.mobile-break { display: none; }

/* 手機版顯示斷行 */
@media (max-width: 640px) {
  .mobile-break { display: inline !important; }
}
```

#### 手機版樣式優化
```css
.hero-main-container {
  width: min(100%, 360px);
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  align-items: center;
}
```

---

## 技術問題與解決方案

### 問題 1: GitHub 推送失敗
**錯誤訊息:**
```
fatal: Authentication failed for 'https://github.com/...'
```

**解決方案:**
1. 生成 Personal Access Token (Settings → Developer settings → Personal access tokens)
2. 使用 Token 作為密碼登入
3. 或設置 git credential helper:
   ```bash
   git config --global credential.helper osxkeychain
   ```

### 問題 2: Logo 圖片不顯示
**原因:** Vite 專案需要將靜態檔案放在 `public` 目錄

**解決:**
```bash
mkdir public
mv logo2.png public/
```

### 問題 3: Hero 區塊手機版不置中
**根本原因:**
- 使用了 `transform: translateX()` 造成偏移
- 各元素分散使用不同的置中邏輯
- 父容器寬度不一致

**最終解決:**
- 建立單一主容器 `.hero-main-container`
- 使用 `width: min(100%, 400px)` 統一寬度
- 使用 `margin: 0 auto` 水平置中
- 移除所有 `transform` 偏移

---

## 檔案結構

```
rouspa-website/
├── public/
│   ├── logo2.png          # 網站 Logo
│   ├── hero-bg.jpg        # Hero 背景圖
│   └── ...
├── src/
│   ├── App.jsx            # 主頁組件
│   ├── Shop.jsx           # 產品頁
│   ├── Contact.jsx        # 聯繫頁
│   ├── Admin.jsx          # 管理頁
│   └── main.jsx           # 入口檔案
├── index.html
├── package.json
├── vite.config.js
└── PROJECT_HISTORY.md     # 本檔案
```

---

## 設計風格規範

### 色彩系統
- **主色 (卡其色)**: `#a3823f`
- **背景色 (米白)**: `#f2ede4`
- **文字色 (深褐)**: `#4a443a` / `#3d382f`
- **輔助色 (淺褐)**: `rgba(74, 68, 58, 0.6)`

### 字體系統
- **中文**: 'Noto Serif TC', serif
- **英文**: 'Cormorant Garamond', serif
- **標題字重**: 400-500
- **內文字重**: 400

### 間距系統
- **區塊間距**: 120px (桌面) / 80px (手機)
- **元素間距**: 20-30px
- **卡片內距**: 24-32px

---

## Git 提交記錄

```bash
# 主要提交
22949a1 - Replace SVG logo with custom logo image
e0dd356 - Remove icons from booking service selection
ff3dbae - Move logo to public folder
ac4c71d - Adjust logo sizes
036b5c7 - Update address, phone, hours; Rename brand
e48dbe2 - Update team section: 6 therapists
5d4c04a - Update Hero section with background image
896d2f9 - Center hero section layout
8445b48 - Move hero logo down
3fffb22 - Rebuild hero section with controlled line breaks
```

---

## 未來待辦

- [ ] 優化網站載入速度
- [ ] 添加更多產品圖片
- [ ] 完善預約系統功能
- [ ] SEO 優化
- [ ] 多語言支援

---

*最後更新: 2024/04/15*
