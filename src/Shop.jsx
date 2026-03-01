import { useState } from "react";

// ============================================================
// 产品数据
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
      // 茶饼
      { category: "tea-cake", name: "雲南古樹普洱茶餅", price: "NT$1,280", priceNote: "357g / 餅", desc: "精選百年古樹茶菁，傳統手工壓製，陳香醇厚，回甘悠長。適合收藏與日常品飲。", badge: "經典" },
      { category: "tea-cake", name: "桂花普洱小茶餅", price: "NT$680", priceNote: "200g / 餅", desc: "普洱熟茶搭配天然桂花，花香與茶韻交融，甜潤順口，午後療癒首選。", badge: "人氣" },
      { category: "tea-cake", name: "玫瑰花茶餅", price: "NT$580", priceNote: "150g / 餅", desc: "大馬士革玫瑰花瓣與白茶壓製，疏肝理氣，養顏美容，適合女性養生。", badge: "" },
      { category: "tea-cake", name: "陳皮老白茶餅", price: "NT$880", priceNote: "300g / 餅", desc: "三年陳皮搭配福鼎老白茶，潤肺化痰，暖胃安神，冬日暖飲佳品。", badge: "推薦" },
      { category: "tea-cake", name: "茉莉龍珠禮盒", price: "NT$960", priceNote: "12顆入 / 盒", desc: "手工搓揉成珠，三次窨花，茉莉花香馥郁。精緻禮盒，送禮自用皆宜。", badge: "禮盒" },
      // 洗头饼
      { category: "shampoo-bar", name: "何首烏養髮洗頭餅", price: "NT$480", priceNote: "80g / 顆", desc: "何首烏、側柏葉、生薑萃取，強健髮根，烏黑亮麗。無矽靈、無化學添加。", badge: "明星" },
      { category: "shampoo-bar", name: "茶籽控油洗頭餅", price: "NT$420", priceNote: "80g / 顆", desc: "苦茶籽油深層清潔，薄荷涼感控油，適合油性頭皮。天然植萃配方。", badge: "" },
      { category: "shampoo-bar", name: "艾草淨化洗頭餅", price: "NT$450", priceNote: "80g / 顆", desc: "陳年艾草、薰衣草精油，淨化頭皮，舒緩敏感。經期與產後調理推薦。", badge: "推薦" },
      { category: "shampoo-bar", name: "生薑暖養洗頭餅", price: "NT$450", priceNote: "80g / 顆", desc: "老薑精華溫暖頭皮，促進循環，改善掉髮。搭配頭療效果加倍。", badge: "" },
      // 精油
      { category: "essential-oil", name: "頭療專用複方精油", price: "NT$1,680", priceNote: "30ml", desc: "薰衣草、迷迭香、薄荷、天竺葵調配，疏通經絡，舒緩頭痛。店內同款。", badge: "店內同款" },
      { category: "essential-oil", name: "安神助眠精油", price: "NT$1,280", priceNote: "15ml", desc: "真正薰衣草、羅馬洋甘菊、佛手柑，滴於枕邊或擴香，一夜好眠。", badge: "人氣" },
      { category: "essential-oil", name: "活血通絡按摩油", price: "NT$980", priceNote: "50ml", desc: "紅花、川芎、當歸浸泡油，搭配甜杏仁基底油，居家肩頸按摩適用。", badge: "" },
      { category: "essential-oil", name: "艾草薰香精油", price: "NT$780", priceNote: "15ml", desc: "純天然艾草蒸餾精油，搭配擴香儀使用，淨化空間，驅寒祛濕。", badge: "" },
      // 养生茶包
      { category: "tea-bag", name: "養生暖身茶（禮盒）", price: "NT$580", priceNote: "12包入", desc: "紅棗、枸杞、桂圓、黃耆，溫補氣血。與店內基礎茶飲同款配方。", badge: "店內同款" },
      { category: "tea-bag", name: "漢方安神茶", price: "NT$680", priceNote: "15包入", desc: "酸棗仁、茯苓、百合、甘草，寧心安神。睡前一杯，改善睡眠品質。", badge: "熱銷" },
      { category: "tea-bag", name: "活血美人茶", price: "NT$620", priceNote: "15包入", desc: "玫瑰、丹參、紅棗、桂花，活血養顏。每日一杯，由內而外的美麗。", badge: "" },
      { category: "tea-bag", name: "清肝明目茶", price: "NT$560", priceNote: "15包入", desc: "菊花、決明子、枸杞、桑葉，清肝火護眼。上班族與3C族必備。", badge: "" },
      { category: "tea-bag", name: "四季養生茶禮盒", price: "NT$1,680", priceNote: "4款各6包", desc: "春養肝、夏清心、秋潤肺、冬暖腎，四季各一款。高級禮盒包裝，送禮首選。", badge: "禮盒" },
    ]
  },
  en: {
    categories: [
      { id: "tea-cake", name: "Tea Cakes", icon: "🍵" },
      { id: "shampoo-bar", name: "Shampoo Bars", icon: "🧼" },
      { id: "essential-oil", name: "Essential Oils", icon: "💧" },
      { id: "tea-bag", name: "Herbal Tea Bags", icon: "🌿" },
    ],
    items: [
      // Tea cakes
      { category: "tea-cake", name: "Yunnan Ancient Tree Pu'er Cake", price: "NT$1,280", priceNote: "357g", desc: "Century-old tree leaves, hand-pressed. Rich aged aroma with sweet aftertaste. Perfect for collection.", badge: "Classic" },
      { category: "tea-cake", name: "Osmanthus Pu'er Mini Cake", price: "NT$680", priceNote: "200g", desc: "Ripe Pu'er blended with natural osmanthus flowers. Sweet, smooth, and comforting.", badge: "Popular" },
      { category: "tea-cake", name: "Rose Flower Tea Cake", price: "NT$580", priceNote: "150g", desc: "Damascus rose petals pressed with white tea. Soothes liver Qi, nourishes skin.", badge: "" },
      { category: "tea-cake", name: "Aged Tangerine White Tea Cake", price: "NT$880", priceNote: "300g", desc: "Three-year aged tangerine peel with Fuding white tea. Warms stomach, calms mind.", badge: "Recommended" },
      { category: "tea-cake", name: "Jasmine Dragon Pearl Gift Box", price: "NT$960", priceNote: "12 pearls", desc: "Hand-rolled pearls scented three times. Rich jasmine fragrance. Elegant gift packaging.", badge: "Gift Set" },
      // Shampoo bars
      { category: "shampoo-bar", name: "He Shou Wu Hair Nourish Bar", price: "NT$480", priceNote: "80g", desc: "He Shou Wu, Biota leaf & ginger extract. Strengthens roots, promotes dark luster. Silicone-free.", badge: "Bestseller" },
      { category: "shampoo-bar", name: "Tea Seed Oil Control Bar", price: "NT$420", priceNote: "80g", desc: "Camellia seed oil deep cleanse with cooling mint. Ideal for oily scalp.", badge: "" },
      { category: "shampoo-bar", name: "Mugwort Purifying Bar", price: "NT$450", priceNote: "80g", desc: "Aged mugwort & lavender oil. Purifies scalp, soothes sensitivity. Great for postpartum care.", badge: "Recommended" },
      { category: "shampoo-bar", name: "Ginger Warming Bar", price: "NT$450", priceNote: "80g", desc: "Old ginger essence warms scalp, boosts circulation, reduces hair loss. Pairs with head therapy.", badge: "" },
      // Essential oils
      { category: "essential-oil", name: "Head Therapy Blend Oil", price: "NT$1,680", priceNote: "30ml", desc: "Lavender, rosemary, peppermint & geranium. Unblocks meridians, relieves headaches. Same as in-store.", badge: "In-Store Formula" },
      { category: "essential-oil", name: "Sleep Well Essential Oil", price: "NT$1,280", priceNote: "15ml", desc: "True lavender, Roman chamomile & bergamot. Drop on pillow or diffuse for deep sleep.", badge: "Popular" },
      { category: "essential-oil", name: "Circulation Massage Oil", price: "NT$980", priceNote: "50ml", desc: "Safflower, ligusticum & angelica infused oil. Sweet almond base. For home neck massage.", badge: "" },
      { category: "essential-oil", name: "Mugwort Diffuser Oil", price: "NT$780", priceNote: "15ml", desc: "Pure steam-distilled mugwort oil. Use with diffuser to purify space and dispel dampness.", badge: "" },
      // Tea bags
      { category: "tea-bag", name: "Warming Qi Tea Gift Box", price: "NT$580", priceNote: "12 bags", desc: "Red date, goji, longan & astragalus. Same formula as our complimentary in-store tea.", badge: "In-Store Formula" },
      { category: "tea-bag", name: "Calming Sleep Tea", price: "NT$680", priceNote: "15 bags", desc: "Jujube seed, poria, lily & licorice. A cup before bed for improved sleep quality.", badge: "Bestseller" },
      { category: "tea-bag", name: "Beauty Bloom Tea", price: "NT$620", priceNote: "15 bags", desc: "Rose, salvia, red date & osmanthus. Promotes circulation for radiant beauty from within.", badge: "" },
      { category: "tea-bag", name: "Liver Cleanse Eye Tea", price: "NT$560", priceNote: "15 bags", desc: "Chrysanthemum, cassia seed, goji & mulberry leaf. Essential for screen-heavy lifestyles.", badge: "" },
      { category: "tea-bag", name: "Four Seasons Tea Gift Set", price: "NT$1,680", priceNote: "4 types × 6 bags", desc: "Spring liver, summer heart, autumn lung, winter kidney. Premium gift box for all seasons.", badge: "Gift Set" },
    ]
  }
};

// 占位图生成（SVG）
const PlaceholderImage = ({ category, index }) => {
  const palettes = {
    "tea-cake": { bg: "#2a1f14", accent: "#c9a96e", icon: "🍵" },
    "shampoo-bar": { bg: "#1a2420", accent: "#7dab8e", icon: "🧼" },
    "essential-oil": { bg: "#1a1a28", accent: "#8e7dab", icon: "💧" },
    "tea-bag": { bg: "#28221a", accent: "#ab9a7d", icon: "🌿" },
  };
  const p = palettes[category] || palettes["tea-cake"];
  const patterns = [
    `radial-gradient(circle at 30% 40%, ${p.accent}15, transparent 60%)`,
    `radial-gradient(circle at 70% 60%, ${p.accent}12, transparent 50%)`,
    `linear-gradient(135deg, ${p.accent}08, transparent, ${p.accent}05)`,
  ];
  return (
    <div style={{
      width: "100%", aspectRatio: "1", background: p.bg,
      backgroundImage: patterns[index % 3],
      display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center",
      borderRadius: "4px 4px 0 0", position: "relative", overflow: "hidden"
    }}>
      <div style={{ fontSize: "48px", marginBottom: "8px", opacity: 0.6 }}>{p.icon}</div>
      <div style={{ fontSize: "10px", color: `${p.accent}60`, letterSpacing: "3px" }}>ROUHE</div>
      {/* decorative circle */}
      <div style={{
        position: "absolute", width: "120px", height: "120px", borderRadius: "50%",
        border: `1px solid ${p.accent}15`, top: "15%", right: "-20px"
      }} />
      <div style={{
        position: "absolute", width: "80px", height: "80px", borderRadius: "50%",
        border: `1px solid ${p.accent}10`, bottom: "10%", left: "-15px"
      }} />
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
    <div style={{ fontFamily: "'Noto Serif TC', 'Noto Serif', Georgia, serif", color: "#e8e0d0", background: "#0a0a08", minHeight: "100vh" }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Serif+TC:wght@300;400;500;600;700&family=Cormorant+Garamond:ital,wght@0,300;0,400;0,500;0,600;1,300;1,400&display=swap');
        .shop-card { 
          background: rgba(201,169,110,0.02); border: 1px solid rgba(201,169,110,0.08); 
          border-radius: 4px; overflow: hidden; transition: all 0.4s ease;
        }
        .shop-card:hover { 
          border-color: rgba(201,169,110,0.2); transform: translateY(-4px);
          box-shadow: 0 12px 40px rgba(0,0,0,0.3);
        }
        .cat-btn {
          padding: 10px 20px; border: 1px solid rgba(201,169,110,0.12); background: transparent;
          color: rgba(201,169,110,0.5); cursor: pointer; border-radius: 3px; font-family: inherit;
          font-size: 13px; letter-spacing: 2px; transition: all 0.3s; white-space: nowrap;
        }
        .cat-btn:hover { border-color: rgba(201,169,110,0.3); color: #c9a96e; }
        .cat-btn.active { background: rgba(201,169,110,0.1); border-color: #c9a96e; color: #c9a96e; }
        .back-btn {
          padding: 10px 24px; border: 1px solid rgba(201,169,110,0.15); background: transparent;
          color: rgba(201,169,110,0.6); cursor: pointer; border-radius: 3px; font-family: inherit;
          font-size: 13px; letter-spacing: 2px; transition: all 0.3s;
        }
        .back-btn:hover { border-color: #c9a96e; color: #c9a96e; }
        .badge-tag {
          position: absolute; top: 12px; left: 12px; padding: 4px 10px; font-size: 10px;
          letter-spacing: 1px; border-radius: 2px; z-index: 2;
        }
        @keyframes shopFadeIn { from { opacity: 0; transform: translateY(20px); } to { opacity: 1; transform: translateY(0); } }
        .shop-animate { animation: shopFadeIn 0.6s ease-out forwards; opacity: 0; }
      `}</style>

      {/* ===== NAV BAR ===== */}
      <nav style={{
        position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
        background: "rgba(10,10,8,0.95)", backdropFilter: "blur(20px)",
        borderBottom: "1px solid rgba(201,169,110,0.08)",
        padding: "16px 30px", display: "flex", justifyContent: "space-between", alignItems: "center"
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "16px" }}>
          <div onClick={onNavigateHome} style={{ cursor: "pointer", display: "flex", alignItems: "center", gap: "12px" }}>
            <span style={{ fontSize: "18px", color: "#c9a96e", letterSpacing: "4px", fontWeight: 600 }}>
              {isZh ? "柔禾養生" : "ROUHE"}
            </span>
          </div>
          <span style={{ color: "rgba(201,169,110,0.2)" }}>|</span>
          <span style={{ fontSize: "13px", color: "rgba(201,169,110,0.5)", letterSpacing: "3px" }}>
            {isZh ? "特色產品" : "Products"}
          </span>
        </div>
        <button className="back-btn" onClick={onNavigateHome}>
          ← {isZh ? "返回首頁" : "Back to Home"}
        </button>
      </nav>

      {/* ===== HERO ===== */}
      <div style={{
        paddingTop: "120px", paddingBottom: "60px", textAlign: "center",
        background: "linear-gradient(180deg, rgba(10,10,8,1) 0%, rgba(15,13,10,1) 100%)",
        position: "relative", overflow: "hidden"
      }}>
        <div style={{
          position: "absolute", width: "400px", height: "400px", borderRadius: "50%",
          background: "radial-gradient(circle, rgba(201,169,110,0.03), transparent 70%)",
          top: "0", left: "50%", transform: "translateX(-50%)"
        }} />
        <div style={{ position: "relative", zIndex: 1 }}>
          <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(201,169,110,0.4)", marginBottom: "16px" }}>
            SHOP
          </div>
          <h1 style={{
            fontSize: isZh ? "clamp(28px, 5vw, 42px)" : "clamp(26px, 4vw, 38px)",
            fontWeight: 300, letterSpacing: isZh ? "8px" : "3px",
            fontFamily: isZh ? "'Noto Serif TC', serif" : "'Cormorant Garamond', serif",
            marginBottom: "16px"
          }}>
            {isZh ? "特色產品" : "Curated Products"}
          </h1>
          <div style={{ width: "40px", height: "1px", background: "rgba(201,169,110,0.3)", margin: "0 auto 16px" }} />
          <p style={{ fontSize: "13px", color: "rgba(201,169,110,0.4)", letterSpacing: "2px", maxWidth: "500px", margin: "0 auto", lineHeight: 1.8 }}>
            {isZh 
              ? "源自養生堂的精選好物，將東方智慧帶回日常。歡迎蒞臨門市選購。" 
              : "Curated wellness essentials from our studio. Bring Eastern wisdom home. Available in-store."}
          </p>
        </div>
      </div>

      {/* ===== CATEGORY TABS ===== */}
      <div style={{ maxWidth: "1200px", margin: "0 auto", padding: "0 30px" }}>
        <div style={{
          display: "flex", gap: "10px", flexWrap: "wrap", justifyContent: "center",
          marginBottom: "50px", paddingBottom: "30px",
          borderBottom: "1px solid rgba(201,169,110,0.06)"
        }}>
          <button 
            className={`cat-btn ${activeCategory === "all" ? "active" : ""}`}
            onClick={() => setActiveCategory("all")}
          >
            {isZh ? "全部" : "All"}
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
          gridTemplateColumns: "repeat(auto-fill, minmax(260px, 1fr))",
          gap: "24px", paddingBottom: "80px"
        }}>
          {filteredItems.map((item, i) => (
            <div key={`${item.category}-${i}`} className="shop-card shop-animate" style={{ animationDelay: `${i * 0.08}s` }}>
              {/* Image */}
              <div style={{ position: "relative" }}>
                <PlaceholderImage category={item.category} index={i} />
                {item.badge && (
                  <span className="badge-tag" style={{
                    background: item.badge.includes("禮盒") || item.badge.includes("Gift") 
                      ? "rgba(201,169,110,0.15)" 
                      : item.badge.includes("店內") || item.badge.includes("In-Store")
                        ? "rgba(107,142,35,0.15)"
                        : "rgba(201,169,110,0.1)",
                    color: item.badge.includes("店內") || item.badge.includes("In-Store") ? "#8fac50" : "#c9a96e",
                    border: `1px solid ${item.badge.includes("店內") || item.badge.includes("In-Store") ? "rgba(107,142,35,0.25)" : "rgba(201,169,110,0.2)"}`
                  }}>
                    {item.badge}
                  </span>
                )}
              </div>
              {/* Info */}
              <div style={{ padding: "20px" }}>
                <h3 style={{ fontSize: "15px", fontWeight: 500, letterSpacing: "1px", marginBottom: "6px", lineHeight: 1.5 }}>
                  {item.name}
                </h3>
                <p style={{ fontSize: "12px", lineHeight: 1.8, color: "rgba(232,224,208,0.35)", marginBottom: "16px", minHeight: "58px" }}>
                  {item.desc}
                </p>
                <div style={{
                  display: "flex", justifyContent: "space-between", alignItems: "flex-end",
                  borderTop: "1px solid rgba(201,169,110,0.06)", paddingTop: "14px"
                }}>
                  <div>
                    <div style={{ fontSize: "18px", color: "#c9a96e", fontFamily: "'Cormorant Garamond', serif", fontWeight: 600, letterSpacing: "1px" }}>
                      {item.price}
                    </div>
                    <div style={{ fontSize: "10px", color: "rgba(201,169,110,0.3)", marginTop: "2px" }}>
                      {item.priceNote}
                    </div>
                  </div>
                  <div style={{
                    fontSize: "10px", color: "rgba(201,169,110,0.4)", letterSpacing: "1px",
                    padding: "6px 12px", border: "1px solid rgba(201,169,110,0.1)", borderRadius: "2px"
                  }}>
                    {isZh ? "門市選購" : "In-Store"}
                  </div>
                </div>
              </div>
            </div>
          ))}
        </div>

        {/* ===== STORE INFO ===== */}
        <div style={{
          textAlign: "center", padding: "60px 20px", marginBottom: "40px",
          background: "rgba(201,169,110,0.02)", border: "1px solid rgba(201,169,110,0.06)",
          borderRadius: "6px"
        }}>
          <div style={{ fontSize: "11px", letterSpacing: "4px", color: "rgba(201,169,110,0.4)", marginBottom: "14px" }}>
            {isZh ? "歡迎蒞臨選購" : "VISIT US IN-STORE"}
          </div>
          <h3 style={{ fontSize: "20px", fontWeight: 400, letterSpacing: "4px", marginBottom: "20px", color: "#c9a96e" }}>
            {isZh ? "柔禾養生" : "Rouhe Wellness"}
          </h3>
          <p style={{ fontSize: "13px", color: "rgba(232,224,208,0.4)", lineHeight: 2, maxWidth: "400px", margin: "0 auto" }}>
            {isZh
              ? "所有產品皆可於門市親自體驗與選購\n享受專業諮詢與試用服務"
              : "All products available for experience and purchase in-store\nEnjoy professional consultation and sampling"}
          </p>
          <div style={{ marginTop: "20px", fontSize: "13px", color: "rgba(201,169,110,0.5)", letterSpacing: "1px" }}>
            {isZh ? "營業時間：週二至週日 10:00 - 22:00" : "Hours: Tue - Sun 10:00 AM - 10:00 PM"}
          </div>
        </div>
      </div>

      {/* ===== FOOTER ===== */}
      <footer style={{ padding: "40px 30px", borderTop: "1px solid rgba(201,169,110,0.06)", textAlign: "center" }}>
        <div style={{ fontSize: "11px", color: "rgba(232,224,208,0.15)", letterSpacing: "1px" }}>
          © 2026 {isZh ? "柔禾養生 版權所有" : "Rouhe Wellness. All Rights Reserved."}
        </div>
      </footer>
    </div>
  );
}
