import { useMemo, useState } from "react";
import { STORE } from "./lib/public-copy.js";
import { money } from "./lib/spa.js";
import { productPresentationMark } from "./lib/catalog-presentation.js";
import { usePublicData } from './lib/usePublicData.js';

function ProductArtwork({ product, category, lang }) {
  const icon = productPresentationMark(product, category, lang);
  return <div className="product-artwork">
    {product.image_url && <img src={product.image_url} alt={lang === "en" ? product.name_en || product.name : product.name} loading="lazy" decoding="async" width="600" height="480" style={{width:"100%",height:"100%",objectFit:"cover",position:"absolute",inset:0}} />}
    {!product.image_url && <><span>{icon}</span><small>ROU SPA</small></>}
  </div>;
}

export default function Shop({ lang = "zh", onNavigateHome }) {
  const { data: catalog, error } = usePublicData('spa_store_catalog', { lang, scopes: ['catalog'] });
  const [activeCategory,setActiveCategory]=useState("all");
  const isZh=lang==="zh";
  const categories=catalog?.categories||[],allProducts=catalog?.products||[];
  const products=useMemo(()=>allProducts.filter(p=>activeCategory==="all"||p.category_id===activeCategory),[allProducts,activeCategory]);
  const zeroBehavior=catalog?.settings?.zero_stock_behavior||"sold_out";
  const visible=products.filter(p=>zeroBehavior!=="hide"||Number(p.inventory)>0);
  const name=(row)=>isZh?row.name:(row.name_en||row.name);
  const description=(row)=>isZh?row.description:(row.description_en||row.description);
  return <div className="shop-page">
    <style>{`
      .shop-page{font-family:var(--public-font);color:#4a443a;background:#f2ede4;min-height:100vh}
      .shop-nav{position:fixed;inset:0 0 auto;z-index:100;background:rgba(242,237,228,.96);backdrop-filter:blur(20px);border-bottom:1px solid rgba(163,130,63,.14);padding:14px clamp(16px,4vw,30px);display:flex;justify-content:space-between;align-items:center;gap:16px}
      .shop-brand{display:flex;align-items:center;gap:14px;min-width:0;border:0;background:transparent;padding:0;cursor:pointer;font:inherit;text-decoration:none}.shop-brand strong{color:#8b6a31;letter-spacing:3px;font-size:17px}.shop-brand span{font-size:12px;letter-spacing:2px;color:#746b5d}
      .shop-back{min-height:44px;padding:8px 16px;border:1px solid rgba(163,130,63,.35);background:transparent;color:#85662f;border-radius:6px;cursor:pointer;font:inherit;text-decoration:none;display:inline-flex;align-items:center}
      .shop-hero{padding:142px 24px 68px;text-align:center;background:linear-gradient(180deg,#f2ede4,#e8e1d5)}.shop-hero small{letter-spacing:6px;color:#9a793e}.shop-hero h1{font-size:clamp(30px,5vw,46px);font-weight:500;letter-spacing:6px;margin:18px 0}.shop-hero p{max-width:620px;margin:auto;line-height:1.9;color:#6c6458}
      .shop-main{max-width:1200px;margin:auto;padding:48px 24px 100px}.category-tabs{display:flex;gap:10px;overflow:auto;padding:0 0 18px;margin-bottom:36px;justify-content:center}.category-tabs button{white-space:nowrap;min-height:44px;padding:8px 20px;border:1px solid rgba(163,130,63,.24);background:transparent;border-radius:30px;color:#4a443a;font:inherit;cursor:pointer}.category-tabs button.active{background:#9a793e;color:#fff}
      .product-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(260px,100%),1fr));gap:24px}.product-card{background:#fff;border:1px solid rgba(163,130,63,.13);border-radius:10px;overflow:hidden;box-shadow:0 8px 24px rgba(74,55,29,.05)}
      .product-artwork{aspect-ratio:1.25;background:#e5ded1 center/cover no-repeat;display:grid;place-items:center;color:#9a793e;position:relative}.product-artwork span{font-size:44px;border:1px solid rgba(154,121,62,.45);width:84px;height:84px;border-radius:50%;display:grid;place-items:center}.product-artwork small{position:absolute;bottom:18px;letter-spacing:3px}
      .product-copy{padding:22px}.product-copy h2{font-size:18px;font-weight:600;line-height:1.45;margin-bottom:8px}.product-copy p{font-size:13px;line-height:1.75;color:#746b5d;min-height:68px}.product-meta{border-top:1px solid #eee5d8;margin-top:18px;padding-top:16px;display:flex;justify-content:space-between;gap:12px;align-items:end}.product-price{font-family:'Cormorant Garamond',serif;color:#8b6a31;font-size:22px;font-weight:700}.product-unit{font-size:11px;color:#867c6c}.stock{font-size:12px;padding:5px 9px;border-radius:20px;background:#eff5ec;color:#51714d}.stock.out{background:#f1ece7;color:#8a6d5b}
      .shop-state{padding:44px;text-align:center;background:#fff;border:1px solid #e5dac7;border-radius:10px}.shop-visit{text-align:center;margin-top:70px;padding:54px 24px;background:#fff;border-radius:10px}.shop-visit p{line-height:1.8}.shop-visit a{color:#80622d}
      @media(max-width:640px){.shop-brand span{display:none}.shop-hero{padding-top:120px}.category-tabs{justify-content:flex-start}.product-copy p{min-height:0}}
    `}</style>
    <nav className="shop-nav">
      <a href="/" className="public-brand-link shop-brand" onClick={event=>{event.preventDefault();onNavigateHome();}}><strong>{isZh?"柔療髮浴":"ROU SPA"}</strong><span>{isZh?"特色產品":"Products"}</span></a>
      <a href="/" className="shop-back" onClick={event=>{event.preventDefault();onNavigateHome();}}>{isZh?"← 返回首頁":"← Back"}</a>
    </nav>
    <header className="shop-hero"><small>COLLECTIONS</small><h1>{isZh?"柔療·好物選":"Curated wellness"}</h1><p>{isZh?"把柔和的養護帶回日常，探索門店精選好物。查看目前價格與供貨狀態，歡迎到店選購。":"Bring gentle care into your daily routine. Explore our curated products and view current store pricing and availability."}</p></header>
    <main className="shop-main">
      {error&&<div className="shop-state" role="alert">{error}</div>}
      {!catalog&&!error&&<div className="shop-state">{isZh?"正在載入商品…":"Loading products…"}</div>}
      {catalog&&<>
        <div className="category-tabs" role="tablist" aria-label={isZh?"商品分類":"Product categories"}>
          <button className={activeCategory==="all"?"active":""} onClick={()=>setActiveCategory("all")}>{isZh?"全部產品":"All products"}</button>
          {categories.map(c=><button key={c.id} className={activeCategory===c.id?"active":""} onClick={()=>setActiveCategory(c.id)}>{name(c)}</button>)}
        </div>
        {!visible.length&&<div className="shop-state">{isZh?"此分類目前沒有上架商品。":"No published products in this category."}</div>}
        <div className="product-grid">{visible.map(p=>{const category=categories.find(c=>c.id===p.category_id),soldOut=Number(p.inventory)<=0;return <article className="product-card" key={p.id}>
          <ProductArtwork product={p} category={category} lang={lang}/><div className="product-copy"><h2>{name(p)}</h2><p>{description(p)}</p><div className="product-meta"><div><div className="product-price">{money(p.price_cents)}</div><div className="product-unit">{isZh?p.unit_label:(p.unit_label_en||p.unit_label)}</div></div><span className={`stock ${soldOut?'out':''}`}>{soldOut?(isZh?"售罄":"Sold out"):(isZh?"門市有貨":"In stock")}</span></div></div>
        </article>})}</div>
      </>}
      <section className="shop-visit"><h2>{isZh?"歡迎到店選購":"Available in store"}</h2><p>{isZh?STORE.ADDRESS_ZH:STORE.ADDRESS_EN}<br/><a href={`tel:${STORE.PHONE}`}>{STORE.PHONE}</a></p></section>
    </main>
  </div>;
}
