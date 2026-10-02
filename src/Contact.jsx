import { useState, useEffect } from "react";
import { STORE, hoursText } from "./lib/public-copy.js";
import { rpc } from "./lib/spa.js";

// ============================================================
// 聯繫資訊配置
// ============================================================
const CONFIG = STORE;

const contactInfo = {
  zh: {
    title: "聯繫我們",
    subtitle: "CONTACT US",
    intro: "歡迎透過以下方式與我們聯繫，預約諮詢或了解更多服務內容。",
    address: "門市地址",
    phone: "聯繫電話",
    email: "電子郵件",
    line: "LINE 官方帳號",
    wechat: "微信",
    facebook: "Facebook 粉絲專頁",
    hours: "營業時間",
    visitFb: "前往粉絲專頁",
    sendEmail: "發送郵件",
    copyTip: "已複製",
    mapTitle: "交通位置",
  },
  en: {
    title: "Contact us",
    subtitle: "CONTACT US",
    intro: "Reach out to us through any of the channels below for appointments or inquiries.",
    address: "Address",
    phone: "Phone",
    email: "Email",
    line: "Official LINE account",
    wechat: "WeChat",
    facebook: "Facebook page",
    hours: "Opening hours",
    visitFb: "Visit page",
    sendEmail: "Send email",
    copyTip: "Copied",
    mapTitle: "Find us",
  }
};

export default function Contact({ lang = "zh", onNavigateHome }) {
  const [copied, setCopied] = useState("");
  const [copyError, setCopyError] = useState("");
  const [settings, setSettings] = useState(null);
  useEffect(() => { let live = true; rpc("spa_catalog").then(c => { if(live) setSettings(c.settings); }).catch(() => {}); return () => { live = false; }; }, []);
  const t = contactInfo[lang];
  const isZh = lang === "zh";

  const copyText = async (text, label) => {
    setCopyError('');
    try { await navigator.clipboard.writeText(text); setCopied(label); setTimeout(() => setCopied(''), 2000); }
    catch { setCopyError(isZh ? '複製未成功，請手動選取並複製。' : 'Could not copy. Please select and copy the text manually.'); }
  };

  const ContactCard = ({ icon, label, value, subValue, action, actionLabel }) => (
    <div style={{
      background: "#ffffff", border: "1px solid rgba(163,130,63,0.15)",
      borderRadius: "4px", padding: "24px", transition: "all 0.3s",
      boxShadow: "0 4px 12px rgba(0,0,0,0.03)"
    }}
    onMouseEnter={e => {
        e.currentTarget.style.borderColor = "rgba(163,130,63,0.4)";
        e.currentTarget.style.boxShadow = "0 8px 20px rgba(163,130,63,0.08)";
    }}
    onMouseLeave={e => {
        e.currentTarget.style.borderColor = "rgba(163,130,63,0.15)";
        e.currentTarget.style.boxShadow = "0 4px 12px rgba(0,0,0,0.03)";
    }}
    >
      <div className="contact-card-row" style={{ display: "flex", alignItems: "flex-start", gap: "16px" }}>
        <div style={{ fontSize: "24px", marginTop: "2px" }}>{icon}</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontSize: "11px", color: "#a3823f", letterSpacing: "2px", marginBottom: "8px", fontWeight: 600 }}>{label}</div>
          <div style={{ fontSize: "15px", fontWeight: 500, color: "#4a443a", letterSpacing: "1px", marginBottom: subValue ? "4px" : "0", lineHeight: 1.6 }}>{value}</div>
          {subValue && <div style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.5)", lineHeight: 1.6 }}>{subValue}</div>}
        </div>
        {action && (
          <button onClick={action} style={{
            padding: "8px 16px", fontSize: "11px", letterSpacing: "1px",
            background: "transparent", border: "1px solid rgba(163,130,63,0.3)",
            color: "#a3823f", borderRadius: "4px", cursor: "pointer",
            fontFamily: "inherit", transition: "all 0.3s", whiteSpace: "nowrap",
            fontWeight: 600
          }}
          onMouseEnter={e => { e.target.style.background = "rgba(163,130,63,0.05)"; e.target.style.borderColor = "#a3823f"; }}
          onMouseLeave={e => { e.target.style.background = "transparent"; e.target.style.borderColor = "rgba(163,130,63,0.3)"; }}
          >
            {copied === label ? `✓ ${t.copyTip}` : actionLabel}
          </button>
        )}
      </div>
    </div>
  );

  return (
    <div className="contact-page" style={{ fontFamily: "'Noto Serif TC', 'Noto Serif', Georgia, serif", color: "#4a443a", background: "#f2ede4", minHeight: "100vh" }}>
      <style>{`
        
        .back-btn {
          padding: 8px 20px; border: 1px solid rgba(163,130,63,0.3); background: transparent;
          color: #a3823f; cursor: pointer; border-radius: 4px; font-family: inherit;
          font-size: 13px; letter-spacing: 1px; transition: all 0.3s;
          display: flex; align-items: center; gap: 8px; font-weight: 500;
        }
        .back-btn:hover { background: rgba(163,130,63,0.08); border-color: #a3823f; }

        @keyframes contactFadeIn { from { opacity: 0; transform: translateY(16px); } to { opacity: 1; transform: translateY(0); } }
        .contact-animate { animation: contactFadeIn 0.5s ease-out forwards; opacity: 0; }
      `}</style>

      {/* NAV */}
      <nav className="public-page-nav" style={{
        position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
        background: "rgba(242, 237, 228, 0.95)", backdropFilter: "blur(20px)",
        borderBottom: "1px solid rgba(163,130,63,0.1)",
        padding: "16px 30px", display: "flex", justifyContent: "space-between", alignItems: "center"
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "16px" }}>
          <button className="public-brand-link" onClick={onNavigateHome} style={{ cursor: "pointer" }}>
            <span style={{ fontSize: "18px", color: "#a3823f", letterSpacing: "4px", fontWeight: 700 }}>
              {isZh ? "柔療髮浴" : "ROU SPA"}
            </span>
          </button>
          <span style={{ color: "rgba(163,130,63,0.2)" }}>|</span>
          <span style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.6)", letterSpacing: "3px", fontWeight: 500 }}>
            {t.title}
          </span>
        </div>
        <button className="back-btn" onClick={onNavigateHome}>
          {isZh ? "← 返回首頁" : "← Back"}
        </button>
      </nav>

      {/* HERO */}
      <div style={{
        paddingTop: "140px", paddingBottom: "60px", textAlign: "center",
        position: "relative", overflow: "hidden"
      }}>
        <div style={{
          position: "absolute", width: "400px", height: "400px", borderRadius: "50%",
          background: "radial-gradient(circle, rgba(163,130,63,0.06), transparent 70%)",
          top: "10px", left: "50%", transform: "translateX(-50%)"
        }} />
        <div style={{ position: "relative", zIndex: 1 }}>
          <div style={{ fontSize: "11px", letterSpacing: "6px", color: "#a3823f", marginBottom: "16px", fontWeight: 600 }}>
            {t.subtitle}
          </div>
          <h1 style={{
            fontSize: isZh ? "clamp(28px, 5vw, 40px)" : "clamp(26px, 4vw, 36px)",
            fontWeight: 500, letterSpacing: isZh ? "8px" : "3px",
            color: "#4a443a", marginBottom: "16px"
          }}>
            {t.title}
          </h1>
          <div style={{ width: "40px", height: "2px", background: "#a3823f", margin: "0 auto 20px" }} />
          <p style={{ fontSize: "14px", color: "rgba(74, 68, 58, 0.7)", letterSpacing: "1px", maxWidth: "480px", margin: "0 auto", lineHeight: 1.8 }}>
            {t.intro}
          </p>
        </div>
      </div>

      {/* CONTACT CARDS */}
      <div style={{ maxWidth: "760px", margin: "0 auto", padding: "0 24px" }}>
        <div style={{ display: "flex", flexDirection: "column", gap: "16px", marginBottom: "50px" }}>

          <div className="contact-animate" style={{ animationDelay: "0.1s" }}>
            <ContactCard
              icon="📍" label={t.address}
              value={isZh ? CONFIG.ADDRESS_ZH : CONFIG.ADDRESS_EN}
              subValue={isZh ? "出發前可透過 LINE 詢問交通資訊。" : "Contact us on LINE for directions before your visit."}
              action={() => copyText(isZh ? CONFIG.ADDRESS_ZH : CONFIG.ADDRESS_EN, t.address)}
              actionLabel={isZh ? "複製地址" : "Copy"}
            />
          </div>

          <div className="contact-animate" style={{ animationDelay: "0.15s" }}>
            <ContactCard icon="🕐" label={t.hours} value={hoursText(settings, lang)} />
          </div>

          <div className="contact-animate" style={{ animationDelay: "0.2s" }}>
            <ContactCard
              icon="📞" label={t.phone} value={CONFIG.PHONE}
              action={() => window.location.assign(`tel:${CONFIG.PHONE.replace(/-/g, "")}`)}
              actionLabel={isZh ? "撥打電話" : "Call"}
            />
          </div>

          <div className="contact-animate" style={{ animationDelay: "0.25s" }}>
            <ContactCard
              icon="✉️" label={t.email} value={CONFIG.EMAIL}
              action={() => window.location.assign(`mailto:${CONFIG.EMAIL}`)}
              actionLabel={t.sendEmail}
            />
          </div>

          {/* LINE Card (Special Styled) */}
          <div className="contact-animate" style={{ animationDelay: "0.3s" }}>
            <div style={{
              background: "#ffffff", border: "1px solid rgba(163,130,63,0.15)",
              borderRadius: "4px", padding: "24px", transition: "all 0.3s",
              boxShadow: "0 4px 12px rgba(0,0,0,0.03)"
            }}>
              <div style={{ display: "flex", alignItems: "flex-start", gap: "16px", flexWrap: "wrap" }}>
                <div style={{ fontSize: "24px", marginTop: "2px" }}>💬</div>
                <div style={{ flex: 1, minWidth: "min(200px, 100%)" }}>
                  <div style={{ fontSize: "11px", color: "#a3823f", letterSpacing: "2px", marginBottom: "8px", fontWeight: 600 }}>{t.line}</div>
                  <div style={{ fontSize: "16px", fontWeight: 500, letterSpacing: "1px", marginBottom: "6px", color: "#4a443a" }}>
                    LINE ID: <span style={{ color: "#06C755", fontWeight: 700 }}>{CONFIG.LINE_ID}</span>
                  </div>
                  <div style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.5)", lineHeight: 1.6 }}>
                    {isZh ? "點擊下方按鈕，加入 LINE 官方帳號。" : "Use the button below to add our official LINE account."}
                  </div>
                </div>
                <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "12px" }}>
                  <button onClick={() => window.open(CONFIG.LINE_URL, "_blank", "noopener,noreferrer")} style={{
                    padding: "8px 20px", fontSize: "12px", letterSpacing: "1px",
                    background: "#06C755", border: "none",
                    color: "white", borderRadius: "4px", cursor: "pointer", fontFamily: "inherit",
                    fontWeight: 600, boxShadow: "0 4px 10px rgba(6,199,85,0.2)"
                  }}>
                    {isZh ? "加入 LINE 好友" : "Add on LINE"}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* WeChat Card (Special Styled) */}
          {CONFIG.WECHAT_ID && <div className="contact-animate" style={{ animationDelay: "0.35s" }}>
            <div style={{
              background: "#ffffff", border: "1px solid rgba(163,130,63,0.15)",
              borderRadius: "4px", padding: "24px", transition: "all 0.3s",
              boxShadow: "0 4px 12px rgba(0,0,0,0.03)"
            }}>
              <div style={{ display: "flex", alignItems: "flex-start", gap: "16px", flexWrap: "wrap" }}>
                <div style={{ fontSize: "24px", marginTop: "2px" }}>🟢</div>
                <div style={{ flex: 1, minWidth: "min(200px, 100%)" }}>
                  <div style={{ fontSize: "11px", color: "#a3823f", letterSpacing: "2px", marginBottom: "8px", fontWeight: 600 }}>{t.wechat}</div>
                  <div style={{ fontSize: "16px", fontWeight: 500, letterSpacing: "1px", marginBottom: "6px", color: "#4a443a" }}>
                    {isZh ? "微信號" : "WeChat ID"}: <span style={{ color: "#07C160", fontWeight: 700 }}>{CONFIG.WECHAT_ID}</span>
                  </div>
                  <div style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.5)", lineHeight: 1.6 }}>
                    {isZh ? "搜尋微信號加入聯絡人。" : "Search the WeChat ID to add us."}
                  </div>
                </div>
                <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "12px" }}>
                  <button onClick={() => copyText(CONFIG.WECHAT_ID, t.wechat)} style={{
                    padding: "8px 20px", fontSize: "12px", letterSpacing: "1px",
                    background: "#07C160", border: "none",
                    color: "white", borderRadius: "4px", cursor: "pointer", fontFamily: "inherit",
                    fontWeight: 600, boxShadow: "0 4px 10px rgba(7,193,96,0.2)"
                  }}>
                    {copied === t.wechat ? `✓ ${t.copyTip}` : (isZh ? "複製微信號" : "Copy ID")}
                  </button>
                </div>
              </div>
            </div>
          </div>}

          {CONFIG.FACEBOOK_URL && <div className="contact-animate" style={{ animationDelay: "0.4s" }}>
            <ContactCard
              icon="📘" label={t.facebook} value={CONFIG.FACEBOOK_NAME}
              subValue={CONFIG.FACEBOOK_URL.replace("https://", "")}
              action={() => window.open(CONFIG.FACEBOOK_URL, "_blank", "noopener,noreferrer")}
              actionLabel={t.visitFb}
            />
          </div>}

        </div>
        {copyError && <p role="alert">{copyError}</p>}

        {/* MAP SECTION */}
        <div className="contact-animate" style={{ animationDelay: "0.45s", marginBottom: "100px" }}>
          <div style={{ fontSize: "12px", letterSpacing: "4px", color: "#a3823f", marginBottom: "20px", textAlign: "center", fontWeight: 600 }}>
            {t.mapTitle}
          </div>
          <div style={{
            width: "100%", height: "360px", borderRadius: "8px", overflow: "hidden",
            border: "1px solid rgba(163,130,63,0.2)", boxShadow: "0 10px 30px rgba(0,0,0,0.05)"
          }}>
            <iframe
              title={isZh ? "門市位置地圖" : "Store location map"}
              src={`https://www.google.com/maps?q=${encodeURIComponent(CONFIG.ADDRESS_ZH)}&output=embed`}
              width="100%" height="100%" style={{ border: 0, filter: "sepia(20%) contrast(1.1) brightness(1.05)" }}
              allowFullScreen="" loading="lazy"
            />
          </div>
          <div style={{ textAlign: "center", marginTop: "16px", fontSize: "13px", color: "rgba(74, 68, 58, 0.5)", fontWeight: 500 }}>
            <a href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(CONFIG.ADDRESS_ZH)}`} target="_blank" rel="noopener noreferrer" style={{ color: "#80622d", display: "inline-flex", alignItems: "center", minHeight: "44px" }}>{isZh ? "在 Google Maps 開啟門市位置 ↗" : "Open store location in Google Maps ↗"}</a>
          </div>
        </div>
      </div>

      {/* FOOTER */}
      <footer style={{ padding: "60px 30px 40px", borderTop: "1px solid rgba(163,130,63,0.1)", textAlign: "center" }}>
        <div style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.4)", letterSpacing: "1px", fontWeight: 500 }}>
          © 2026 {isZh ? "柔療髮浴 版權所有" : "ROU SPA. All rights reserved."}
        </div>
      </footer>
    </div>
  );
}
