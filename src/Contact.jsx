import { useState } from "react";

const CONFIG = {
  ADDRESS_ZH: "台北市大安區敦化南路一段88號2樓",
  ADDRESS_EN: "2F, No.88, Sec.1, Dunhua S. Rd., Da'an Dist., Taipei",
  EMAIL: "rosa12345@gmail.com",
  PHONE: "02-2700-8888",
  // ⬇️ 后期填入真实链接
  LINE_URL: "https://line.me/R/ti/p/@YOUR_LINE_ID",
  LINE_ID: "@yourlineid",
  WECHAT_ID: "your_wechat_id",
  FACEBOOK_URL: "https://facebook.com/your_page",
  FACEBOOK_NAME: "柔禾養生 Rouhe Wellness",
};

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
    hoursDetail: "週二至週日 10:00 - 22:00（週一公休）",
    scanLine: "掃碼加好友",
    scanWechat: "掃碼加微信",
    visitFb: "前往粉絲專頁",
    sendEmail: "發送郵件",
    copyTip: "已複製",
    mapTitle: "如何到達",
    mrt: "🚇 捷運：大安站 4 號出口，步行約 5 分鐘",
  },
  en: {
    title: "Contact Us",
    subtitle: "CONTACT US",
    intro: "Reach out to us through any of the channels below for appointments or inquiries.",
    address: "Address",
    phone: "Phone",
    email: "Email",
    line: "LINE Official",
    wechat: "WeChat",
    facebook: "Facebook Page",
    hours: "Business Hours",
    hoursDetail: "Tue - Sun 10:00 AM - 10:00 PM (Closed on Mondays)",
    scanLine: "Scan to add",
    scanWechat: "Scan to add",
    visitFb: "Visit Page",
    sendEmail: "Send Email",
    copyTip: "Copied",
    mapTitle: "How to Get Here",
    mrt: "🚇 MRT: Da'an Station Exit 4, approx. 5 min walk",
  }
};

// QR code placeholder SVG
const QRPlaceholder = ({ label }) => (
  <div style={{
    width: "120px", height: "120px", background: "rgba(201,169,110,0.04)",
    border: "1px solid rgba(201,169,110,0.1)", borderRadius: "4px",
    display: "flex", flexDirection: "column", alignItems: "center", justifyContent: "center"
  }}>
    <div style={{ fontSize: "28px", marginBottom: "6px", opacity: 0.4 }}>📱</div>
    <div style={{ fontSize: "9px", color: "rgba(201,169,110,0.3)", letterSpacing: "1px" }}>{label}</div>
  </div>
);

export default function Contact({ lang = "zh", onNavigateHome }) {
  const [copied, setCopied] = useState("");
  const t = contactInfo[lang];
  const isZh = lang === "zh";

  const copyText = (text, label) => {
    navigator.clipboard?.writeText(text);
    setCopied(label);
    setTimeout(() => setCopied(""), 2000);
  };

  const ContactCard = ({ icon, label, value, subValue, action, actionLabel }) => (
    <div style={{
      background: "rgba(201,169,110,0.02)", border: "1px solid rgba(201,169,110,0.08)",
      borderRadius: "4px", padding: "24px", transition: "all 0.3s",
    }}
    onMouseEnter={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.2)"}
    onMouseLeave={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.08)"}
    >
      <div style={{ display: "flex", alignItems: "flex-start", gap: "16px" }}>
        <div style={{ fontSize: "24px", marginTop: "2px" }}>{icon}</div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: "11px", color: "rgba(201,169,110,0.4)", letterSpacing: "2px", marginBottom: "8px" }}>{label}</div>
          <div style={{ fontSize: "15px", fontWeight: 400, letterSpacing: "1px", marginBottom: subValue ? "4px" : "0", lineHeight: 1.6 }}>{value}</div>
          {subValue && <div style={{ fontSize: "12px", color: "rgba(232,224,208,0.35)", lineHeight: 1.6 }}>{subValue}</div>}
        </div>
        {action && (
          <button onClick={action} style={{
            padding: "6px 14px", fontSize: "11px", letterSpacing: "1px",
            background: "transparent", border: "1px solid rgba(201,169,110,0.15)",
            color: "rgba(201,169,110,0.6)", borderRadius: "2px", cursor: "pointer",
            fontFamily: "inherit", transition: "all 0.3s", whiteSpace: "nowrap"
          }}
          onMouseEnter={e => { e.target.style.borderColor = "#c9a96e"; e.target.style.color = "#c9a96e"; }}
          onMouseLeave={e => { e.target.style.borderColor = "rgba(201,169,110,0.15)"; e.target.style.color = "rgba(201,169,110,0.6)"; }}
          >
            {copied === label ? `✓ ${t.copyTip}` : actionLabel}
          </button>
        )}
      </div>
    </div>
  );

  return (
    <div style={{ fontFamily: "'Noto Serif TC', 'Noto Serif', Georgia, serif", color: "#e8e0d0", background: "#0a0a08", minHeight: "100vh" }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Serif+TC:wght@300;400;500;600;700&family=Cormorant+Garamond:ital,wght@0,300;0,400;0,500;0,600;1,300;1,400&display=swap');
        .back-btn {
          padding: 10px 24px; border: 1px solid rgba(201,169,110,0.15); background: transparent;
          color: rgba(201,169,110,0.6); cursor: pointer; border-radius: 3px; font-family: inherit;
          font-size: 13px; letter-spacing: 2px; transition: all 0.3s;
        }
        .back-btn:hover { border-color: #c9a96e; color: #c9a96e; }
        @keyframes contactFadeIn { from { opacity: 0; transform: translateY(16px); } to { opacity: 1; transform: translateY(0); } }
        .contact-animate { animation: contactFadeIn 0.5s ease-out forwards; opacity: 0; }
      `}</style>

      {/* NAV */}
      <nav style={{
        position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
        background: "rgba(10,10,8,0.95)", backdropFilter: "blur(20px)",
        borderBottom: "1px solid rgba(201,169,110,0.08)",
        padding: "16px 30px", display: "flex", justifyContent: "space-between", alignItems: "center"
      }}>
        <div style={{ display: "flex", alignItems: "center", gap: "16px" }}>
          <div onClick={onNavigateHome} style={{ cursor: "pointer" }}>
            <span style={{ fontSize: "18px", color: "#c9a96e", letterSpacing: "4px", fontWeight: 600 }}>
              {isZh ? "柔禾養生" : "ROUHE"}
            </span>
          </div>
          <span style={{ color: "rgba(201,169,110,0.2)" }}>|</span>
          <span style={{ fontSize: "13px", color: "rgba(201,169,110,0.5)", letterSpacing: "3px" }}>
            {t.title}
          </span>
        </div>
        <button className="back-btn" onClick={onNavigateHome}>
          ← {isZh ? "返回首頁" : "Back to Home"}
        </button>
      </nav>

      {/* HERO */}
      <div style={{
        paddingTop: "120px", paddingBottom: "50px", textAlign: "center",
        position: "relative", overflow: "hidden"
      }}>
        <div style={{
          position: "absolute", width: "350px", height: "350px", borderRadius: "50%",
          background: "radial-gradient(circle, rgba(201,169,110,0.03), transparent 70%)",
          top: "10px", left: "50%", transform: "translateX(-50%)"
        }} />
        <div style={{ position: "relative", zIndex: 1 }}>
          <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(201,169,110,0.4)", marginBottom: "16px" }}>
            {t.subtitle}
          </div>
          <h1 style={{
            fontSize: isZh ? "clamp(28px, 5vw, 40px)" : "clamp(26px, 4vw, 36px)",
            fontWeight: 300, letterSpacing: isZh ? "8px" : "3px",
            fontFamily: isZh ? "'Noto Serif TC', serif" : "'Cormorant Garamond', serif",
            marginBottom: "16px"
          }}>
            {t.title}
          </h1>
          <div style={{ width: "40px", height: "1px", background: "rgba(201,169,110,0.3)", margin: "0 auto 16px" }} />
          <p style={{ fontSize: "13px", color: "rgba(201,169,110,0.4)", letterSpacing: "2px", maxWidth: "460px", margin: "0 auto", lineHeight: 1.8 }}>
            {t.intro}
          </p>
        </div>
      </div>

      {/* CONTACT CARDS */}
      <div style={{ maxWidth: "720px", margin: "0 auto", padding: "0 24px" }}>
        <div style={{ display: "flex", flexDirection: "column", gap: "16px", marginBottom: "50px" }}>

          {/* Address */}
          <div className="contact-animate" style={{ animationDelay: "0.1s" }}>
            <ContactCard
              icon="📍" label={t.address}
              value={isZh ? CONFIG.ADDRESS_ZH : CONFIG.ADDRESS_EN}
              subValue={t.mrt}
              action={() => copyText(isZh ? CONFIG.ADDRESS_ZH : CONFIG.ADDRESS_EN, t.address)}
              actionLabel={isZh ? "複製地址" : "Copy"}
            />
          </div>

          {/* Hours */}
          <div className="contact-animate" style={{ animationDelay: "0.15s" }}>
            <ContactCard icon="🕐" label={t.hours} value={t.hoursDetail} />
          </div>

          {/* Phone */}
          <div className="contact-animate" style={{ animationDelay: "0.2s" }}>
            <ContactCard
              icon="📞" label={t.phone} value={CONFIG.PHONE}
              action={() => window.open(`tel:${CONFIG.PHONE.replace(/-/g, "")}`)}
              actionLabel={isZh ? "撥打電話" : "Call"}
            />
          </div>

          {/* Email */}
          <div className="contact-animate" style={{ animationDelay: "0.25s" }}>
            <ContactCard
              icon="✉️" label={t.email} value={CONFIG.EMAIL}
              action={() => window.open(`mailto:${CONFIG.EMAIL}`)}
              actionLabel={t.sendEmail}
            />
          </div>

          {/* LINE */}
          <div className="contact-animate" style={{ animationDelay: "0.3s" }}>
            <div style={{
              background: "rgba(201,169,110,0.02)", border: "1px solid rgba(201,169,110,0.08)",
              borderRadius: "4px", padding: "24px", transition: "all 0.3s",
            }}
            onMouseEnter={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.2)"}
            onMouseLeave={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.08)"}
            >
              <div style={{ display: "flex", alignItems: "flex-start", gap: "16px", flexWrap: "wrap" }}>
                <div style={{ fontSize: "24px", marginTop: "2px" }}>💬</div>
                <div style={{ flex: 1, minWidth: "180px" }}>
                  <div style={{ fontSize: "11px", color: "rgba(201,169,110,0.4)", letterSpacing: "2px", marginBottom: "8px" }}>{t.line}</div>
                  <div style={{ fontSize: "15px", fontWeight: 400, letterSpacing: "1px", marginBottom: "4px" }}>
                    LINE ID: <span style={{ color: "#06C755" }}>{CONFIG.LINE_ID}</span>
                  </div>
                  <div style={{ fontSize: "12px", color: "rgba(232,224,208,0.35)" }}>
                    {isZh ? "點擊右方按鈕或掃描 QR Code 加好友" : "Click button or scan QR code to add"}
                  </div>
                </div>
                <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "8px" }}>
                  <QRPlaceholder label={t.scanLine} />
                  <button onClick={() => window.open(CONFIG.LINE_URL)} style={{
                    padding: "6px 14px", fontSize: "11px", letterSpacing: "1px",
                    background: "rgba(6,199,85,0.1)", border: "1px solid rgba(6,199,85,0.25)",
                    color: "#06C755", borderRadius: "2px", cursor: "pointer", fontFamily: "inherit",
                  }}>
                    {isZh ? "加入好友" : "Add Friend"}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* WeChat */}
          <div className="contact-animate" style={{ animationDelay: "0.35s" }}>
            <div style={{
              background: "rgba(201,169,110,0.02)", border: "1px solid rgba(201,169,110,0.08)",
              borderRadius: "4px", padding: "24px", transition: "all 0.3s",
            }}
            onMouseEnter={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.2)"}
            onMouseLeave={e => e.currentTarget.style.borderColor = "rgba(201,169,110,0.08)"}
            >
              <div style={{ display: "flex", alignItems: "flex-start", gap: "16px", flexWrap: "wrap" }}>
                <div style={{ fontSize: "24px", marginTop: "2px" }}>🟢</div>
                <div style={{ flex: 1, minWidth: "180px" }}>
                  <div style={{ fontSize: "11px", color: "rgba(201,169,110,0.4)", letterSpacing: "2px", marginBottom: "8px" }}>{t.wechat}</div>
                  <div style={{ fontSize: "15px", fontWeight: 400, letterSpacing: "1px", marginBottom: "4px" }}>
                    {isZh ? "微信號" : "WeChat ID"}: <span style={{ color: "#07C160" }}>{CONFIG.WECHAT_ID}</span>
                  </div>
                  <div style={{ fontSize: "12px", color: "rgba(232,224,208,0.35)" }}>
                    {isZh ? "掃描 QR Code 或搜尋微信號添加" : "Scan QR code or search WeChat ID to add"}
                  </div>
                </div>
                <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "8px" }}>
                  <QRPlaceholder label={t.scanWechat} />
                  <button onClick={() => copyText(CONFIG.WECHAT_ID, t.wechat)} style={{
                    padding: "6px 14px", fontSize: "11px", letterSpacing: "1px",
                    background: "rgba(7,193,96,0.1)", border: "1px solid rgba(7,193,96,0.25)",
                    color: "#07C160", borderRadius: "2px", cursor: "pointer", fontFamily: "inherit",
                  }}>
                    {copied === t.wechat ? `✓ ${t.copyTip}` : (isZh ? "複製微信號" : "Copy ID")}
                  </button>
                </div>
              </div>
            </div>
          </div>

          {/* Facebook */}
          <div className="contact-animate" style={{ animationDelay: "0.4s" }}>
            <ContactCard
              icon="📘" label={t.facebook} value={CONFIG.FACEBOOK_NAME}
              subValue={CONFIG.FACEBOOK_URL.replace("https://", "")}
              action={() => window.open(CONFIG.FACEBOOK_URL)}
              actionLabel={t.visitFb}
            />
          </div>

        </div>

        {/* MAP SECTION */}
        <div className="contact-animate" style={{ animationDelay: "0.45s", marginBottom: "60px" }}>
          <div style={{ fontSize: "11px", letterSpacing: "4px", color: "rgba(201,169,110,0.4)", marginBottom: "16px", textAlign: "center" }}>
            {t.mapTitle}
          </div>
          <div style={{
            width: "100%", height: "300px", borderRadius: "4px", overflow: "hidden",
            border: "1px solid rgba(201,169,110,0.08)"
          }}>
            <iframe
              src="https://www.google.com/maps/embed?pb=!1m18!1m12!1m3!1d3615.0!2d121.5485!3d25.0418!2m3!1f0!2f0!3f0!3m2!1i1024!2i768!4f13.1!3m3!1m2!1s0x0%3A0x0!2zMjXCsDAyJzMwLjUiTiAxMjHCsDMyJzU0LjYiRQ!5e0!3m2!1szh-TW!2stw!4v1"
              width="100%" height="100%" style={{ border: 0, filter: "invert(90%) hue-rotate(180deg) brightness(0.8) contrast(1.1)" }}
              allowFullScreen="" loading="lazy"
            />
          </div>
          <div style={{ textAlign: "center", marginTop: "12px", fontSize: "12px", color: "rgba(201,169,110,0.3)" }}>
            {isZh ? "※ 正式地址確認後將更新地圖定位" : "※ Map location will be updated once address is confirmed"}
          </div>
        </div>
      </div>

      {/* FOOTER */}
      <footer style={{ padding: "40px 30px", borderTop: "1px solid rgba(201,169,110,0.06)", textAlign: "center" }}>
        <div style={{ fontSize: "11px", color: "rgba(232,224,208,0.15)", letterSpacing: "1px" }}>
          © 2026 {isZh ? "柔禾養生 版權所有" : "Rouhe Wellness. All Rights Reserved."}
        </div>
      </footer>
    </div>
  );
}
