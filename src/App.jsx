import { useState, useEffect, useRef } from "react";

// ============================================================
// 🔧 CONFIGURATION
// ============================================================
const CONFIG = {
  SUPABASE_URL: "https://etiggwqxacnlrgokfsjt.supabase.co/",
  SUPABASE_ANON_KEY: "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImV0aWdnd3F4YWNubHJnb2tmc2p0Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzIzNjk0ODgsImV4cCI6MjA4Nzk0NTQ4OH0.Wqjn6rZJfwCAfTr7L0XdPh1U1hNzJYjjYSt1YASH5uw",
  LINE_URL: "https://line.me/R/ti/p/@258llual",
  DOMAIN: "https://rouspa.tw",
  PHONE: "0978-918-737",
  ADDRESS_ZH: "嘉義市西區蘭井街421號",
  ADDRESS_EN: "No.421, Lanjing St., West Dist., Chiayi City",
};

const i18n = {
  zh: {
    brand: "柔療髮浴",
    brandEn: "ROU SPA",
    brandSub: "東方頭療・經絡養生",
    nav: { home: "首頁", services: "服務項目", booking: "立即預約", shop: "特色產品", contact: "聯繫我們" },
    hero: {
      title: "以柔養生",
      subtitle: "源自千年中醫智慧的頭部經絡調理",
      desc: "柔療髮浴以傳統中醫理論為根基，融合現代養生手法，為您開啟身心療癒之旅。疏通頭部經絡，調和氣血，讓身心回歸自然平衡。",
      cta: "預約體驗"
    },
    services: {
      title: "養生項目",
      subtitle: "精選調理 · 身心合一",
      items: [
        { name: "經典頭療", duration: "60分鐘", price: "NT$1,800", desc: "運用傳統中醫推拿手法，疏通頭部十二經絡，緩解頭痛、失眠、壓力，恢復氣血暢通。", icon: "☯" },
        { name: "御方草本頭療", duration: "90分鐘", price: "NT$2,800", desc: "嚴選十八味漢方草本精華，搭配熱敷薰蒸與穴位按摩，深層滋養頭皮，養髮固本。", icon: "🌿" },
        { name: "艾灸通絡頭療", duration: "75分鐘", price: "NT$2,200", desc: "以陳年艾草溫灸百會、太陽等要穴，溫經散寒，祛濕排毒，改善頭部循環。", icon: "🔥" },
        { name: "全息頭部SPA", duration: "120分鐘", price: "NT$3,800", desc: "結合頭部刮痧、耳燭、面部撥筋與肩頸調理，從頭到肩全方位深度放鬆與修復。", icon: "✨" }
      ]
    },
    team: {
      members: [
        { name: "林雅芳", title: "首席調理師", exp: "15年經驗", specialty: "經絡調理 · 艾灸養生", desc: "師承中醫名家，精通頭部經絡與穴位調理，擅長針對性調理方案。" },
        { name: "陳柏翰", title: "資深調理師", exp: "12年經驗", specialty: "草本頭療 · 刮痧排毒", desc: "深研漢方草本學，獨創御方頭療配方，深受顧客好評。" },
        { name: "王詩涵", title: "調理師", exp: "8年經驗", specialty: "全息SPA · 肩頸調理", desc: "手法細膩溫柔，擅長全身經絡疏通，讓您在寧靜中找回平衡。" },
        { name: "張家豪", title: "調理師", exp: "6年經驗", specialty: "頭部推拿 · 穴位按摩", desc: "力道精準到位，專注於頭部深層放鬆，有效改善睡眠品質。" },
        { name: "李靜怡", title: "調理師", exp: "5年經驗", specialty: "芳香療法 · 淋巴排毒", desc: "專精精油調配與淋巴引流手法，結合東西方療癒智慧。" },
        { name: "吳俊霖", title: "調理師", exp: "4年經驗", specialty: "經絡推拿 · 拔罐理療", desc: "嫻熟傳統推拿技法，擅長針對肩頸腰背痠痛調理。" }
      ]
    },
    booking: {
      title: "預約調理",
      subtitle: "開啟您的養生之旅",
      steps: ["選擇服務", "選擇技師", "選擇時段", "選擇茶飲", "確認預約"],
      selectService: "請選擇服務項目",
      selectTherapist: "請選擇技師",
      anyTherapist: "不指定技師",
      selectDate: "選擇日期",
      selectTime: "選擇時段",
      name: "姓名",
      phone: "手機號碼",
      note: "備註（選填）",
      next: "下一步",
      prev: "上一步",
      confirm: "確認預約",
      success: "預約成功！",
      successSub: "我們將盡快與您確認預約時間",
      successLine: "加入 LINE 官方帳號，即時接收預約確認與專屬優惠",
      addLine: "加入 LINE",
      morning: "上午",
      afternoon: "下午",
      evening: "晚間",
      submitting: "預約中...",
      selectTea: "療程搭配養生茶飲",
      teaIncluded: "基礎茶飲（免費）",
      teaUpgrade: "升級精選茶飲",
      teaNote: "每位貴賓皆享一杯養生茶飲，可免費選擇基礎款或加價升級"
    },
    tea: {
      items: [
        { name: "養生暖身茶", price: "免費", priceNum: 0, desc: "紅棗枸杞桂圓茶，溫補氣血，療程基本搭配。", icon: "🍵", tag: "基礎" },
        { name: "漢方安神茶", price: "+NT$120", priceNum: 120, desc: "酸棗仁、茯苓、百合，寧心安神，適合失眠困擾者。", icon: "🌙", tag: "升級" },
        { name: "活血通絡茶", price: "+NT$150", priceNum: 150, desc: "丹參、川芎、玫瑰花，活血化瘀，促進循環。", icon: "🌺", tag: "升級" },
        { name: "清肝明目茶", price: "+NT$120", priceNum: 120, desc: "菊花、決明子、枸杞，清肝火、護眼明目。", icon: "🌼", tag: "升級" },
        { name: "養顏美肌茶", price: "+NT$180", priceNum: 180, desc: "雪耳、桃膠、紅棗、玫瑰，膠質滿滿，養顏潤膚。", icon: "🌸", tag: "人氣" }
      ]
    },
    feedback: {
      eyebrow: "FEEDBACK",
      title: "您的反饋，能讓我們更好",
      placeholder: "柔療需要改進的地方",
      submit: "送出",
      sending: "傳送中...",
      thanks: "謝謝您的寶貴意見，我們會持續改善。",
      tooShort: "請再多寫幾個字，讓我們更清楚。",
      tooFast: "請稍候片刻再送出。",
      limit: "今日的意見我們已收到，感謝您的用心。",
      failed: "送出失敗，請稍後再試。"
    },
    footer: {
      address: CONFIG.ADDRESS_ZH,
      hours: "營業時間：10:00 - 02:00（全年無休）",
      phone: CONFIG.PHONE,
      copyright: "© 2026 柔療髮浴 版權所有"
    },
    line: { tooltip: "LINE 諮詢" },
    langSwitch: "EN"
  },
  en: {
      // (保持原本的英文翻譯不變)
      brand: "ROU SPA",
      brandEn: "ROU SPA",
      brandSub: "Oriental Head Therapy · Meridian Wellness",
      nav: { home: "Home", services: "Services", booking: "Book Now", shop: "Products", contact: "Contact" },
      hero: {
        title: "Gentle\nWellness",
        subtitle: "Ancient Chinese Medicine Wisdom for Modern Healing",
        desc: "Rooted in Traditional Chinese Medicine, Rou Spa's head therapy harmonizes Qi and blood flow, guiding you on a journey of holistic healing and deep relaxation.",
        cta: "Book Now"
      },
      services: {
        title: "Services",
        subtitle: "Curated Therapies · Mind & Body Unity",
        items: [
          { name: "Classic Head Therapy", duration: "60 min", price: "NT$1,800", desc: "Traditional TCM massage techniques to unblock head meridians, relieve headaches, insomnia, and stress.", icon: "☯" },
          { name: "Herbal Head Therapy", duration: "90 min", price: "NT$2,800", desc: "Premium herbal essence blend with hot compress and acupoint massage for deep scalp nourishment.", icon: "🌿" },
          { name: "Moxibustion Therapy", duration: "75 min", price: "NT$2,200", desc: "Aged moxa warming of Baihui and Taiyang points to dispel cold, remove dampness, and improve circulation.", icon: "🔥" },
          { name: "Holistic Head SPA", duration: "120 min", price: "NT$3,800", desc: "Full spectrum treatment combining Gua Sha, ear candling, facial meridian work, and shoulder therapy.", icon: "✨" }
        ]
      },
      team: {
        members: [
          { name: "Lin Ya-Fang", title: "Chief Therapist", exp: "15 Years", specialty: "Meridian Therapy · Moxibustion", desc: "Trained under renowned TCM masters, expert in head meridian and acupoint therapy." },
          { name: "Chen Bo-Han", title: "Senior Therapist", exp: "12 Years", specialty: "Herbal Therapy · Gua Sha", desc: "Deep expertise in herbal formulations, creator of our signature herbal blend." },
          { name: "Wang Shi-Han", title: "Therapist", exp: "8 Years", specialty: "Holistic SPA · Shoulder Care", desc: "Gentle and precise technique, specializing in full-body meridian harmony." },
          { name: "Zhang Jia-Hao", title: "Therapist", exp: "6 Years", specialty: "Head Massage · Acupoint Work", desc: "Precise pressure control, focused on deep head relaxation and sleep improvement." }
        ]
      },
      booking: {
        title: "Book Appointment",
        subtitle: "Begin Your Wellness Journey",
        steps: ["Select Service", "Select Therapist", "Select Time", "Select Tea", "Confirm"],
        selectService: "Choose a service",
        selectTherapist: "Choose a therapist",
        anyTherapist: "No Preference",
        selectDate: "Select Date",
        selectTime: "Select Time",
        name: "Full Name",
        phone: "Phone Number",
        note: "Notes (Optional)",
        next: "Next",
        prev: "Back",
        confirm: "Confirm Booking",
        success: "Booking Confirmed!",
        successSub: "We will contact you shortly to confirm your appointment.",
        successLine: "Follow our LINE account for instant booking confirmation & exclusive offers.",
        addLine: "Add LINE",
        morning: "Morning",
        afternoon: "Afternoon",
        evening: "Evening",
        submitting: "Submitting...",
        selectTea: "Pair Your Therapy with Herbal Tea",
        teaIncluded: "Complimentary Tea",
        teaUpgrade: "Premium Tea Upgrade",
        teaNote: "Every guest enjoys one herbal tea — choose complimentary or upgrade"
      },
      tea: {
        items: [
          { name: "Warming Qi Tea", price: "Free", priceNum: 0, desc: "Red date, goji & longan blend. Warms and nourishes Qi.", icon: "🍵", tag: "Basic" },
          { name: "Calming Sleep Tea", price: "+NT$120", priceNum: 120, desc: "Jujube seed, poria & lily. Soothes the mind for better sleep.", icon: "🌙", tag: "Upgrade" },
          { name: "Circulation Boost Tea", price: "+NT$150", priceNum: 150, desc: "Salvia, ligusticum & rose. Promotes blood flow and vitality.", icon: "🌺", tag: "Upgrade" },
          { name: "Liver Cleanse Tea", price: "+NT$120", priceNum: 120, desc: "Chrysanthemum, cassia seed & goji. Clears liver heat, protects eyes.", icon: "🌼", tag: "Upgrade" },
          { name: "Beauty Glow Tea", price: "+NT$180", priceNum: 180, desc: "Snow fungus, peach gum, rose & red date. Collagen-rich skin nourishment.", icon: "🌸", tag: "Popular" }
        ]
      },
      feedback: {
        eyebrow: "FEEDBACK",
        title: "Your Feedback Helps Us Grow",
        placeholder: "What could Rou Spa do better?",
        submit: "Send",
        sending: "Sending...",
        thanks: "Thank you for your thoughts — we will keep improving.",
        tooShort: "Please write a little more so we understand.",
        tooFast: "Please wait a moment before sending.",
        limit: "We have received your notes for today. Thank you.",
        failed: "Could not send. Please try again later."
      },
      footer: {
        address: CONFIG.ADDRESS_EN,
        hours: "Hours: 10:00 AM - 2:00 AM (Open Daily)",
        phone: CONFIG.PHONE,
        copyright: "© 2026 Rou Spa. All Rights Reserved."
      },
      line: { tooltip: "LINE Chat" },
      langSwitch: "中文"
  }
};

async function submitBooking(data) {
  try {
    const res = await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/bookings`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: CONFIG.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
        Prefer: "return=representation",
      },
      body: JSON.stringify(data),
    });
    if (!res.ok) {
      const errBody = await res.text();
      if (errBody.includes("duplicate") || errBody.includes("unique")) {
        return { success: false, error: "slot_taken" };
      }
      throw new Error(`HTTP ${res.status}`);
    }
    return { success: true };
  } catch (err) {
    console.error("Booking submission failed:", err);
    return { success: false, error: err.message };
  }
}

// ============================================================
// 匿名意見回饋：只寫入、不讀取，前台永遠不顯示任何留言
// ============================================================
const FEEDBACK_MIN_LEN = 5;
const FEEDBACK_MAX_LEN = 500;
const FEEDBACK_MIN_DWELL_MS = 3000;   // 進入區塊後至少停留 3 秒才可送出
const FEEDBACK_COOLDOWN_MS = 60000;   // 兩則留言間隔至少 60 秒
const FEEDBACK_DAILY_LIMIT = 5;       // 同一裝置每日上限
const FEEDBACK_GUARD_KEY = "rouspa_fb_guard";

// 頻率限制只記在本機，不帶任何身分資訊，維持完全匿名
function readFeedbackGuard() {
  try {
    const g = JSON.parse(localStorage.getItem(FEEDBACK_GUARD_KEY) || "{}");
    return { day: g.day || "", count: g.count || 0, last: g.last || 0 };
  } catch {
    return { day: "", count: 0, last: 0 };
  }
}

function writeFeedbackGuard(guard) {
  try {
    localStorage.setItem(FEEDBACK_GUARD_KEY, JSON.stringify(guard));
  } catch {
    /* 無痕模式下略過 */
  }
}

function todayKey() {
  const d = new Date();
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

async function submitFeedback(message) {
  try {
    const base = CONFIG.SUPABASE_URL.replace(/\/+$/, "");
    const res = await fetch(`${base}/rest/v1/feedback`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: CONFIG.SUPABASE_ANON_KEY,
        Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
        Prefer: "return=minimal", // 不回傳資料，前台無從讀取任何留言
      },
      body: JSON.stringify({ message }),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return { success: true };
  } catch (err) {
    console.error("Feedback submission failed:", err);
    return { success: false };
  }
}

async function fetchBookedSlots(date) {
  try {
    const res = await fetch(
      `${CONFIG.SUPABASE_URL}/rest/v1/rpc/get_all_booked_slots`,
      {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          apikey: CONFIG.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
        },
        body: JSON.stringify({ p_date: date }),
      }
    );
    if (!res.ok) return {};
    const rows = await res.json();
    const map = {};
    rows.forEach((r) => {
      if (!map[r.therapist_index]) map[r.therapist_index] = new Set();
      map[r.therapist_index].add(r.booking_time);
    });
    return map;
  } catch (err) {
    console.error("Failed to fetch booked slots:", err);
    return {};
  }
}

const SealLogo = ({ size = 44, variant = "mark" }) => (
  <img
    src={variant === "hero" ? "/logo-hero-white.png" : "/logo-mark.png"}
    alt="柔療髮浴 ROU SPA"
    style={{
      height: size, width: "auto", maxWidth: "100%", objectFit: "contain",
      display: "block", userSelect: "none",
      // 米白色實心字在淺色 hero 背景上，用雙層暗影提升可讀性（不更動背景）
      filter: variant === "hero"
        ? "drop-shadow(0 1px 2px rgba(58,44,18,0.55)) drop-shadow(0 3px 14px rgba(70,56,28,0.45))"
        : "none"
    }}
    draggable={false}
  />
);

// 圓圈章印（清・養・通）+ 展開式方子卡片
function FormulaCard({ stamp, name, sub, steps, isOpen, onEnter, onLeave, onToggle, variant = "v90" }) {
  return (
    <div
      className={`service-card formula-card ${variant} ${isOpen ? "open" : ""}`}
      onMouseEnter={onEnter}
      onMouseLeave={onLeave}
      onClick={onToggle}
    >
      <div className="formula-head">
        {stamp && (
          <span className={`seal-stamp seal-${variant}`}>
            <span className="seal-char">{stamp}</span>
          </span>
        )}
        <div className={stamp ? "formula-title" : "formula-title formula-title-center"}>
          <span className="formula-name">{name}</span>
          {sub && <span className="formula-sub">{sub}</span>}
        </div>
        <span className="formula-toggle">⌄</span>
      </div>
      <div className="formula-body">
        <div className="formula-inner">
          <div className="formula-steps">
            {steps.map((s, i) => (
              <span key={i} className="formula-step">{s}</span>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

const LineIcon = () => (
  <svg width="28" height="28" viewBox="0 0 24 24" fill="white">
    <path d="M12 2C6.48 2 2 5.82 2 10.5c0 2.95 1.95 5.55 4.86 7.17-.19.66-.68 2.46-.78 2.84-.13.49.18.48.38.35.15-.1 2.44-1.66 3.44-2.34.7.1 1.4.15 2.1.15 5.52 0 10-3.82 10-8.5S17.52 2 12 2zm-3.5 11h-2a.75.75 0 01-.75-.75v-4a.75.75 0 011.5 0v3.25H8.5a.75.75 0 010 1.5zm2.25-.75a.75.75 0 01-1.5 0v-4a.75.75 0 011.5 0v4zm4.25.75h-.1a.75.75 0 01-.6-.33L12.5 9.92v2.33a.75.75 0 01-1.5 0v-4c0-.33.22-.63.53-.72.31-.1.65.02.82.3L14.15 10.58V8.25a.75.75 0 011.5 0v4a.75.75 0 01-.65.75zm3.25-1.25h-1.5v.5a.75.75 0 01-1.5 0v-4a.75.75 0 01.75-.75h2.25a.75.75 0 010 1.5h-1.5v.75h1.5a.75.75 0 010 1.5z" />
  </svg>
);

const GoldDivider = () => (
  <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: "16px", margin: "20px 0" }}>
    <div style={{ width: "60px", height: "1px", background: "linear-gradient(to right, transparent, #a3823f)" }} />
    <div style={{ color: "#a3823f", fontSize: "10px", letterSpacing: "4px" }}>◆</div>
    <div style={{ width: "60px", height: "1px", background: "linear-gradient(to left, transparent, #a3823f)" }} />
  </div>
);

const FeedbackSection = ({ t }) => {
  const fb = t.feedback;
  const [message, setMessage] = useState("");
  const [status, setStatus] = useState("idle"); // idle | sending | done
  const [hint, setHint] = useState("");
  const [trap, setTrap] = useState("");         // 蜜罐欄位，真人看不到
  const openedAt = useRef(Date.now());

  const handleSubmit = async () => {
    if (status === "sending") return;
    const text = message.trim();

    // 機器人填了隱藏欄位：假裝成功，不寫入資料庫
    if (trap) {
      setMessage("");
      setStatus("done");
      return;
    }
    if (Date.now() - openedAt.current < FEEDBACK_MIN_DWELL_MS) return setHint(fb.tooFast);
    if (text.length < FEEDBACK_MIN_LEN) return setHint(fb.tooShort);

    const guard = readFeedbackGuard();
    const today = todayKey();
    const count = guard.day === today ? guard.count : 0;
    if (count >= FEEDBACK_DAILY_LIMIT) return setHint(fb.limit);
    if (Date.now() - guard.last < FEEDBACK_COOLDOWN_MS) return setHint(fb.tooFast);

    setHint("");
    setStatus("sending");
    const res = await submitFeedback(text.slice(0, FEEDBACK_MAX_LEN));
    if (!res.success) {
      setStatus("idle");
      setHint(fb.failed);
      return;
    }
    writeFeedbackGuard({ day: today, count: count + 1, last: Date.now() });
    setMessage("");
    setStatus("done");
  };

  return (
    <section className="fb-section" style={{
      padding: "clamp(56px, 7vw, 96px) 30px",
      background: "linear-gradient(180deg, rgba(255,255,255,0.3) 0%, rgba(255,255,255,0.7) 55%, #fff 100%)"
    }}>
      <div style={{ maxWidth: "560px", margin: "0 auto", textAlign: "center" }}>
        <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "14px" }}>{fb.eyebrow}</div>
        <h2 className="fb-title" style={{ fontSize: "clamp(20px, 2.6vw, 28px)", fontWeight: 500, letterSpacing: "3px", color: "#4a443a", marginBottom: "30px" }}>{fb.title}</h2>

        <div className="fb-body">
          <div className="fb-scroll">
            <div className="fb-rod" />
            {status === "done" ? (
              <div className="fb-paper fb-paper-done">
                <p className="fb-thanks">
                  <span className="fb-thanks-mark">◆</span>
                  {fb.thanks}
                </p>
              </div>
            ) : (
              <div className="fb-paper">
                <textarea
                  value={message}
                  onChange={e => { setMessage(e.target.value); if (hint) setHint(""); }}
                  maxLength={FEEDBACK_MAX_LEN}
                  placeholder={fb.placeholder}
                  aria-label={fb.title}
                />
                <span className="fb-count">{message.length}/{FEEDBACK_MAX_LEN}</span>
              </div>
            )}
            <div className="fb-rod" />
          </div>

          {status !== "done" && (
            <>
              <div className="fb-hint">{hint}</div>
              <input
                className="fb-trap"
                type="text"
                tabIndex={-1}
                autoComplete="off"
                aria-hidden="true"
                value={trap}
                onChange={e => setTrap(e.target.value)}
              />
              <button className="gold-btn" onClick={handleSubmit} disabled={status === "sending"}
                style={{ padding: "13px 46px", fontSize: "13px", letterSpacing: "4px", borderRadius: "2px" }}>
                {status === "sending" ? fb.sending : fb.submit}
              </button>
            </>
          )}
        </div>
      </div>
    </section>
  );
};

const Particle = ({ delay, x, duration }) => (
  <div style={{
    position: "absolute", left: `${x}%`, bottom: "-10px", width: "4px", height: "4px",
    borderRadius: "50%", background: "radial-gradient(circle, rgba(163,130,63,0.3), transparent)",
    animation: `floatUp ${duration}s ease-in-out ${delay}s infinite`
  }} />
);

export default function RouSpa({ onNavigateShop, onNavigateContact, onLangChange }) {
  const [lang, setLang] = useState("zh");
  const [bookingStep, setBookingStep] = useState(0);
  const [selectedService, setSelectedService] = useState(null);
  const [selectedTherapist, setSelectedTherapist] = useState(null);
  const [selectedDate, setSelectedDate] = useState("");
  const [selectedTime, setSelectedTime] = useState("");
  const [selectedTea, setSelectedTea] = useState(null);
  const [formName, setFormName] = useState("");
  const [formPhone, setFormPhone] = useState("");
  const [formNote, setFormNote] = useState("");
  const [bookingComplete, setBookingComplete] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [bookedSlots, setBookedSlots] = useState({});
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [slotError, setSlotError] = useState("");
  const [scrollY, setScrollY] = useState(0);
  const [menuOpen, setMenuOpen] = useState(false);
  const [animatedSections, setAnimatedSections] = useState(new Set());
  const [lineHover, setLineHover] = useState(false);
  const [showLineTooltip, setShowLineTooltip] = useState(false);
  const [openFormula, setOpenFormula] = useState(null);
  const enterFormula = (key) => setOpenFormula(key);
  const leaveFormula = (key) => setOpenFormula((prev) => (prev === key ? null : prev));
  const toggleFormula = (key) => setOpenFormula((prev) => (prev === key ? null : key));

  const t = i18n[lang];
  const sectionRefs = { home: useRef(), services: useRef(), booking: useRef(), location: useRef() };

  useEffect(() => {
    const h = () => setScrollY(window.scrollY || 0);
    window.addEventListener("scroll", h);
    return () => window.removeEventListener("scroll", h);
  }, []);

  useEffect(() => {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(entry => {
        if (entry.isIntersecting) setAnimatedSections(prev => new Set([...prev, entry.target.dataset.section]));
      });
    }, { threshold: 0.15 });
    Object.entries(sectionRefs).forEach(([key, ref]) => {
      if (ref.current) { ref.current.dataset.section = key; observer.observe(ref.current); }
    });
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => setShowLineTooltip(true), 3000);
    const hide = setTimeout(() => setShowLineTooltip(false), 8000);
    return () => { clearTimeout(timer); clearTimeout(hide); };
  }, []);

  const scrollTo = (section) => {
    sectionRefs[section]?.current?.scrollIntoView({ behavior: "smooth" });
    setMenuOpen(false);
  };

  useEffect(() => {
    if (!selectedDate) return;
    setLoadingSlots(true);
    fetchBookedSlots(selectedDate).then((map) => {
      setBookedSlots(map);
      setLoadingSlots(false);
    });
  }, [selectedDate]);

  const isSlotBooked = (time) => {
    if (selectedTherapist === -1) {
      const totalTherapists = i18n.zh.team.members.length;
      let bookedCount = 0;
      for (let i = 0; i < totalTherapists; i++) {
        if (bookedSlots[i] && bookedSlots[i].has(time)) bookedCount++;
      }
      return bookedCount >= totalTherapists;
    } else {
      return bookedSlots[selectedTherapist]?.has(time) || false;
    }
  };

  const getNext7Days = () => {
    const days = [];
    const today = new Date();
    for (let i = 1; i <= 7; i++) {
      const d = new Date(today); d.setDate(today.getDate() + i);
      if (d.getDay() !== 1) days.push(d.toISOString().split("T")[0]);
    }
    return days;
  };

  const timeSlots = {
    morning: ["10:00", "10:30", "11:00", "11:30"],
    afternoon: ["13:00", "13:30", "14:00", "14:30", "15:00", "15:30", "16:00", "16:30"],
    evening: ["17:00", "17:30", "18:00", "18:30", "19:00", "19:30", "20:00"]
  };

  const handleSubmitBooking = async () => {
    setSubmitting(true);
    setSlotError("");
    const teamNames = i18n.zh.team.members;
    let finalTherapistIndex = selectedTherapist;
    let finalTherapistName = "不指定";
    if (selectedTherapist === -1) {
      for (let i = 0; i < teamNames.length; i++) {
        if (!bookedSlots[i] || !bookedSlots[i].has(selectedTime)) {
          finalTherapistIndex = i;
          finalTherapistName = teamNames[i].name;
          break;
        }
      }
    } else {
      finalTherapistName = teamNames[selectedTherapist]?.name || "";
    }

    const data = {
      service: i18n.zh.services.items[selectedService]?.name || "",
      therapist: finalTherapistName,
      therapist_index: finalTherapistIndex,
      booking_date: selectedDate,
      booking_time: selectedTime,
      tea: i18n.zh.tea.items[selectedTea]?.name || "",
      customer_name: formName,
      phone: formPhone,
      note: formNote || null,
      status: "confirmed",
      created_at: new Date().toISOString(),
    };
    const result = await submitBooking(data);
    setSubmitting(false);
    if (result.success) {
      setBookingComplete(true);
    } else if (result.error === "slot_taken") {
      setSlotError(lang === "zh" ? "該時段剛被其他客人預約了，請選擇其他時間。" : "This slot was just booked. Please choose another time.");
      fetchBookedSlots(selectedDate).then(setBookedSlots);
    } else {
      setBookingComplete(true);
    }
  };

  const resetBooking = () => {
    setBookingStep(0); setSelectedService(null); setSelectedTherapist(null);
    setSelectedDate(""); setSelectedTime(""); setSelectedTea(null); setFormName(""); setFormPhone("");
    setFormNote(""); setBookingComplete(false); setSubmitting(false); setBookedSlots({}); setSlotError("");
  };

  const isAnimated = (s) => animatedSections.has(s);
  const navOpacity = Math.min(scrollY / 300, 0.98);

  // ===== 養生方子資料 =====
  const steps45 = ["頭肩頸筋絡按摩", "頭皮洗淨", "水療眼部", "手技收尾"];
  const formulas90 = [
    { stamp: "清", name: "森呼吸", sub: "柔禾角質調理", steps: ["頭肩頸筋絡按摩", "臉部牛角刷去角質", "綠豆泥頭皮去角質", "舒緩泡腳", "水療眼部", "四肢放鬆", "手技收尾"] },
    { stamp: "養", name: "墨玉烏", sub: "60天木質萃湯浴", steps: ["頭肩頸筋絡按摩", "木質萃湯浴養髮", "舒緩泡腳", "水療眼部", "四肢放鬆", "手技收尾"] },
    { stamp: "通", name: "薑暖陽", sub: "鮮薑溫通舒筋", steps: ["頭肩頸筋絡按摩", "鮮生薑頭部敷泥", "舒緩泡腳", "水療眼部", "四肢放鬆", "手技收尾"] },
  ];
  const formulas120 = [
    { stamp: "清", name: "森呼吸", sub: "柔禾角質調理", steps: ["頭肩頸筋絡按摩", "耳穴撥筋", "眼部清濁", "臉部牛角刷去角質", "綠豆泥頭皮去角質", "水乳面膜", "舒緩泡腳", "水療眼部", "四肢放鬆", "羽式采耳", "手技收尾"] },
    { stamp: "養", name: "墨玉烏", sub: "60天木質萃湯浴", steps: ["頭肩頸筋絡按摩", "耳穴撥筋", "眼部清濁", "木質萃湯浴養髮", "水乳面膜", "舒緩泡腳", "水療眼部", "四肢放鬆", "羽式采耳", "手技收尾"] },
    { stamp: "通", name: "薑暖陽", sub: "鮮薑溫通舒筋", steps: ["頭肩頸筋絡按摩", "耳穴撥筋", "眼部清濁", "鮮生薑頭部敷泥", "水乳面膜", "舒緩泡腳", "水療眼部", "四肢放鬆", "羽式采耳", "手技收尾"] },
  ];

  return (
    <div style={{ fontFamily: "'Noto Serif TC', 'Noto Serif', Georgia, serif", color: "#4a443a", background: "#f2ede4", minHeight: "100vh", overflowX: "hidden" }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Serif+TC:wght@300;400;500;600;700&family=Cormorant+Garamond:ital,wght@0,300;0,400;0,500;0,600;1,300;1,400&display=swap');
        * { margin: 0; padding: 0; box-sizing: border-box; }
        html { scroll-behavior: smooth; }

        @keyframes floatUp {
          0% { transform: translateY(0) scale(1); opacity: 0; }
          20% { opacity: 0.8; }
          80% { opacity: 0.4; }
          100% { transform: translateY(-600px) scale(0); opacity: 0; }
        }
        @keyframes fadeInUp { from { opacity: 0; transform: translateY(40px); } to { opacity: 1; transform: translateY(0); } }
        @keyframes fadeIn { from { opacity: 0; } to { opacity: 1; } }
        @keyframes gentlePulse { 0%, 100% { opacity: 0.05; } 50% { opacity: 0.1; } }
        @keyframes linePulse { 0%, 100% { box-shadow: 0 4px 20px rgba(6,199,85,0.3); } 50% { box-shadow: 0 4px 30px rgba(6,199,85,0.5), 0 0 60px rgba(6,199,85,0.15); } }
        @keyframes tooltipSlide { from { opacity: 0; transform: translateX(10px); } to { opacity: 1; transform: translateX(0); } }
        @keyframes checkmark { 0% { transform: scale(0) rotate(-45deg); opacity: 0; } 50% { transform: scale(1.2) rotate(0deg); } 100% { transform: scale(1) rotate(0deg); opacity: 1; } }

        /* 手機版控制斷行 - 預設隱藏 */
        .mobile-break { display: none; }
        
        @media (max-width: 640px) {
          .mobile-break { display: inline !important; }
        }

        .animate-in { animation: fadeInUp 0.8s ease-out forwards; }
        .animate-in-delay-1 { animation: fadeInUp 0.8s ease-out 0.15s forwards; opacity: 0; }
        .animate-in-delay-2 { animation: fadeInUp 0.8s ease-out 0.3s forwards; opacity: 0; }
        .animate-in-delay-3 { animation: fadeInUp 0.8s ease-out 0.45s forwards; opacity: 0; }
        .animate-in-delay-4 { animation: fadeInUp 0.8s ease-out 0.6s forwards; opacity: 0; }

        /* ===== Hero 主 logo 下移，避免與頂端漢堡選單重疊 ===== */
        .hero-logo-wrap { margin-top: 7vh; }

        /* ===== Hero 副標花字 + 金線繚繞整句 ===== */
        @property --gold-ang { syntax: '<angle>'; initial-value: 0deg; inherits: false; }
        .hero-brand-block {
          position: relative; display: flex; flex-direction: column;
          align-items: center; gap: 8px; padding: 16px 32px;
          border-radius: 46px; margin-bottom: 16px;
        }
        .hero-brand-block::before {
          content: ''; position: absolute; inset: 0; border-radius: 46px; padding: 1.6px;
          background: conic-gradient(from var(--gold-ang),
            rgba(163,130,63,0) 0deg, rgba(163,130,63,0) 200deg,
            #a3823f 258deg, #efd396 300deg, #a3823f 342deg, rgba(163,130,63,0) 360deg);
          -webkit-mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
          -webkit-mask-composite: xor;
          mask: linear-gradient(#000 0 0) content-box, linear-gradient(#000 0 0);
          mask-composite: exclude;
          animation: goldThread 4.5s linear infinite; pointer-events: none;
        }
        @keyframes goldThread { to { --gold-ang: 360deg; } }
        .hero-fancy {
          font-family: 'Noto Serif TC', serif; font-weight: 500;
          font-size: clamp(17px, 4.6vw, 22px);
          letter-spacing: 6px; line-height: 1.55; white-space: nowrap;
          background: linear-gradient(100deg, #7d6229 0%, #a3823f 24%, #f4dca6 50%, #a3823f 76%, #7d6229 100%);
          background-size: 220% auto;
          -webkit-background-clip: text; background-clip: text;
          -webkit-text-fill-color: transparent; color: transparent;
          animation: goldShimmer 6s linear infinite;
        }
        @keyframes goldShimmer { to { background-position: 220% center; } }
        @media (max-width: 640px) {
          .hero-logo-wrap { margin-top: 15vh !important; }
          .hero-brand-block { padding: 13px 22px; gap: 6px; margin-bottom: 14px; }
          .hero-fancy { letter-spacing: 4px; }
        }

        .gold-btn {
          background: linear-gradient(135deg, #a3823f 0%, #8a6d35 100%);
          color: #f2ede4; border: none; cursor: pointer;
          font-family: 'Noto Serif TC', serif; font-weight: 500;
          letter-spacing: 2px; transition: all 0.4s ease;
          position: relative; overflow: hidden;
        }
        .gold-btn:hover { background: linear-gradient(135deg, #b89650 0%, #a3823f 100%); transform: translateY(-2px); box-shadow: 0 8px 30px rgba(163,130,63,0.3); }
        .gold-btn:disabled { opacity: 0.4; cursor: not-allowed; transform: none; box-shadow: none; }

        .outline-btn {
          background: transparent; color: #a3823f; border: 1px solid rgba(163,130,63,0.4);
          cursor: pointer; font-family: 'Noto Serif TC', serif; font-weight: 400;
          letter-spacing: 2px; transition: all 0.4s ease;
        }
        .outline-btn:hover { border-color: #a3823f; background: rgba(163,130,63,0.08); }

        .line-btn {
          background: #06C755; color: white; border: none; cursor: pointer;
          font-family: 'Noto Serif TC', serif; font-weight: 500;
          letter-spacing: 1px; transition: all 0.3s; display: inline-flex; align-items: center; gap: 8px;
        }
        .line-btn:hover { background: #05b34c; transform: translateY(-1px); box-shadow: 0 6px 20px rgba(6,199,85,0.3); }

        .service-card {
          background: rgba(255, 255, 255, 0.4);
          border: 1px solid rgba(163,130,63,0.1); transition: all 0.5s cubic-bezier(0.4, 0, 0.2, 1);
          cursor: pointer; position: relative; overflow: hidden;
          box-shadow: 0 4px 20px rgba(0,0,0,0.03);
        }
        .service-card::before { content: ''; position: absolute; top: 0; left: 0; right: 0; height: 2px; background: linear-gradient(to right, transparent, #a3823f, transparent); opacity: 0; transition: opacity 0.5s; }
        .service-card:hover::before { opacity: 1; }
        .service-card:hover { border-color: rgba(163,130,63,0.35); transform: translateY(-6px); box-shadow: 0 15px 40px rgba(0,0,0,0.06); }
        .service-card.selected { border-color: rgba(163,130,63,0.6); background: rgba(255, 255, 255, 0.8); box-shadow: 0 0 40px rgba(163,130,63,0.1); }
        .service-card.selected::before { opacity: 1; }

        .therapist-card {
          background: rgba(255, 255, 255, 0.3);
          border: 1px solid rgba(163,130,63,0.08); transition: all 0.5s ease; cursor: pointer;
        }
        .therapist-card:hover { border-color: rgba(163,130,63,0.25); transform: translateY(-4px); background: rgba(255, 255, 255, 0.5); }
        .therapist-card.selected { border-color: rgba(163,130,63,0.5); background: rgba(255, 255, 255, 0.8); }

        .time-chip {
          background: rgba(163,130,63,0.05); border: 1px solid rgba(163,130,63,0.1);
          color: #a3823f; cursor: pointer; transition: all 0.3s;
          font-family: 'Cormorant Garamond', serif; font-size: 15px;
        }
        .time-chip:hover { background: rgba(163,130,63,0.1); border-color: rgba(163,130,63,0.3); }
        .time-chip.selected { background: linear-gradient(135deg, #a3823f, #8a6d35); color: #f2ede4; border-color: #a3823f; font-weight: 600; }
        .time-chip.booked { background: rgba(180,180,180,0.1); border-color: rgba(0,0,0,0.05); color: rgba(0,0,0,0.2); }

        input, textarea {
          background: rgba(255, 255, 255, 0.6); border: 1px solid rgba(163,130,63,0.2);
          color: #4a443a; font-family: 'Noto Serif TC', serif; font-size: 15px;
          padding: 14px 18px; width: 100%; border-radius: 4px; transition: all 0.3s; outline: none;
        }
        input:focus, textarea:focus { border-color: #a3823f; background: #fff; box-shadow: 0 0 20px rgba(163,130,63,0.05); }
        input::placeholder, textarea::placeholder { color: rgba(163,130,63,0.35); }

        /* ===== 匿名意見回饋 · 捲軸視覺 ===== */
        @keyframes fbFadeIn { from { opacity: 0; transform: translateY(8px); } to { opacity: 1; transform: none; } }

        /* min-height 讓送出前後高度一致，感謝訊息才會在「原位置」淡入而不跳版 */
        .fb-body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 18px; min-height: 238px; }
        .fb-scroll { width: 100%; max-width: 460px; margin: 0 auto; }

        .fb-rod {
          height: 6px; border-radius: 3px; position: relative;
          background: linear-gradient(180deg, rgba(232,217,180,0.95) 0%, #b89a5c 45%, #937a3c 100%);
          box-shadow: 0 2px 8px rgba(163,130,63,0.14);
        }
        .fb-rod::before, .fb-rod::after {
          content: ''; position: absolute; top: 50%; width: 6px; height: 6px;
          border-radius: 50%; transform: translateY(-50%);
          background: radial-gradient(circle at 35% 30%, #f1e6c9, #a3823f 78%);
        }
        .fb-rod::before { left: -4px; }
        .fb-rod::after { right: -4px; }

        .fb-paper {
          position: relative; padding: 18px 20px 20px;
          background: linear-gradient(180deg, #fdfbf5 0%, #faf6ec 55%, #f6f0e2 100%);
          border-left: 1px solid rgba(163,130,63,0.16);
          border-right: 1px solid rgba(163,130,63,0.16);
          box-shadow: inset 0 9px 14px -12px rgba(138,109,53,0.32),
                      inset 0 -9px 14px -12px rgba(138,109,53,0.32),
                      0 8px 26px rgba(163,130,63,0.06);
          transition: box-shadow 0.4s ease;
        }
        .fb-paper:focus-within {
          box-shadow: inset 0 9px 14px -12px rgba(138,109,53,0.32),
                      inset 0 -9px 14px -12px rgba(138,109,53,0.32),
                      0 12px 34px rgba(163,130,63,0.13);
        }

        .fb-paper textarea {
          display: block; background: transparent; border: none; border-radius: 0;
          padding: 0; height: 92px; resize: none; text-align: left;
          font-size: 14px; line-height: 2.1; letter-spacing: 1px; color: #4a443a;
        }
        .fb-paper textarea:focus { background: transparent; border: none; box-shadow: none; }
        .fb-paper textarea::placeholder { color: rgba(163,130,63,0.4); letter-spacing: 2px; }
        .fb-paper textarea::-webkit-scrollbar { width: 3px; }
        .fb-paper textarea::-webkit-scrollbar-track { background: transparent; }
        .fb-paper textarea::-webkit-scrollbar-thumb { background: rgba(163,130,63,0.28); border-radius: 3px; }

        .fb-count {
          position: absolute; right: 18px; bottom: 6px; font-size: 10px; letter-spacing: 1px;
          color: rgba(163,130,63,0.4); font-family: 'Cormorant Garamond', serif;
        }

        .fb-paper-done { display: flex; align-items: center; justify-content: center; min-height: 130px; }
        .fb-thanks {
          animation: fbFadeIn 0.9s ease-out both;
          font-size: 14px; line-height: 2; letter-spacing: 2px; color: #a3823f;
        }
        .fb-thanks-mark { display: block; font-size: 10px; letter-spacing: 4px; color: rgba(163,130,63,0.5); margin-bottom: 10px; }

        .fb-hint { min-height: 15px; font-size: 11px; letter-spacing: 1.5px; color: rgba(163,130,63,0.85); animation: fbFadeIn 0.4s ease-out; }
        .fb-trap { position: absolute !important; left: -9999px; width: 1px; height: 1px; opacity: 0; }

        @media (max-width: 640px) {
          .fb-section { padding: 36px 24px 40px !important; }
          /* 16px 可避免 iOS 點擊輸入框時自動放大頁面 */
          .fb-paper textarea { height: 74px; line-height: 1.9; font-size: 16px; }
          .fb-paper-done { min-height: 112px; }
          .fb-body { gap: 14px; min-height: 212px; }
          .fb-title { margin-bottom: 24px !important; }
        }

        .ink-bg { position: absolute; border-radius: 50%; opacity: 0.1; background: radial-gradient(circle, #a3823f, transparent 70%); animation: gentlePulse 8s ease-in-out infinite; }

        .step-dot { width: 10px; height: 10px; border-radius: 50%; border: 1px solid rgba(163,130,63,0.3); transition: all 0.4s; }
        .step-dot.active { background: #a3823f; border-color: #a3823f; box-shadow: 0 0 12px rgba(163,130,63,0.4); }
        .step-dot.completed { background: rgba(163,130,63,0.4); border-color: rgba(163,130,63,0.4); }

        @media (max-width: 768px) {
          .desktop-nav { display: none !important; }
          .mobile-menu-btn { display: flex !important; }
        }
        
        /* 技师卡片响应式布局 */
        .team-grid {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 28px 24px;
          max-width: 1000px;
          margin: 0 auto;
        }
        
        /* Hero文案响应式优化 */
        @media (max-width: 768px) {
          .team-grid {
            grid-template-columns: repeat(3, 1fr);
            gap: 16px 12px;
            padding: 0 16px;
          }
          .team-grid .therapist-card {
            padding: 20px 8px !important;
          }
          .team-grid .therapist-card h3 {
            font-size: 14px !important;
            letter-spacing: 1px !important;
          }
          .team-grid .therapist-card > div:first-child {
            width: 56px !important;
            height: 56px !important;
            font-size: 18px !important;
          }
        }
        
        @media (max-width: 640px) {
          .hero-text-mobile {
            font-size: 14px !important;
            letter-spacing: 1px !important;
            padding: 0 20px;
          }
          
          /* Hero區塊手機版 - 完全置中對稱 */
          .hero-section {
            padding: 0 20px !important;
            background-position: center center !important;
          }
          .hero-content {
            max-width: 100% !important;
            width: 100% !important;
            padding: 0 !important;
            margin: 0 auto !important;
            text-align: center !important;
            transform: translateX(-7px) !important; /* 整體往左移7px */
            display: flex !important;
            flex-direction: column !important;
            align-items: center !important;
          }
          .hero-content > * {
            margin-left: auto !important;
            margin-right: auto !important;
            width: 100% !important;
            display: flex !important;
            flex-direction: column !important;
            align-items: center !important;
          }
          /* Logo位置 - 往下移避免與上方重疊 */
          .hero-content > div:first-child {
            margin-top: 48px !important;
            margin-bottom: 24px !important;
            display: flex !important;
            justify-content: center !important;
          }
          /* 五感療癒小標手機版 */
          .hero-content .animate-in-delay-3 {
            gap: 16px !important;
          }
          .hero-subtitle-line {
            width: 40px !important;
            flex-shrink: 0 !important;
          }
          .hero-subtitle-text {
            font-size: 15px !important;
            letter-spacing: 6px !important;
            white-space: nowrap !important;
          }
          /* Hero文案置中 */
          .hero-content p,
          .hero-content h1,
          .hero-content h2 {
            text-align: center !important;
            margin-left: auto !important;
            margin-right: auto !important;
            padding: 0 !important;
            width: 100% !important;
          }
          
          /* 服務項目小卡片手機版 */
          .service-section-mobile {
            padding: 80px 20px !important;
          }
          .service-section-mobile .service-title-row {
            flex-direction: column !important;
            gap: 8px !important;
          }
          .service-section-mobile .service-title-row span:first-child {
            font-size: 16px !important;
          }
          .service-section-mobile .service-title-row span:last-child {
            font-size: 12px !important;
            margin-left: 0 !important;
          }
        }
        
        @media (max-width: 640px) {
          /* 養生項目縱向列表手機版優化 */
          .service-vertical-list {
            gap: 12px !important;
            padding: 0 20px !important;
          }
          .service-item-vertical {
            padding: 18px 20px !important;
          }
          .service-item-vertical > div:first-child {
            font-size: 14px !important;
            letter-spacing: 1.5px !important;
          }
          .service-item-vertical > div:last-child {
            font-size: 11px !important;
            letter-spacing: 0.5px !important;
          }
          
          /* 預約頁面服務選項手機版 - 保持橫向 */
          .booking-service-options {
            gap: 10px !important;
            padding: 0 10px;
          }
          .booking-service-options .booking-option-card {
            padding: 14px 16px !important;
            border-radius: 30px !important;
            min-width: auto !important;
            flex: 1 !important;
            max-width: none !important;
          }
          .booking-service-options .booking-option-card > div {
            font-size: 13px !important;
            letter-spacing: 1px !important;
          }
        }
        
        @media (max-width: 380px) {
          /* 超小手機螢幕 */
          .booking-service-options {
            gap: 8px !important;
          }
          .booking-service-options .booking-option-card {
            padding: 12px 12px !important;
          }
          .booking-service-options .booking-option-card > div {
            font-size: 12px !important;
            letter-spacing: 0.5px !important;
          }
        }

        /* ===== 養生方子展開卡片 ===== */
        .formula-list { display: flex; flex-direction: column; gap: 14px; }
        .formula-card {
          padding: 0 !important;
          border-radius: 8px;
          text-align: left;
          overflow: hidden;
          background: rgba(255,255,255,0.5);
        }
        .formula-card:hover { transform: none; border-color: rgba(163,130,63,0.3); }
        .formula-head {
          display: flex; align-items: center; gap: 18px;
          padding: 22px 26px;
        }
        /* 圓圈章印：清・養・通 */
        .seal-stamp {
          position: relative;
          width: 48px; height: 48px; flex-shrink: 0;
          border-radius: 50%;
          display: flex; align-items: center; justify-content: center;
          font-family: 'Noto Serif TC', serif;
        }
        .seal-char { line-height: 1; display: block; transform: translateY(0.5px); }
        /* 90分：淡雅描邊章（單圈細框、色淡、通透） */
        .seal-stamp.seal-v90 {
          border: 1.5px solid rgba(163,130,63,0.7);
          box-shadow: inset 0 0 0 3px rgba(163,130,63,0.08);
          color: #8a6d35; font-size: 22px; font-weight: 500;
          background: radial-gradient(circle at 32% 30%, rgba(255,255,255,0.75), rgba(163,130,63,0.05));
        }
        /* 120分：精緻實心金章 + 雙圈金框，明顯區別於 90 分 */
        .seal-stamp.seal-v120 {
          width: 54px; height: 54px;
          color: #fbf4e2;
          border: 1px solid #6a5124;
          box-shadow:
            inset 0 0 0 3px rgba(251,244,226,0.5),
            0 4px 14px rgba(110,86,40,0.45);
          background: radial-gradient(circle at 34% 26%, #cdaa5f 0%, #a5813c 52%, #7c5f2b 100%);
          font-size: 24px; font-weight: 600;
          text-shadow: 0 1px 2px rgba(80,60,24,0.55);
        }
        /* 雙圈外框（金色細框） */
        .seal-stamp.seal-v120::after {
          content: '';
          position: absolute; inset: -5px;
          border-radius: 50%;
          border: 1px solid rgba(163,130,63,0.6);
          pointer-events: none;
        }
        /* 120分卡片整體略作區隔（較精緻的章印感 + 微暖底色） */
        .formula-card.v120 {
          background: rgba(250,245,236,0.62);
          border-color: rgba(163,130,63,0.22);
        }
        .formula-card.v120.open {
          background: rgba(252,248,240,0.85);
          box-shadow: 0 12px 38px rgba(163,130,63,0.16);
          border-color: rgba(163,130,63,0.42);
        }
        .formula-card.v120 .formula-inner {
          background: linear-gradient(180deg, rgba(228,216,193,0.7) 0%, rgba(221,229,214,0.55) 100%);
          border-top: 1px double rgba(163,130,63,0.4);
        }
        .formula-title { flex: 1; display: flex; flex-direction: column; gap: 5px; min-width: 0; }
        .formula-title-center { align-items: center; text-align: center; }
        .formula-name { font-size: 17px; letter-spacing: 2.5px; color: #3d382f; font-weight: 600; line-height: 1.25; }
        .formula-sub { font-size: 12.5px; letter-spacing: 1.5px; color: rgba(74,68,58,0.6); font-weight: 400; line-height: 1.25; }
        .formula-toggle {
          flex-shrink: 0; font-size: 18px; color: #a3823f; opacity: 0.7;
          transition: transform 0.4s ease; line-height: 1;
        }
        .formula-card.open .formula-toggle { transform: rotate(180deg); }
        .formula-card.open {
          background: rgba(255,255,255,0.75);
          box-shadow: 0 10px 34px rgba(163,130,63,0.12);
          border-color: rgba(163,130,63,0.35);
        }
        .formula-body { max-height: 0; overflow: hidden; transition: max-height 0.55s cubic-bezier(0.4,0,0.2,1); }
        .formula-card.open .formula-body { max-height: 680px; }
        .formula-inner {
          padding: 20px 28px 26px;
          border-top: 1px dashed rgba(163,130,63,0.28);
          background: linear-gradient(180deg, rgba(234,225,208,0.62) 0%, rgba(224,231,218,0.5) 100%);
        }
        .formula-steps { display: grid; grid-template-columns: 1fr 1fr; gap: 12px 26px; }
        .formula-step {
          position: relative; padding-left: 18px;
          font-size: 14px; letter-spacing: 1px; color: #5b5346; line-height: 1.6;
        }
        .formula-step::before {
          content: ''; position: absolute; left: 2px; top: 8px;
          width: 6px; height: 6px; border-radius: 50%;
          background: #a3823f; opacity: 0.55;
        }

        @media (max-width: 640px) {
          .hero-logo-wrap img { height: 170px !important; }
          .formula-head { padding: 18px 18px; gap: 13px; }
          .seal-stamp { width: 44px; height: 44px; }
          .seal-stamp.seal-v90 { font-size: 20px; }
          .seal-stamp.seal-v120 { width: 48px; height: 48px; font-size: 21px; }
          .formula-name { font-size: 16px; letter-spacing: 2px; }
          .formula-sub { font-size: 12px; letter-spacing: 1px; }
          .formula-inner { padding: 18px 20px 22px; }
          .formula-steps { grid-template-columns: 1fr; gap: 11px; }
          .formula-step { font-size: 14px; }
        }
      `}</style>

      {/* ========== NAV ========== */}
      <nav style={{
        position: "fixed", top: 0, left: 0, right: 0, zIndex: 100,
        background: `rgba(242, 237, 228, ${navOpacity})`,
        backdropFilter: navOpacity > 0.1 ? "blur(20px)" : "none",
        borderBottom: navOpacity > 0.3 ? "1px solid rgba(163,130,63,0.1)" : "none",
        transition: "all 0.3s"
      }}>
        <div style={{ maxWidth: "1200px", margin: "0 auto", padding: "12px 30px", display: "flex", justifyContent: "space-between", alignItems: "center" }}>
          {/* 頁眉左上角 logo 與文字已移除 */}
          <div />
          <div className="desktop-nav" style={{ display: "flex", alignItems: "center", gap: "36px" }}>
            {Object.entries(t.nav).map(([key, label]) => (
              <span key={key} onClick={() => key === "shop" ? onNavigateShop?.() : key === "contact" ? onNavigateContact?.() : scrollTo(key)} style={{
                cursor: "pointer", fontSize: "13px", letterSpacing: "2px",
                color: key === "booking" ? "#a3823f" : "rgba(74, 68, 58, 0.7)",
                transition: "color 0.3s", fontWeight: key === "booking" ? 600 : 400
              }}
              onMouseEnter={e => e.target.style.color = "#a3823f"}
              onMouseLeave={e => e.target.style.color = key === "booking" ? "#a3823f" : "rgba(74, 68, 58, 0.7)"}
              >{label}</span>
            ))}
            <span onClick={() => { const newLang = lang === "zh" ? "en" : "zh"; setLang(newLang); onLangChange?.(newLang); }} style={{
              cursor: "pointer", fontSize: "12px", letterSpacing: "2px", padding: "5px 14px",
              border: "1px solid rgba(163,130,63,0.3)", color: "#a3823f", borderRadius: "2px", transition: "all 0.3s"
            }}
            onMouseEnter={e => e.target.style.background = "rgba(163,130,63,0.1)"}
            onMouseLeave={e => e.target.style.background = "transparent"}
            >{t.langSwitch}</span>
          </div>
          <div className="mobile-menu-btn" onClick={() => setMenuOpen(!menuOpen)} style={{
            cursor: "pointer", display: "none", flexDirection: "column", gap: "5px", padding: "4px"
          }}>
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", transform: menuOpen ? "rotate(45deg) translateY(6px)" : "none" }} />
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", opacity: menuOpen ? 0 : 1 }} />
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", transform: menuOpen ? "rotate(-45deg) translateY(-6px)" : "none" }} />
          </div>
        </div>
        {menuOpen && (
          <div className="mobile-nav" style={{
            background: "rgba(242, 237, 228, 0.98)", backdropFilter: "blur(20px)",
            padding: "20px 30px 30px", display: "flex", flexDirection: "column", gap: "20px",
            borderBottom: "1px solid rgba(163,130,63,0.1)"
          }}>
            {Object.entries(t.nav).map(([key, label]) => (
              <span key={key} onClick={() => { if (key === "shop") { onNavigateShop?.(); } else if (key === "contact") { onNavigateContact?.(); } else { scrollTo(key); } setMenuOpen(false); }} style={{ cursor: "pointer", fontSize: "15px", letterSpacing: "3px", color: "#4a443a", padding: "8px 0" }}>{label}</span>
            ))}
            <span onClick={() => { const newLang = lang === "zh" ? "en" : "zh"; setLang(newLang); onLangChange?.(newLang); setMenuOpen(false); }} style={{ cursor: "pointer", fontSize: "13px", letterSpacing: "2px", color: "#a3823f", padding: "8px 0" }}>{t.langSwitch}</span>
          </div>
        )}
      </nav>

      {/* ========== LINE FLOATING BUTTON ========== */}
      <div style={{ position: "fixed", bottom: "30px", right: "30px", zIndex: 99, display: "flex", alignItems: "center", gap: "12px" }}>
        {showLineTooltip && (
          <div style={{
            background: "white", border: "1px solid rgba(6,199,85,0.2)",
            padding: "10px 16px", borderRadius: "8px", fontSize: "13px", color: "#4a443a",
            boxShadow: "0 4px 15px rgba(0,0,0,0.08)",
            letterSpacing: "1px", whiteSpace: "nowrap", animation: "tooltipSlide 0.4s ease-out",
            backdropFilter: "blur(10px)"
          }}>
            {t.line.tooltip}
          </div>
        )}
        <a href={CONFIG.LINE_URL} target="_blank" rel="noopener noreferrer"
          onMouseEnter={() => { setLineHover(true); setShowLineTooltip(true); }}
          onMouseLeave={() => { setLineHover(false); setShowLineTooltip(false); }}
          style={{
            width: "60px", height: "60px", borderRadius: "50%", background: "#06C755",
            display: "flex", alignItems: "center", justifyContent: "center",
            boxShadow: "0 4px 20px rgba(6,199,85,0.3)", animation: "linePulse 3s ease-in-out infinite",
            transition: "transform 0.3s", transform: lineHover ? "scale(1.1)" : "scale(1)",
            textDecoration: "none"
          }}>
          <LineIcon />
        </a>
      </div>

      {/* ========== HERO ========== */}
      <section ref={sectionRefs.home} className="hero-section" style={{
        minHeight: "100vh",
        display: "flex",
        alignItems: "center",
        justifyContent: "flex-start",
        flexDirection: "column",
        position: "relative",
        overflow: "hidden",
        padding: "5vh 20px 7vh",
        backgroundImage: "url('/hero-bg.jpg')",
        backgroundSize: "cover",
        backgroundPosition: "center",
        backgroundRepeat: "no-repeat"
      }}>
        {/* 米白色遮罩：上方淡（露出照片、襯托白字 logo），往下漸濃（內文清楚可讀） */}
        <div style={{
          position: "absolute",
          inset: 0,
          background: "linear-gradient(180deg, rgba(242,237,228,0.22) 0%, rgba(242,237,228,0.34) 20%, rgba(243,238,230,0.62) 40%, rgba(243,238,230,0.82) 60%, rgba(242,237,228,0.88) 100%)"
        }} />
        {/* 內文區柔光，集中在中下段，避免洗掉上方照片 */}
        <div style={{
          position: "absolute",
          inset: 0,
          background: "radial-gradient(ellipse at 50% 62%, rgba(248,244,238,0.35) 0%, rgba(242,237,228,0.12) 55%, transparent 100%)"
        }} />
        <div className="ink-bg" style={{ width: "800px", height: "800px", top: "-200px", right: "-200px" }} />
        <div className="ink-bg" style={{ width: "600px", height: "600px", bottom: "-100px", left: "-100px", animationDelay: "4s" }} />
        {[15, 30, 50, 65, 80].map((x, i) => <Particle key={i} x={x} delay={i * 2.5} duration={12 + i * 2} />)}
        
        {/* 主內容容器 - 統一中軸 */}
        <div className="hero-main-container" style={{ 
          position: "relative", 
          zIndex: 1, 
          width: "min(100%, 400px)",
          margin: "0 auto",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          textAlign: "center",
          boxSizing: "border-box"
        }}>
          {/* Logo */}
          <div className="animate-in hero-logo-wrap" style={{ marginBottom: "22px", display: "flex", justifyContent: "center" }}>
            <SealLogo variant="hero" size={200} />
          </div>

          {/* 副標花字 + 金線繚繞（東方頭療・經絡養生 / 以柔養生） */}
          <div className="animate-in-delay-1 hero-brand-block">
            <span className="hero-fancy">{t.brandSub}</span>
            <span className="hero-fancy">{t.hero.title}</span>
          </div>

          {/* 裝飾線 */}
          <div className="animate-in-delay-2" style={{ marginBottom: "24px" }}>
            <GoldDivider />
          </div>
          
          {/* 第一段內文 - 控制斷行 */}
          <p className="animate-in-delay-3 hero-intro-1" style={{
            fontSize: "15px", 
            lineHeight: 2, 
            color: "rgba(74, 68, 58, 0.85)", 
            margin: "0 0 28px 0", 
            letterSpacing: "2px", 
            fontWeight: 400,
            textAlign: "center"
          }}>
            取東方養護之意，循舒緩調理之法<span className="mobile-break"><br /></span>
            由頭開始，漸入身心。
          </p>
          
          {/* 五感療癒小標 */}
          <div className="animate-in-delay-4 hero-subtitle-wrap" style={{
            display: "flex", 
            alignItems: "center", 
            justifyContent: "center",
            gap: "16px", 
            marginBottom: "24px",
            width: "100%"
          }}>
            <div className="hero-subtitle-line" style={{ 
              width: "40px", 
              height: "1px", 
              background: "rgba(163,130,63,0.4)",
              flexShrink: 0 
            }} />
            <h2 style={{
              fontSize: "16px", 
              fontWeight: 500, 
              letterSpacing: "6px",
              color: "#a3823f", 
              fontFamily: "'Noto Serif TC', serif",
              whiteSpace: "nowrap"
            }}>五感療癒</h2>
            <div className="hero-subtitle-line" style={{ 
              width: "40px", 
              height: "1px", 
              background: "rgba(163,130,63,0.4)",
              flexShrink: 0 
            }} />
          </div>
          
          {/* 第二段內文 - 控制斷行 */}
          <p className="animate-in-delay-4 hero-intro-2" style={{
            fontSize: "14px", 
            lineHeight: 2, 
            color: "rgba(74, 68, 58, 0.8)", 
            margin: "0 0 36px 0", 
            letterSpacing: "2px", 
            fontWeight: 400,
            textAlign: "center"
          }}>
            香和其息，音靜其神，觸柔其體，<span className="mobile-break"><br /></span>
            境緩其意，養歸於心。
          </p>
          
          {/* CTA 按鈕 */}
          <div className="animate-in-delay-4" style={{ width: "100%" }}>
            <button className="gold-btn" onClick={() => scrollTo("booking")} style={{
              padding: "16px 48px", 
              fontSize: "14px", 
              letterSpacing: "4px", 
              borderRadius: "2px"
            }}>{t.hero.cta}</button>
          </div>
        </div>
      </section>

      {/* ========== SERVICES ========== */}
      <section ref={sectionRefs.services} style={{
        padding: "120px 30px", position: "relative", overflow: "hidden",
        background: "rgba(255,255,255,0.2)"
      }}>
        <div style={{ maxWidth: "900px", margin: "0 auto", position: "relative", zIndex: 1 }}>
          <div style={{ textAlign: "center", marginBottom: "80px" }} className={isAnimated("services") ? "animate-in" : ""}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>SERVICES</div>
            <h2 style={{ fontSize: lang === "zh" ? "clamp(28px, 4vw, 38px)" : "clamp(26px, 3.5vw, 36px)", fontWeight: 500, letterSpacing: lang === "zh" ? "6px" : "3px" }}>{t.services.title}</h2>
            <GoldDivider />
            <p style={{ fontSize: "12px", letterSpacing: "2px", color: "rgba(74,68,58,0.5)", marginTop: "4px" }}>
              {lang === "zh" ? "滑鼠移入或點擊項目，展開完整療程內容" : "Hover or tap each item to reveal the full ritual"}
            </p>
          </div>
          
          {/* 45分方子區塊 */}
          <div style={{ marginBottom: "70px" }} className={isAnimated("services") ? "animate-in-delay-1" : ""}>
            <div style={{ textAlign: "center", marginBottom: "28px" }}>
              <span style={{ fontSize: "18px", letterSpacing: "3px", color: "#4a443a", fontWeight: 600 }}>45分方子</span>
              <span style={{ fontSize: "13px", letterSpacing: "2px", color: "rgba(163,130,63,0.7)", marginLeft: "16px" }}>原價1100</span>
            </div>
            <div className="service-vertical-list formula-list" style={{ maxWidth: "520px", margin: "0 auto" }}>
              <FormulaCard
                name="苦茶籽潔淨髮浴"
                steps={steps45}
                isOpen={openFormula === "45-0"}
                onEnter={() => enterFormula("45-0")}
                onLeave={() => leaveFormula("45-0")}
                onToggle={() => toggleFormula("45-0")}
              />
            </div>
          </div>
          
          {/* 90分方子區塊 */}
          <div style={{ marginBottom: "70px" }} className={isAnimated("services") ? "animate-in-delay-2" : ""}>
            <div style={{ textAlign: "center", marginBottom: "28px" }}>
              <span style={{ fontSize: "18px", letterSpacing: "3px", color: "#4a443a", fontWeight: 600 }}>90分方子</span>
              <span style={{ fontSize: "13px", letterSpacing: "2px", color: "rgba(163,130,63,0.7)", marginLeft: "16px" }}>原價2360</span>
            </div>
            <div className="service-vertical-list formula-list" style={{ maxWidth: "520px", margin: "0 auto" }}>
              {formulas90.map((f, i) => (
                <FormulaCard
                  key={i}
                  stamp={f.stamp}
                  name={f.name}
                  sub={f.sub}
                  steps={f.steps}
                  isOpen={openFormula === `90-${i}`}
                  onEnter={() => enterFormula(`90-${i}`)}
                  onLeave={() => leaveFormula(`90-${i}`)}
                  onToggle={() => toggleFormula(`90-${i}`)}
                />
              ))}
            </div>
          </div>
          
          {/* 120分全息區塊 */}
          <div style={{ marginBottom: "40px" }} className={isAnimated("services") ? "animate-in-delay-3" : ""}>
            <div style={{ textAlign: "center", marginBottom: "28px" }}>
              <span style={{ fontSize: "18px", letterSpacing: "3px", color: "#4a443a", fontWeight: 600 }}>120分方子</span>
              <span style={{ fontSize: "13px", letterSpacing: "2px", color: "rgba(163,130,63,0.7)", marginLeft: "16px" }}>原價3200</span>
            </div>
            <div className="service-vertical-list formula-list" style={{ maxWidth: "520px", margin: "0 auto" }}>
              {formulas120.map((f, i) => (
                <FormulaCard
                  key={i}
                  stamp={f.stamp}
                  name={f.name}
                  sub={f.sub}
                  steps={f.steps}
                  variant="v120"
                  isOpen={openFormula === `120-${i}`}
                  onEnter={() => enterFormula(`120-${i}`)}
                  onLeave={() => leaveFormula(`120-${i}`)}
                  onToggle={() => toggleFormula(`120-${i}`)}
                />
              ))}
            </div>
          </div>
        </div>
      </section>

      {/* ========== BOOKING ========== */}
      <section ref={sectionRefs.booking} style={{
        padding: "120px 30px", position: "relative", overflow: "hidden",
        background: "rgba(255,255,255,0.3)"
      }}>
        <div style={{ maxWidth: "700px", margin: "0 auto", position: "relative", zIndex: 1 }}>
          <div style={{ textAlign: "center", marginBottom: "50px" }} className={isAnimated("booking") ? "animate-in" : ""}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>RESERVATION</div>
            <h2 style={{ fontSize: lang === "zh" ? "clamp(28px, 4vw, 38px)" : "clamp(26px, 3.5vw, 36px)", fontWeight: 500, letterSpacing: lang === "zh" ? "6px" : "3px" }}>{t.booking.title}</h2>
            <GoldDivider />
            <p style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.6)", letterSpacing: "3px" }}>{t.booking.subtitle}</p>
          </div>

          {!bookingComplete && (
            <div style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: "12px", marginBottom: "50px" }}>
              {t.booking.steps.map((step, i) => (
                <div key={i} style={{ display: "flex", alignItems: "center", gap: "12px" }}>
                  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "8px" }}>
                    <div className={`step-dot ${i < bookingStep ? "completed" : ""} ${i === bookingStep ? "active" : ""}`} />
                    <span style={{ fontSize: "10px", letterSpacing: "1px", color: i <= bookingStep ? "#a3823f" : "rgba(0,0,0,0.2)", whiteSpace: "nowrap", fontWeight: 500 }}>{step}</span>
                  </div>
                  {i < 4 && <div style={{ width: "30px", height: "1px", background: i < bookingStep ? "rgba(163,130,63,0.3)" : "rgba(0,0,0,0.1)", marginBottom: "20px" }} />}
                </div>
              ))}
            </div>
          )}

          {bookingComplete ? (
            <div style={{ textAlign: "center", padding: "40px 30px", animation: "fadeInUp 0.6s ease-out" }}>
              <div style={{
                width: "80px", height: "80px", borderRadius: "50%", margin: "0 auto 28px",
                background: "rgba(163,130,63,0.1)", border: "2px solid #a3823f",
                display: "flex", alignItems: "center", justifyContent: "center",
                fontSize: "36px", color: "#a3823f", animation: "checkmark 0.6s ease-out"
              }}>✓</div>
              <p style={{ fontSize: "22px", color: "#a3823f", letterSpacing: "3px", marginBottom: "12px", fontWeight: 600 }}>{t.booking.success}</p>
              <p style={{ fontSize: "14px", color: "rgba(74, 68, 58, 0.7)", letterSpacing: "1px", marginBottom: "40px", lineHeight: 1.8 }}>{t.booking.successSub}</p>
              <div style={{ background: "white", borderRadius: "8px", padding: "28px", marginBottom: "36px", boxShadow: "0 4px 15px rgba(0,0,0,0.05)" }}>
                <p style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.7)", letterSpacing: "1px", marginBottom: "18px", lineHeight: 1.8 }}>{t.booking.successLine}</p>
                <a href={CONFIG.LINE_URL} target="_blank" rel="noopener noreferrer" style={{ textDecoration: "none" }}>
                  <button className="line-btn" style={{ padding: "12px 32px", fontSize: "14px", borderRadius: "6px" }}><LineIcon /> {t.booking.addLine}</button>
                </a>
              </div>
              <button className="outline-btn" onClick={resetBooking} style={{ padding: "12px 36px", fontSize: "13px", borderRadius: "2px" }}>{lang === "zh" ? "重新預約" : "Book Again"}</button>
            </div>
          ) : (
            <div style={{ animation: "fadeIn 0.4s ease-out" }}>
              {bookingStep === 0 && (
                <div>
                  <p style={{ fontSize: "14px", color: "#a3823f", textAlign: "center", marginBottom: "50px", letterSpacing: "2px", fontWeight: 500 }}>{t.booking.selectService}</p>
                  {/* 橫向三選項 - 膠囊式按鈕 */}
                  <div className="booking-service-options" style={{ 
                    display: "flex", 
                    justifyContent: "center", 
                    gap: "24px", 
                    marginBottom: "50px",
                    flexWrap: "nowrap"
                  }}>
                    {["45分方子", "90分方子", "120分方子"].map((name, i) => (
                      <div key={i} 
                        className={`service-card booking-option-card ${selectedService === i ? "selected" : ""}`}
                        onClick={() => setSelectedService(i)}
                        style={{ 
                          padding: "18px 36px", 
                          borderRadius: "40px", 
                          textAlign: "center",
                          cursor: "pointer",
                          transition: "all 0.3s ease",
                          minWidth: "100px",
                          flex: "1",
                          maxWidth: "160px"
                        }}>
                        <div style={{ 
                          fontSize: "15px", 
                          fontWeight: 500, 
                          letterSpacing: "2px", 
                          color: selectedService === i ? "#a3823f" : "#4a443a",
                          whiteSpace: "nowrap"
                        }}>{name}</div>
                      </div>
                    ))}
                  </div>
                  <div style={{ textAlign: "center", marginTop: "40px" }}>
                    <button className="gold-btn" disabled={selectedService === null} onClick={() => selectedService !== null && setBookingStep(1)}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.next}</button>
                  </div>
                </div>
              )}
              {/* (後續步驟依此類推，背景與文字顏色已透過CSS類別統一管理) */}
              {bookingStep === 1 && (
                <div>
                  <p style={{ fontSize: "14px", color: "#a3823f", textAlign: "center", marginBottom: "30px", letterSpacing: "1px", fontWeight: 500 }}>{t.booking.selectTherapist}</p>
                  <div style={{ display: "grid", gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))", gap: "16px" }}>
                    <div className={`therapist-card ${selectedTherapist === -1 ? "selected" : ""}`} onClick={() => setSelectedTherapist(-1)}
                      style={{ padding: "28px 20px", borderRadius: "4px", textAlign: "center" }}>
                      <div style={{ width: "56px", height: "56px", borderRadius: "50%", margin: "0 auto 14px", background: "rgba(163,130,63,0.08)", border: "1px solid rgba(163,130,63,0.1)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "20px", color: "#a3823f" }}>✦</div>
                      <div style={{ fontSize: "14px", letterSpacing: "2px", color: "#a3823f", fontWeight: 500 }}>{t.booking.anyTherapist}</div>
                    </div>
                    {t.team.members.map((m, i) => (
                      <div key={i} className={`therapist-card ${selectedTherapist === i ? "selected" : ""}`} onClick={() => setSelectedTherapist(i)}
                        style={{ padding: "28px 20px", borderRadius: "4px", textAlign: "center" }}>
                        <div style={{ width: "56px", height: "56px", borderRadius: "50%", margin: "0 auto 14px", background: `linear-gradient(135deg, rgba(163,130,63,0.15), rgba(255,255,255,0.5))`, border: "1px solid rgba(163,130,63,0.1)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "18px", color: "#a3823f", fontWeight: 600 }}>{m.name.charAt(0)}</div>
                        <div style={{ fontSize: "14px", fontWeight: 600, letterSpacing: "2px", marginBottom: "4px", color: "#4a443a" }}>{m.name}</div>
                        <div style={{ fontSize: "11px", color: "rgba(74, 68, 58, 0.6)" }}>{m.specialty}</div>
                      </div>
                    ))}
                  </div>
                  <div style={{ display: "flex", justifyContent: "center", gap: "20px", marginTop: "40px" }}>
                    <button className="outline-btn" onClick={() => setBookingStep(0)} style={{ padding: "14px 36px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.prev}</button>
                    <button className="gold-btn" disabled={selectedTherapist === null} onClick={() => selectedTherapist !== null && setBookingStep(2)}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.next}</button>
                  </div>
                </div>
              )}

              {bookingStep === 2 && (
                <div>
                  <div style={{ marginBottom: "36px" }}>
                    <label style={{ display: "block", fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "12px", fontWeight: 600 }}>{t.booking.selectDate}</label>
                    <div style={{ display: "flex", gap: "10px", flexWrap: "wrap" }}>
                      {getNext7Days().map(date => {
                        const d = new Date(date);
                        const wd = lang === "zh" ? ["日","一","二","三","四","五","六"][d.getDay()] : ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][d.getDay()];
                        return (
                          <div key={date} className={`time-chip ${selectedDate === date ? "selected" : ""}`} onClick={() => setSelectedDate(date)}
                            style={{ padding: "12px 16px", borderRadius: "4px", textAlign: "center", minWidth: "70px" }}>
                            <div style={{ fontSize: "11px", marginBottom: "4px", opacity: 0.8 }}>{wd}</div>
                            <div style={{ fontSize: "15px", fontWeight: 600 }}>{d.getDate()}</div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                  {selectedDate && (
                    <div style={{ animation: "fadeInUp 0.4s ease-out" }}>
                      <label style={{ display: "block", fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "16px", fontWeight: 600 }}>{t.booking.selectTime}</label>
                      {loadingSlots ? (
                        <div style={{ textAlign: "center", padding: "30px", color: "rgba(74, 68, 58, 0.5)", fontSize: "13px" }}>{lang === "zh" ? "正在查詢可用時段..." : "Loading..."}</div>
                      ) : (
                      <>
                      {Object.entries(timeSlots).map(([period, slots]) => (
                        <div key={period} style={{ marginBottom: "20px" }}>
                          <div style={{ fontSize: "11px", color: "rgba(74, 68, 58, 0.5)", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>{t.booking[period]}</div>
                          <div style={{ display: "flex", gap: "8px", flexWrap: "wrap" }}>
                            {slots.map(time => {
                              const booked = isSlotBooked(time);
                              return (
                                <div key={time} className={`time-chip ${selectedTime === time ? "selected" : ""} ${booked ? "booked" : ""}`}
                                  onClick={() => !booked && setSelectedTime(time)}
                                  style={{ padding: "10px 18px", borderRadius: "3px", opacity: booked ? 0.4 : 1, cursor: booked ? "not-allowed" : "pointer" }}>
                                  {time}
                                </div>
                              );
                            })}
                          </div>
                        </div>
                      ))}
                      </>
                      )}
                    </div>
                  )}
                  <div style={{ display: "flex", justifyContent: "center", gap: "20px", marginTop: "40px" }}>
                    <button className="outline-btn" onClick={() => setBookingStep(1)} style={{ padding: "14px 36px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.prev}</button>
                    <button className="gold-btn" disabled={!selectedDate || !selectedTime} onClick={() => selectedDate && selectedTime && setBookingStep(3)}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.next}</button>
                  </div>
                </div>
              )}
              {/* (其餘步驟 3, 4 同理，皆使用定義好的卡其配色變數) */}
              {bookingStep === 3 && (
                <div>
                  <p style={{ fontSize: "14px", color: "#a3823f", textAlign: "center", marginBottom: "8px", letterSpacing: "1px", fontWeight: 500 }}>{t.booking.selectTea}</p>
                  <p style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.5)", textAlign: "center", marginBottom: "30px", letterSpacing: "1px" }}>{t.booking.teaNote}</p>
                  <div style={{ display: "flex", flexDirection: "column", gap: "14px" }}>
                    {t.tea.items.map((tea, i) => (
                      <div key={i} className={`service-card ${selectedTea === i ? "selected" : ""}`}
                        onClick={() => setSelectedTea(i)}
                        style={{ padding: "20px 24px", borderRadius: "4px", display: "flex", alignItems: "center", gap: "16px", flexWrap: "wrap" }}>
                        <div style={{ fontSize: "28px", flexShrink: 0 }}>{tea.icon}</div>
                        <div style={{ flex: 1, minWidth: "180px" }}>
                          <div style={{ display: "flex", alignItems: "center", gap: "10px", marginBottom: "4px" }}>
                            <span style={{ fontSize: "15px", fontWeight: 600, letterSpacing: "1px", color: "#4a443a" }}>{tea.name}</span>
                            <span style={{ fontSize: "10px", padding: "2px 8px", background: "rgba(163,130,63,0.1)", color: "#a3823f", borderRadius: "2px" }}>{tea.tag}</span>
                          </div>
                          <p style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.6)", lineHeight: 1.6 }}>{tea.desc}</p>
                        </div>
                        <div style={{ fontSize: "14px", color: "#a3823f", fontWeight: 600 }}>{tea.price}</div>
                      </div>
                    ))}
                  </div>
                  <div style={{ display: "flex", justifyContent: "center", gap: "20px", marginTop: "40px" }}>
                    <button className="outline-btn" onClick={() => setBookingStep(2)} style={{ padding: "14px 36px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.prev}</button>
                    <button className="gold-btn" disabled={selectedTea === null} onClick={() => selectedTea !== null && setBookingStep(4)}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.next}</button>
                  </div>
                </div>
              )}

              {bookingStep === 4 && (
                <div>
                  <div style={{ background: "rgba(255,255,255,0.5)", border: "1px solid rgba(163,130,63,0.1)", borderRadius: "4px", padding: "28px", marginBottom: "36px" }}>
                    <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "16px", fontWeight: 600 }}>預約摘要</div>
                    <div style={{ display: "grid", gap: "12px" }}>
                      {[
                        [lang === "zh" ? "服務" : "Service", t.services.items[selectedService]?.name],
                        [lang === "zh" ? "技師" : "Therapist", selectedTherapist === -1 ? t.booking.anyTherapist : t.team.members[selectedTherapist]?.name],
                        [lang === "zh" ? "日期" : "Date", selectedDate],
                        [lang === "zh" ? "時間" : "Time", selectedTime],
                        [lang === "zh" ? "茶飲" : "Tea", t.tea.items[selectedTea]?.name],
                        [lang === "zh" ? "費用" : "Price", t.services.items[selectedService]?.price],
                      ].map(([label, val], i) => (
                        <div key={i} style={{ display: "flex", justifyContent: "space-between", fontSize: "14px" }}>
                          <span style={{ color: "rgba(74, 68, 58, 0.6)" }}>{label}</span>
                          <span style={{ color: "#4a443a", fontWeight: 600 }}>{val}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                  <div style={{ display: "flex", flexDirection: "column", gap: "20px", marginBottom: "40px" }}>
                    <input value={formName} onChange={e => setFormName(e.target.value)} placeholder="您的姓名" />
                    <input value={formPhone} onChange={e => setFormPhone(e.target.value)} placeholder="您的手機號碼" />
                    <textarea value={formNote} onChange={e => setFormNote(e.target.value)} rows={3} placeholder="備註（選填）" />
                  </div>
                  <div style={{ display: "flex", justifyContent: "center", gap: "20px" }}>
                    <button className="outline-btn" onClick={() => setBookingStep(3)} style={{ padding: "14px 36px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>上一步</button>
                    <button className="gold-btn" disabled={!formName || !formPhone || submitting} onClick={handleSubmitBooking}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>
                      {submitting ? "提交中..." : "確認預約"}
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </section>

      {/* ========== FEEDBACK（匿名意見回饋） ========== */}
      <FeedbackSection t={t} />

      {/* ========== LOCATION ========== */}
      <section ref={sectionRefs.location} style={{ padding: "100px 30px 80px", background: "white" }}>
        <div style={{ maxWidth: "1100px", margin: "0 auto" }}>
          <div style={{ textAlign: "center", marginBottom: "50px" }}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>LOCATION</div>
            <h2 style={{ fontSize: "32px", fontWeight: 500, color: "#4a443a" }}>交通位置</h2>
            <GoldDivider />
          </div>
          <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: "40px", alignItems: "center" }}>
            <div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>地址</div>
                <p style={{ fontSize: "15px", color: "#4a443a" }}>{t.footer.address}</p>
              </div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>營業時間</div>
                <p style={{ fontSize: "15px", color: "#4a443a" }}>10:00 - 02:00（全年無休）</p>
              </div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>預約電話</div>
                <p style={{ fontSize: "18px", color: "#a3823f", fontWeight: 600 }}>{CONFIG.PHONE}</p>
              </div>
            </div>
            <div style={{ borderRadius: "8px", overflow: "hidden", border: "1px solid rgba(163,130,63,0.1)", height: "300px" }}>
              <iframe src="https://www.google.com/maps?q=嘉義市西區蘭井街421號&output=embed" width="100%" height="100%" style={{ border: 0, filter: "sepia(20%) contrast(1.1) brightness(1.05)" }} allowFullScreen="" loading="lazy" title="map" />
            </div>
          </div>
        </div>
      </section>

      {/* ========== FOOTER ========== */}
      <footer style={{ padding: "60px 30px 40px", borderTop: "1px solid rgba(163,130,63,0.1)", textAlign: "center" }}>
        <div style={{ marginBottom: "20px" }}><SealLogo size={150} /></div>
        <div style={{ fontSize: "16px", fontWeight: 600, color: "#a3823f", letterSpacing: "6px", marginBottom: "24px" }}>{t.brand}</div>
        <div style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.5)", letterSpacing: "1px" }}>{t.footer.copyright}</div>
      </footer>
    </div>
  );
}
