import { useState } from "react";
import { STORE } from "./lib/public-copy.js";

// ============================================================
// 產品資料；品名與價格保持原設定
// ============================================================
const products = {
  zh: {
    categories: [
      { id: "tea-cake", name: "茶餅", icon: "🍵" },
      { id: "shampoo-bar", name: "洗頭餅", icon: "🧼" },
      { id: "essential-oil", name: "精油", icon: "💧" },
      { id: "tea-bag", name: "養生茶包", icon: "🌿" },
    ],
    items: [
      { category: "tea-cake", name: "雲南古樹普洱茶餅", price: "NT$1,280", priceNote: "357 g / 餅", desc: "精選百年古樹茶菁，傳統手工壓製，陳香醇厚，回甘悠長。適合收藏與日常品飲。", badge: "經典" },
      { category: "tea-cake", name: "桂花普洱小茶餅", price: "NT$680", priceNote: "200 g / 餅", desc: "普洱熟茶搭配天然桂花，花香與茶韻交融，甜潤順口，午後療癒首選。", badge: "人氣" },
      { category: "tea-cake", name: "玫瑰花茶餅", price: "NT$580", priceNote: "150 g / 餅", desc: "大馬士革玫瑰花瓣與白茶壓製，花香與茶香交融，適合日常品飲。", badge: "" },
      { category: "tea-cake", name: "陳皮老白茶餅", price: "NT$880", priceNote: "300 g / 餅", desc: "三年陳皮搭配福鼎老白茶，茶香醇和，適合冬日暖飲。", badge: "推薦" },
      { category: "tea-cake", name: "茉莉龍珠禮盒", price: "NT$960", priceNote: "12顆入 / 盒", desc: "手工搓揉成珠，三次窨花，茉莉花香馥郁。精緻禮盒，送禮自用皆宜。", badge: "禮盒" },
      { category: "shampoo-bar", name: "何首烏養髮洗頭餅", price: "NT$480", priceNote: "80 g / 顆", desc: "何首烏、側柏葉、生薑萃取，適合日常洗髮與頭皮清潔。", badge: "明星" },
      { category: "shampoo-bar", name: "茶籽控油洗頭餅", price: "NT$420", priceNote: "80 g / 顆", desc: "苦茶籽油深層清潔，薄荷涼感控油，適合油性頭皮。天然植萃配方。", badge: "" },
      { category: "shampoo-bar", name: "艾草淨化洗頭餅", price: "NT$450", priceNote: "80 g / 顆", desc: "陳年艾草、薰衣草精油，草本香氣，適合日常頭皮清潔。", badge: "推薦" },
      { category: "shampoo-bar", name: "生薑暖養洗頭餅", price: "NT$450", priceNote: "80 g / 顆", desc: "老薑精華溫暖頭皮，帶來暖感與草本香氣，搭配日常洗髮使用。", badge: "" },
      { category: "essential-oil", name: "頭療專用複方精油", price: "NT$1,680", priceNote: "30 ml", desc: "薰衣草、迷迭香、薄荷、天竺葵調配，芳香層次豐富，可搭配頭療使用。", badge: "店內同款" },
      { category: "essential-oil", name: "安神助眠精油", price: "NT$1,280", priceNote: "15 ml", desc: "真正薰衣草、羅馬洋甘菊、佛手柑，柔和香氣，適合營造放鬆的居家氛圍。", badge: "人氣" },
      { category: "essential-oil", name: "活血通絡按摩油", price: "NT$980", priceNote: "50 ml", desc: "紅花、川芎、當歸浸泡油，搭配甜杏仁基底油，居家肩頸按摩適用。", badge: "" },
      { category: "essential-oil", name: "艾草薰香精油", price: "NT$780", priceNote: "15 ml", desc: "純天然艾草蒸餾精油，搭配擴香儀使用，營造草本香氣的居家氛圍。", badge: "" },
      { category: "tea-bag", name: "養生暖身茶（禮盒）", price: "NT$580", priceNote: "12包入", desc: "紅棗、枸杞、桂圓、黃耆，草本暖飲，適合日常品飲。", badge: "店內同款" },
      { category: "tea-bag", name: "漢方安神茶", price: "NT$680", priceNote: "15包入", desc: "酸棗仁、茯苓、百合、甘草，適合在晚間享用的草本茶飲。", badge: "熱銷" },
      { category: "tea-bag", name: "活血美人茶", price: "NT$620", priceNote: "15包入", desc: "玫瑰、丹參、紅棗、桂花，花香與草本風味交融，適合日常品飲。", badge: "" },
      { category: "tea-bag", name: "清肝明目茶", price: "NT$560", priceNote: "15包入", desc: "菊花、決明子、枸杞、桑葉，清爽草本風味，適合休息時品飲。", badge: "" },
      { category: "tea-bag", name: "四季養生茶禮盒", price: "NT$1,680", priceNote: "4款各6包", desc: "四款草本風味，適合不同季節品飲。高級禮盒包裝，送禮首選。", badge: "禮盒" },
    ]
  },
  en: {
    // 英文產品資料
    categories: [
        { id: "tea-cake", name: "Tea cakes", icon: "🍵" },
        { id: "shampoo-bar", name: "Shampoo bars", icon: "🧼" },
        { id: "essential-oil", name: "Essential oils", icon: "💧" },
        { id: "tea-bag", name: "Herbal tea bags", icon: "🌿" },
      ],
      items: [
        { category: "tea-cake", name: "Yunnan Ancient Tree Pu'er Cake", price: "NT$1,280", priceNote: "357 g", desc: "Century-old tree leaves, hand-pressed. Rich aged aroma with sweet aftertaste. Perfect for collection.", badge: "Classic" },
        { category: "tea-cake", name: "Osmanthus Pu'er Mini Cake", price: "NT$680", priceNote: "200 g", desc: "Ripe Pu'er blended with natural osmanthus flowers. Sweet, smooth, and comforting.", badge: "Popular" },
        { category: "tea-cake", name: "Rose Flower Tea Cake", price: "NT$580", priceNote: "150 g", desc: "Damascus rose petals pressed with white tea. A floral blend for everyday tea drinking.", badge: "" },
        { category: "tea-cake", name: "Aged Tangerine White Tea Cake", price: "NT$880", priceNote: "300 g", desc: "Three-year aged tangerine peel with Fuding white tea. A mellow blend for a warm winter drink.", badge: "Recommended" },
        { category: "tea-cake", name: "Jasmine Dragon Pearl Gift Box", price: "NT$960", priceNote: "12 pearls", desc: "Hand-rolled pearls scented three times. Rich jasmine fragrance. Elegant gift packaging.", badge: "Gift set" },
        { category: "shampoo-bar", name: "He Shou Wu Hair Nourish Bar", price: "NT$480", priceNote: "80 g", desc: "He Shou Wu, Biota leaf & ginger extract. For everyday hair washing and scalp cleansing.", badge: "Bestseller" },
        { category: "shampoo-bar", name: "Tea Seed Oil Control Bar", price: "NT$420", priceNote: "80 g", desc: "Camellia seed oil deep cleanse with cooling mint. Ideal for oily scalp.", badge: "" },
        { category: "shampoo-bar", name: "Mugwort Purifying Bar", price: "NT$450", priceNote: "80 g", desc: "Aged mugwort & lavender oil. Herbal aroma for everyday scalp cleansing.", badge: "Recommended" },
        { category: "shampoo-bar", name: "Ginger Warming Bar", price: "NT$450", priceNote: "80 g", desc: "Old ginger essence warms scalp, with a warming sensation and herbal aroma for everyday washing.", badge: "" },
        { category: "essential-oil", name: "Head Therapy Blend Oil", price: "NT$1,680", priceNote: "30 ml", desc: "Lavender, rosemary, peppermint & geranium. A layered aromatic blend for head therapy.", badge: "Store selection" },
        { category: "essential-oil", name: "Sleep Well Essential Oil", price: "NT$1,280", priceNote: "15 ml", desc: "True lavender, Roman chamomile & bergamot. A gentle aroma for a relaxing home atmosphere.", badge: "Popular" },
        { category: "essential-oil", name: "Circulation Massage Oil", price: "NT$980", priceNote: "50 ml", desc: "Safflower, ligusticum & angelica infused oil. Sweet almond base. For home neck massage.", badge: "" },
        { category: "essential-oil", name: "Mugwort Diffuser Oil", price: "NT$780", priceNote: "15 ml", desc: "Pure steam-distilled mugwort oil. Use with diffuser to create a herbal atmosphere at home.", badge: "" },
        { category: "tea-bag", name: "Warming Qi Tea Gift Box", price: "NT$580", priceNote: "12 bags", desc: "Red date, goji, longan & astragalus. A warming herbal blend for everyday tea drinking.", badge: "Store selection" },
        { category: "tea-bag", name: "Calming Sleep Tea", price: "NT$680", priceNote: "15 bags", desc: "Jujube seed, poria, lily & licorice. An herbal blend to enjoy in the evening.", badge: "Bestseller" },
        { category: "tea-bag", name: "Beauty Bloom Tea", price: "NT$620", priceNote: "15 bags", desc: "Rose, salvia, red date & osmanthus. A floral herbal blend for everyday tea drinking.", badge: "" },
        { category: "tea-bag", name: "Liver Cleanse Eye Tea", price: "NT$560", priceNote: "15 bags", desc: "Chrysanthemum, cassia seed, goji & mulberry leaf. A refreshing herbal blend to enjoy during a break.", badge: "" },
        { category: "tea-bag", name: "Four Seasons Tea Gift set", price: "NT$1,680", priceNote: "4 types × 6 bags", desc: "Four herbal blends for different seasons. Premium gift box for all seasons.", badge: "Gift set" },
      ]
  }
};

// 占位圖生成 (配色同步為淺色系)
const PlaceholderImage = ({ category, index }) => {
  const palettes = {
    "tea-cake": { bg: "#e6dfd1", accent: "#a3823f", icon: "🍵" },
    "shampoo-bar": { bg: "#dee6e0", accent: "#7dab8e", icon: "🧼" },
    "essential-oil": { bg: "#e2e2eb", accent: "#8e7dab", icon: "💧" },
    "tea-bag": { bg: "#e8e1d5", accent: "#ab9a7d", icon: "🌿" },
  };
  const p = palettes[category] || palettes["tea-cake"];
  const patterns = [
    `radial-gradient(circle at 30% 40%, white, transparent 60%)`,
    `radial-gradient(circle at 70% 60%, white, transparent 50%)`,
    `linear-gradient(135deg, rgba(255,255,255,0.4), transparent)`,
  ];
  return (
    <div style={{
      width: "100%", aspectRatio: "1.2", background: p.bg,
      backgroundImage: patterns[index % 3],
      display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center",
      borderRadius: "4px 4px 0 0", position: "relative", overflow: "hidden"
    }}>
      <div style={{ fontSize: "56px", marginBottom: "8px", filter: "drop-shadow(0 2px 4px rgba(0,0,0,0.1))" }}>{p.icon}</div>
      <div style={{ fontSize: "10px", color: `${p.accent}`, letterSpacing: "3px", fontWeight: 600, opacity: 0.5 }}>ROU SPA</div>
    </div>
  );
};

// ============================================================
// Shop Component
// ============================================================
export default function Shop({ lang = "zh", onNavigateHome }) {
  const [activeCategory, setActiveCategory] = useState("all");
  const t = products[lang];

  const filteredItems = activeCategory === "all"
    ? t.items
    : t.items.filter(item => item.category === activeCategory);

  const isZh = lang === "zh";

  return (
    <div className="shop-page" style={{ fontFamily: "'Noto Serif TC', 'Noto Serif', Georgia, serif", color: "#4a443a", background: "#f2ede4", minHeight: "100vh" }}>
      <style>{`

        .shop-card {
          background: #fff; border: 1px solid rgba(163,130,63,0.12);
          border-radius: 4px; overflow: hidden; transition: all 0.4s ease;
          box-shadow: 0 4px 12px rgba(0,0,0,0.03);
        }
        .shop-card:hover {
          border-color: rgba(163,130,63,0.3); transform: translateY(-6px);
          box-shadow: 0 15px 35px rgba(163,130,63,0.1);
        }

        .cat-btn {
          padding: 10px 24px; border: 1px solid rgba(163,130,63,0.2); background: transparent;
          color: #4a443a; cursor: pointer; border-radius: 40px; font-family: inherit;
          font-size: 13px; letter-spacing: 1px; transition: all 0.3s; white-space: nowrap;
        }
        .cat-btn:hover { border-color: #a3823f; color: #a3823f; background: rgba(163,130,63,0.05); }
        .cat-btn.active { background: #a3823f; border-color: #a3823f; color: #f2ede4; box-shadow: 0 4px 12px rgba(163,130,63,0.2); }

        .back-btn {
          padding: 8px 20px; border: 1px solid rgba(163,130,63,0.3); background: transparent;
          color: #a3823f; cursor: pointer; border-radius: 4px; font-family: inherit;
          font-size: 13px; letter-spacing: 1px; transition: all 0.3s;
          display: flex; alignItems: center; gap: 8px;
        }
        .back-btn:hover { background: rgba(163,130,63,0.08); border-color: #a3823f; }

        .badge-tag {
          position: absolute; top: 12px; left: 12px; padding: 4px 12px; font-size: 10px;
          letter-spacing: 1px; border-radius: 4px; z-index: 2; font-weight: 600;
          box-shadow: 0 2px 8px rgba(0,0,0,0.05);
        }

        @keyframes shopFadeIn { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
        .shop-animate { animation: shopFadeIn 0.6s ease-out forwards; opacity: 0; }
      `}</style>

      {/* ===== NAV BAR ===== */}
      <nav className="public-page-nav" style={{
        position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
        background: "rgba(242, 237, 228, 0.95)", backdropFilter: "blur(20px)",
        borderBottom: "1px solid rgba(163,130,63,0.1)",
        padding: "16px 30px", display: "flex", justifyContent: "space-between", alignItems: "center"
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "16px" }}>
          <button className="public-brand-link" onClick={onNavigateHome} style={{ cursor: "pointer", display: "flex", alignItems: "center", gap: "12px" }}>
            <span style={{ fontSize: "18px", color: "#a3823f", letterSpacing: "4px", fontWeight: 700 }}>
              {isZh ? "柔療髮浴" : "ROU SPA"}
            </span>
          </button>
          <span style={{ color: "rgba(163,130,63,0.2)" }}>|</span>
          <span style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.6)", letterSpacing: "3px", fontWeight: 500 }}>
            {isZh ? "特色產品" : "Products"}
          </span>
        </div>
        <button className="back-btn" onClick={onNavigateHome}>
          {isZh ? "← 返回首頁" : "← Back"}
        </button>
      </nav>

      {/* ===== HERO ===== */}
      <div style={{
        paddingTop: "140px", paddingBottom: "80px", textAlign: "center",
        background: "linear-gradient(180deg, #f2ede4 0%, #e8e1d5 100%)",
        position: "relative", overflow: "hidden"
      }}>
        <div style={{
          position: "absolute", width: "600px", height: "600px", borderRadius: "50%",
          background: "radial-gradient(circle, rgba(163,130,63,0.06), transparent 70%)",
          top: "-200px", left: "50%", transform: "translateX(-50%)"
        }} />
        <div style={{ position: "relative", zIndex: 1, padding: "0 20px" }}>
          <div style={{ fontSize: "11px", letterSpacing: "6px", color: "#a3823f", marginBottom: "16px", fontWeight: 600 }}>
            COLLECTIONS
          </div>
          <h1 style={{
            fontSize: isZh ? "clamp(32px, 5vw, 48px)" : "clamp(28px, 4vw, 40px)",
            fontWeight: 500, letterSpacing: isZh ? "8px" : "3px",
            color: "#4a443a", marginBottom: "20px"
          }}>
            {isZh ? "柔療·好物選" : "Curated wellness"}
          </h1>
          <div style={{ width: "40px", height: "2px", background: "#a3823f", margin: "0 auto 24px" }} />
          <p style={{ fontSize: "14px", color: "rgba(74, 68, 58, 0.7)", letterSpacing: "1px", maxWidth: "600px", margin: "0 auto", lineHeight: 1.8 }}>
            {isZh
              ? "將柔療的舒緩時光延伸至居家生活。每一件產品，都承載著我們對東方智慧的體悟。"
              : "Extend the relaxing experience of our studio to your daily life. Every product carries our understanding of Eastern wisdom."}
          </p>
        </div>
      </div>

      {/* ===== CATEGORY TABS ===== */}
      <div style={{ maxWidth: "1200px", margin: "0 auto", padding: "0 30px" }}>
        <div style={{
          display: "flex", gap: "12px", flexWrap: "wrap", justifyContent: "center",
          marginBottom: "60px", paddingBottom: "10px"
        }}>
          <button
            className={`cat-btn ${activeCategory === "all" ? "active" : ""}`}
            onClick={() => setActiveCategory("all")}
          >
            {isZh ? "全部產品" : "All Products"}
          </button>
          {t.categories.map(cat => (
            <button
              key={cat.id}
              className={`cat-btn ${activeCategory === cat.id ? "active" : ""}`}
              onClick={() => setActiveCategory(cat.id)}
            >
              {cat.icon} {cat.name}
            </button>
          ))}
        </div>

        {/* ===== PRODUCT GRID ===== */}
        <div style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fill, minmax(min(280px, 100%), 1fr))",
          gap: "30px", paddingBottom: "100px"
        }}>
          {filteredItems.map((item, i) => (
            <div key={`${item.category}-${i}`} className="shop-card shop-animate" style={{ animationDelay: `${i * 0.08}s` }}>
              <div style={{ position: "relative" }}>
                <PlaceholderImage category={item.category} index={i} />
                {item.badge && (
                  <span className="badge-tag" style={{
                    background: item.badge.includes("店內") || item.badge.includes("In-Store") ? "#8fac50" : "#a3823f",
                    color: "white"
                  }}>
                    {item.badge}
                  </span>
                )}
              </div>
              <div style={{ padding: "24px" }}>
                <h3 style={{ fontSize: "16px", fontWeight: 600, color: "#4a443a", marginBottom: "8px", lineHeight: 1.4 }}>
                  {item.name}
                </h3>
                <p style={{ fontSize: "13px", lineHeight: 1.8, color: "rgba(74, 68, 58, 0.6)", marginBottom: "20px", minHeight: "60px" }}>
                  {item.desc}
                </p>
                <div style={{
                  display: "flex", justifyContent: "space-between", alignItems: "center",
                  borderTop: "1px solid rgba(163,130,63,0.1)", paddingTop: "18px"
                }}>
                  <div>
                    <div style={{ fontSize: "20px", color: "#a3823f", fontWeight: 700, fontFamily: "'Cormorant Garamond', serif" }}>
                      {item.price}
                    </div>
                    <div style={{ fontSize: "11px", color: "rgba(74, 68, 58, 0.4)", marginTop: "2px" }}>
                      {item.priceNote}
                    </div>
                  </div>
                  <div style={{
                    fontSize: "11px", color: "#a3823f", fontWeight: 600, letterSpacing: "1px",
                    padding: "6px 14px", border: "1px solid #a3823f", borderRadius: "4px"
                  }}>
                    {isZh ? "門市選購" : "In-Store"}
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>

        {/* ===== VISIT INFO ===== */}
        <div style={{
          textAlign: "center", padding: "80px 40px", marginBottom: "80px",
          background: "#fff", border: "1px solid rgba(163,130,63,0.1)",
          borderRadius: "8px", boxShadow: "0 10px 30px rgba(0,0,0,0.02)"
        }}>
          <div style={{ fontSize: "12px", letterSpacing: "4px", color: "#a3823f", marginBottom: "16px", fontWeight: 600 }}>
            {isZh ? "體驗與購買" : "EXPERIENCE & PURCHASE"}
          </div>
          <h3 style={{ fontSize: "24px", fontWeight: 500, letterSpacing: "4px", marginBottom: "24px", color: "#4a443a" }}>
            {isZh ? "親臨門市選購" : "Visit Our Store"}
          </h3>
          <p style={{ fontSize: "15px", color: "rgba(74, 68, 58, 0.7)", lineHeight: 2, maxWidth: "500px", margin: "0 auto" }}>
            {isZh
              ? "歡迎到門市了解產品與香氣，試用安排及供應情況請向門店詢問。"
              : "Explore our collection in store. Contact us about product availability and trial arrangements."}
          </p>
          <div style={{ marginTop: "30px", fontSize: "14px", color: "#a3823f", fontWeight: 500 }}>
            {isZh ? STORE.ADDRESS_ZH : STORE.ADDRESS_EN}
          </div>
        </div>
      </div>

      {/* ===== FOOTER ===== */}
      <footer style={{ padding: "60px 30px 40px", borderTop: "1px solid rgba(163,130,63,0.1)", textAlign: "center" }}>
        <div style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.4)", letterSpacing: "1px", fontWeight: 500 }}>
          © 2026 {isZh ? "柔療髮浴 版權所有" : "ROU SPA. All rights reserved."}
        </div>
      </footer>
    </div>
  );
}
