import { useState, useEffect, useLayoutEffect, useRef, useId } from "react";
import BookingLookup from "./BookingLookup.jsx";
import { STORE, hoursText, publicName, slotLabel } from "./lib/public-copy.js";
import { rpc, errorText, money, dateAfter, taipeiDate } from "./lib/spa.js";

// ============================================================
// 🔧 CONFIGURATION
// ============================================================
const CONFIG = STORE;

const i18n = {
  zh: {
    brand: "柔療髮浴",
    brandEn: "ROU SPA",
    brandSub: "東方頭療・經絡舒緩",
    nav: { home: "首頁", services: "服務項目", booking: "立即預約", lookup: "查詢預約", shop: "特色產品", contact: "聯繫我們" },
    hero: {
      title: "以柔養生",
      cta: "預約體驗"
    },
    services: {
      title: "養生項目",
      subtitle: "精選調理 · 身心合一",
    },
    booking: {
      title: "預約調理",
      subtitle: "開啟您的養生之旅",
      steps: ["選擇服務", "選擇技師", "選擇時段", "確認預約"],
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
      successLine: "加入 LINE 官方帳號，聯絡門店確認預約或詢問服務。",
      addLine: "加入 LINE",
      morning: "上午",
      afternoon: "下午",
      evening: "晚間",
      submitting: "預約中…"
    },
    feedback: {
      eyebrow: "FEEDBACK",
      title: "您的反饋，能讓我們更好",
      placeholder: "柔療需要改進的地方",
      submit: "送出",
      sending: "傳送中…",
      thanks: "謝謝您的寶貴意見，我們會持續改善。",
      tooShort: "請再多寫幾個字，讓我們更清楚。",
      tooFast: "請稍候片刻再送出。",
      limit: "今日的意見我們已收到，感謝您的用心。",
      failed: "送出失敗，請稍後再試。"
    },
    footer: {
      address: CONFIG.ADDRESS_ZH,
      phone: CONFIG.PHONE,
      copyright: "© 2026 柔療髮浴 版權所有"
    },
    line: { tooltip: "LINE 諮詢" },
    langSwitch: "EN"
  },
  en: {
      brand: "ROU SPA",
      brandEn: "ROU SPA",
      brandSub: "Head therapy · Meridian relaxation",
      nav: { home: "Home", services: "Services", booking: "Book now", lookup: "Find booking", shop: "Products", contact: "Contact" },
      hero: {
        title: "Wellness through gentle care",
        cta: "Book now"
      },
      services: {
        title: "Services",
        subtitle: "Curated therapies · Mind and body",
      },
    booking: {
        title: "Book an appointment",
        subtitle: "Begin your wellness journey",
        steps: ["Select service", "Select therapist", "Select time", "Confirm"],
        selectService: "Choose a service",
        selectTherapist: "Choose a therapist",
        anyTherapist: "No preference",
        selectDate: "Select date",
        selectTime: "Select time",
        name: "Full name",
        phone: "Phone number",
        note: "Notes (optional)",
        next: "Next",
        prev: "Back",
        confirm: "Confirm booking",
        success: "Booking confirmed",
        successSub: "We will contact you shortly to confirm your appointment.",
        successLine: "Add our LINE account to contact us about your booking or services.",
        addLine: "Add on LINE",
        morning: "Morning",
        afternoon: "Afternoon",
        evening: "Evening",
        submitting: "Submitting…"
      },
      feedback: {
        eyebrow: "FEEDBACK",
        title: "Your feedback helps us improve",
        placeholder: "What could ROU SPA do better?",
        submit: "Send",
        sending: "Sending…",
        thanks: "Thank you for your thoughts — we will keep improving.",
        tooShort: "Please write a little more so we understand.",
        tooFast: "Please wait a moment before sending.",
        limit: "We have received your notes for today. Thank you.",
        failed: "Could not send. Please try again later."
      },
      footer: {
        address: CONFIG.ADDRESS_EN,
        phone: CONFIG.PHONE,
        copyright: "© 2026 ROU SPA. All rights reserved."
      },
      line: { tooltip: "LINE chat" },
      langSwitch: "中文"
  }
};

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
  return taipeiDate();
}

async function submitFeedback(message) {
  try { await rpc("spa_submit_feedback", { p_message: message }); return { success: true }; }
  catch { return { success: false }; }
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
function FormulaCard({ stamp, name, sub, steps, isOpen, onToggle, variant = "v90" }) {
  const panelId = useId();
  return (
    <div className={`service-card formula-card ${variant} ${isOpen ? "open" : ""}`}>
      <button type="button" className="formula-head" aria-expanded={isOpen} aria-controls={panelId} onClick={onToggle}>
        {stamp && (
          <span className={`seal-stamp seal-${variant}`}>
            <span className="seal-char">{stamp}</span>
          </span>
        )}
        <span className={stamp ? "formula-title" : "formula-title formula-title-center"}>
          <span className="formula-name">{name}</span>
          {sub && <span className="formula-sub">{sub}</span>}
        </span>
        <span className="formula-toggle" aria-hidden="true">⌄</span>
      </button>
      <div id={panelId} className="formula-body" hidden={!isOpen}>
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

const GoldDivider = ({ plain = false }) => plain ? (
  <div className="hero-divider" aria-hidden="true" />
) : (
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

function PublishedReviews({lang}) {
 const [reviews,setReviews]=useState([]);
 useEffect(()=>{let live=true;rpc('spa_public_reviews').then(rows=>{if(live)setReviews(rows);}).catch(()=>{});return()=>{live=false;};},[]);
 if(!reviews.length)return null;
 return <section className="public-reviews" style={{padding:"30px 30px 80px",maxWidth:900,margin:"0 auto"}}><h2 style={{fontWeight:500,textAlign:"center",color:"#a3823f",marginBottom:28}}>{lang==='zh'?'顧客療程評價':'Verified guest reviews'}</h2><div style={{display:"grid",gridTemplateColumns:"repeat(auto-fit,minmax(250px,1fr))",gap:20}}>{reviews.map((r,i)=><article key={i} style={{padding:24,border:"1px solid rgba(163,130,63,.2)",borderRadius:4}}><p aria-label={`${r.rating} / 5`} style={{color:"#a3823f"}}>{'★'.repeat(r.rating)}{'☆'.repeat(5-r.rating)}</p><p style={{marginTop:12,lineHeight:1.8,whiteSpace:"pre-wrap",overflowWrap:"anywhere"}}>{r.comment}</p><p style={{fontSize:12,opacity:.7,marginTop:12}}>{r.therapist} · {taipeiDate(new Date(r.created_at))}</p>{r.reply&&<p style={{marginTop:16,lineHeight:1.8,fontSize:13,whiteSpace:"pre-wrap"}}>{lang==='zh'?'門店回覆：':'Our reply: '}{r.reply}</p>}</article>)}</div></section>;
}

const Particle = ({ delay, x, duration }) => (
  <div style={{
    position: "absolute", left: `${x}%`, bottom: "-10px", width: "4px", height: "4px",
    borderRadius: "50%", background: "radial-gradient(circle, rgba(163,130,63,0.3), transparent)",
    animation: `floatUp ${duration}s ease-in-out ${delay}s infinite`
  }} />
);

export default function RouSpa({ lang = "zh", onNavigateShop, onNavigateContact, onLangChange }) {
  const setLang = next => onLangChange?.(next);
  const [bookingStep, setBookingStep] = useState(0);
  const [bookingMode, setBookingMode] = useState("new");
  const bookingAnchor = useRef(null), navRef = useRef(null), bookingMounted = useRef(false);
  const [selectedService, setSelectedService] = useState(null);
  const [selectedTherapist, setSelectedTherapist] = useState(null);
  const [selectedDate, setSelectedDate] = useState("");
  const [selectedTime, setSelectedTime] = useState("");
  const [formName, setFormName] = useState("");
  const [formPhone, setFormPhone] = useState("");
  const [formNote, setFormNote] = useState("");
  const [bookingComplete, setBookingComplete] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [catalog, setCatalog] = useState(null);
  const [catalogError, setCatalogError] = useState("");
  const [bookedSlots, setBookedSlots] = useState([]);
  const [receipt, setReceipt] = useState(null);
  const bookingRequest = useRef(null);
  const services = catalog?.services || [];
  const therapists = (catalog?.staff || []).filter(st => selectedService === null || catalog.skills.some(sk => sk.staff_id === st.id && sk.service_id === services[selectedService]?.id));
  const [loadingSlots, setLoadingSlots] = useState(false);
  const [slotError, setSlotError] = useState("");
  const [scrollY, setScrollY] = useState(0);
  const [menuOpen, setMenuOpen] = useState(false);
  const [animatedSections, setAnimatedSections] = useState(new Set());
  const [lineHover, setLineHover] = useState(false);
  const [showLineTooltip, setShowLineTooltip] = useState(false);
  const [lineOverContent, setLineOverContent] = useState(false);
  const [openFormula, setOpenFormula] = useState(null);
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
    const visible = new Set();
    const observer = new IntersectionObserver(entries => {
      for (const entry of entries) entry.isIntersecting ? visible.add(entry.target) : visible.delete(entry.target);
      setLineOverContent(visible.size > 0);
    });
    [sectionRefs.services.current, sectionRefs.booking.current].filter(Boolean).forEach(el => observer.observe(el));
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const timer = setTimeout(() => setShowLineTooltip(true), 3000);
    const hide = setTimeout(() => setShowLineTooltip(false), 8000);
    return () => { clearTimeout(timer); clearTimeout(hide); };
  }, []);

  const alignBooking = (behavior = "instant") => {
    const target = bookingAnchor.current;
    if (!target) return;
    const offset = (navRef.current?.getBoundingClientRect().height || 64) + 16;
    window.scrollTo({ top: Math.max(0, target.getBoundingClientRect().top + window.scrollY - offset), left: 0, behavior });
  };
  const scrollTo = (section) => {
    setMenuOpen(false);
    if (section === "booking" || section === "lookup") {
      setBookingMode(section === "lookup" ? "lookup" : "new");
      requestAnimationFrame(() => alignBooking(window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth'));
    } else {
      requestAnimationFrame(() => {
        const target = sectionRefs[section]?.current;
        if (target) window.scrollTo({ top: Math.max(0, target.getBoundingClientRect().top + window.scrollY - (navRef.current?.getBoundingClientRect().height || 64)), behavior: 'smooth' });
      });
    }
  };
  useLayoutEffect(() => {
    if (!bookingMounted.current) { bookingMounted.current = true;return; }
    if (document.activeElement instanceof HTMLElement) document.activeElement.blur();
    alignBooking();
  }, [bookingStep, bookingComplete, bookingMode]);

  useEffect(() => {
    rpc("spa_catalog").then(setCatalog).catch(err => setCatalogError(errorText(err, lang)));
  }, []);

  useEffect(() => {
    setSelectedTime(""); setBookedSlots([]);
    if (!selectedDate || selectedService === null || !services[selectedService]) return;
    let current = true;
    setLoadingSlots(true); setSlotError("");
    rpc("spa_availability", { p_service: services[selectedService].id, p_date: selectedDate, p_staff: selectedTherapist === -1 ? null : selectedTherapist })
      .then(slots => { if (current) setBookedSlots(slots); })
      .catch(err => { if (current) setSlotError(errorText(err, lang)); })
      .finally(() => { if (current) setLoadingSlots(false); });
    return () => { current = false; };
  }, [selectedDate, selectedService, selectedTherapist, catalog]);

  const getNext7Days = () => Array.from({ length: Math.min(7, catalog?.settings.booking_days || 7) }, (_, i) => dateAfter(i));
  const timeSlots = {
    morning: bookedSlots.filter(s => !s.time_label.startsWith("翌日") && Number(s.time_label.slice(0,2)) < 12),
    afternoon: bookedSlots.filter(s => !s.time_label.startsWith("翌日") && Number(s.time_label.slice(0,2)) >= 12 && Number(s.time_label.slice(0,2)) < 17),
    evening: bookedSlots.filter(s => s.time_label.startsWith("翌日") || Number(s.time_label.slice(0,2)) >= 17)
  };
  const handleSubmitBooking = async () => {
    if (submitting) return;
    setSubmitting(true); setSlotError("");
    const payload = { p_service: services[selectedService]?.id, p_date: selectedDate, p_start: selectedTime,
      p_staff: selectedTherapist === -1 ? null : selectedTherapist, p_name: formName.trim(), p_phone: formPhone.trim(), p_tea: 0, p_note: formNote };
    const fingerprint = JSON.stringify(payload);
    if (bookingRequest.current?.fingerprint !== fingerprint) bookingRequest.current = { fingerprint, id: crypto.randomUUID() };
    try {
      const result = await rpc("spa_create_booking", { p_request: bookingRequest.current.id, ...payload });
      setReceipt(result); setBookingComplete(true);
    } catch (err) {
      setSlotError(errorText(err, lang));
      if (err.message?.includes("SLOT_TAKEN")) {
        setSelectedTime(""); setBookingStep(2);
        try { setBookedSlots(await rpc("spa_availability", { p_service: payload.p_service, p_date: selectedDate, p_staff: payload.p_staff })); }
        catch { setBookedSlots([]); }
      }
    } finally { setSubmitting(false); }
  };

  const resetBooking = () => {
    setBookingStep(0); setSelectedService(null); setSelectedTherapist(null);
    setSelectedDate(""); setSelectedTime(""); setFormName(""); setFormPhone("");
    setFormNote(""); setBookingComplete(false); setSubmitting(false); setBookedSlots([]); setSlotError(""); setReceipt(null); bookingRequest.current = null;
  };

  const isAnimated = (s) => animatedSections.has(s);
  const navOpacity = Math.min(scrollY / 300, 0.98);

  // 官網療程內容與預約價格共用後台主資料；停用或封存會同步從前台移除。
  const websiteServices = catalog?.website_services || services;
  const serviceRituals = service => service.website_content?.[lang] || service.website_content?.zh || [];

  return (
    <div className="public-home" data-language={lang} style={{ fontFamily: "var(--public-font)", color: "#4a443a", background: "#f2ede4", minHeight: "100vh", overflowX: "clip" }}>
      <style>{`
        html { scroll-behavior: auto; }

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

        /* ===== Hero 棕色副標 + 間歇金色掃光 ===== */
        .hero-brand-block {
          position: relative; display: flex; flex-direction: column;
          align-items: center; gap: 8px; padding: 16px 32px;
          margin-bottom: 16px;
        }
        .hero-fancy {
          font-family: var(--public-font); font-weight: 700;
          font-size: clamp(17px, 4.6vw, 22px);
          letter-spacing: 6px; line-height: 1.55; white-space: nowrap;
          color: rgba(102, 70, 43, 0.9);
        }
        @supports (background-clip: text) or (-webkit-background-clip: text) {
          .hero-fancy {
            background-image: linear-gradient(90deg,
              rgba(102,70,43,0.9) 0%, rgba(102,70,43,0.9) 40%,
              rgba(186,143,65,0.94) 46%, rgba(231,195,119,0.96) 50%,
              rgba(186,143,65,0.94) 54%, rgba(102,70,43,0.9) 60%, rgba(102,70,43,0.9) 100%);
            background-size: 250% 100%; background-repeat: no-repeat;
            -webkit-background-clip: text; background-clip: text;
            -webkit-text-fill-color: transparent;
            animation: heroGoldSweep 6.6s linear infinite;
          }
        }
        /* Each 6.6-second cycle sweeps left to right for 1.6 seconds, then holds brown for 5 seconds. */
        @keyframes heroGoldSweep {
          0% { background-position: 100% center; animation-timing-function: ease-in-out; }
          24.242424%, 100% { background-position: 0% center; }
        }
        .hero-divider {
          width: 180px; max-width: 100%; height: 1px; margin: 20px auto;
          background: rgba(131,101,52,0.65); transform: scaleY(0.5);
        }
        @media (prefers-reduced-motion: reduce) {
          .hero-fancy {
            animation: none; background-image: none;
            -webkit-text-fill-color: currentColor;
          }
        }
        @media (max-width: 640px) {
          .hero-logo-wrap { margin-top: 15vh !important; }
          .hero-brand-block { padding: 13px 22px; gap: 6px; margin-bottom: 14px; }
          .hero-fancy { letter-spacing: 4px; }
        }

        .gold-btn {
          background: linear-gradient(135deg, #a3823f 0%, #8a6d35 100%);
          color: #f2ede4; border: none; cursor: pointer;
          font-family: var(--public-font); font-weight: 500;
          letter-spacing: 2px; transition: all 0.4s ease;
          position: relative; overflow: hidden;
        }
        .gold-btn:hover { background: linear-gradient(135deg, #b89650 0%, #a3823f 100%); transform: translateY(-2px); box-shadow: 0 8px 30px rgba(163,130,63,0.3); }
        .gold-btn:disabled { opacity: 0.4; cursor: not-allowed; transform: none; box-shadow: none; }

        .outline-btn {
          background: transparent; color: #a3823f; border: 1px solid rgba(163,130,63,0.4);
          cursor: pointer; font-family: var(--public-font); font-weight: 400;
          letter-spacing: 2px; transition: all 0.4s ease;
        }
        .outline-btn:hover { border-color: #a3823f; background: rgba(163,130,63,0.08); }

        .line-btn {
          background: #06C755; color: white; border: none; cursor: pointer;
          font-family: var(--public-font); font-weight: 500;
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
          color: #4a443a; font-family: var(--public-font); font-size: 15px;
          padding: 14px 18px; width: 100%; border-radius: 4px; transition: all 0.3s; outline: none;
        }
        input:focus, textarea:focus { border-color: #a3823f; background: #fff; box-shadow: 0 0 20px rgba(163,130,63,0.05); }
        input::placeholder, textarea::placeholder { color: rgba(163,130,63,0.35); }

        /* 精品茶席：與「120分方子」同字級並列，以卡其金與較輕字重區隔主從 */
        .tea-tag {
          display: inline-block; white-space: nowrap;
          font-size: 18px; font-weight: 500; letter-spacing: 3px;
          color: #a3823f;
        }

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

        /* 技師卡片響應式布局 */
        .team-grid {
          display: grid;
          grid-template-columns: repeat(3, 1fr);
          gap: 28px 24px;
          max-width: 1000px;
          margin: 0 auto;
        }

        /* Hero文案響應式優化 */
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
            padding: 0 !important;
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
          width: 100%; border: 0; background: transparent; text-align: left; color: inherit; font: inherit; cursor: pointer;
          padding: 22px 26px;
        }
        /* 圓圈章印：清・養・通 */
        .seal-stamp {
          position: relative;
          width: 48px; height: 48px; flex-shrink: 0;
          border-radius: 50%;
          display: flex; align-items: center; justify-content: center;
          font-family: var(--public-font);
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
        .formula-name { font-size: 17px; letter-spacing: 1.5px; color: #3d382f; font-weight: 500; line-height: 1.5; overflow-wrap: break-word; }
        .formula-sub { font-size: 13px; letter-spacing: 0.5px; color: #756b5b; font-weight: 400; line-height: 1.5; }
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
        .formula-body { overflow: hidden; }
        .formula-body[hidden] { display: none; }
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
          .formula-head { padding: 18px 16px; gap: 12px; }
          .seal-stamp { width: 44px; height: 44px; }
          .seal-stamp.seal-v90 { font-size: 20px; }
          .seal-stamp.seal-v120 { width: 48px; height: 48px; font-size: 21px; }
          .formula-name { font-size: 17px; letter-spacing: 1px; }
          .formula-sub { font-size: 13px; letter-spacing: 0.5px; }
          .formula-inner { padding: 18px 20px 22px; }
          .formula-steps { grid-template-columns: 1fr; gap: 11px; }
          .formula-step { font-size: 14px; }
        }
      `}</style>

      {/* ========== NAV ========== */}
      <nav ref={navRef} className="public-nav" style={{
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
              <button type="button" className="public-nav-link" key={key} onClick={() => key === "shop" ? onNavigateShop?.() : key === "contact" ? onNavigateContact?.() : scrollTo(key)} style={{
                cursor: "pointer", fontSize: "13px", letterSpacing: "2px",
                color: key === "booking" ? "#a3823f" : "rgba(74, 68, 58, 0.7)",
                transition: "color 0.3s", fontWeight: key === "booking" ? 600 : 400
              }}
              onMouseEnter={e => e.target.style.color = "#a3823f"}
              onMouseLeave={e => e.target.style.color = key === "booking" ? "#a3823f" : "rgba(74, 68, 58, 0.7)"}
              >{label}</button>
            ))}
            <button type="button" className="public-nav-link" onClick={() => { const newLang = lang === "zh" ? "en" : "zh"; setLang(newLang); onLangChange?.(newLang); }} style={{
              cursor: "pointer", fontSize: "12px", letterSpacing: "2px", padding: "5px 14px",
              border: "1px solid rgba(163,130,63,0.3)", color: "#a3823f", borderRadius: "2px", transition: "all 0.3s"
            }}
            onMouseEnter={e => e.target.style.background = "rgba(163,130,63,0.1)"}
            onMouseLeave={e => e.target.style.background = "transparent"}
            >{t.langSwitch}</button>
          </div>
          <button type="button" aria-label={lang === "zh" ? "開啟導覽選單" : "Open navigation menu"} aria-expanded={menuOpen} className="mobile-menu-btn" onClick={() => setMenuOpen(!menuOpen)} style={{
            cursor: "pointer", display: "none", flexDirection: "column", gap: "5px", padding: "4px"
          }}>
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", transform: menuOpen ? "rotate(45deg) translateY(6px)" : "none" }} />
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", opacity: menuOpen ? 0 : 1 }} />
            <div style={{ width: "24px", height: "1px", background: "#a3823f", transition: "all 0.3s", transform: menuOpen ? "rotate(-45deg) translateY(-6px)" : "none" }} />
          </button>
        </div>
        {menuOpen && (
          <div className="mobile-nav" style={{
            background: "rgba(242, 237, 228, 0.98)", backdropFilter: "blur(20px)",
            padding: "20px 30px 30px", display: "flex", flexDirection: "column", gap: "20px",
            borderBottom: "1px solid rgba(163,130,63,0.1)"
          }}>
            {Object.entries(t.nav).map(([key, label]) => (
              <button type="button" className="public-nav-link" key={key} onClick={() => { if (key === "shop") { onNavigateShop?.(); } else if (key === "contact") { onNavigateContact?.(); } else { scrollTo(key); } setMenuOpen(false); }} style={{ cursor: "pointer", fontSize: "15px", letterSpacing: "3px", color: "#4a443a", padding: "8px 0" }}>{label}</button>
            ))}
            <button type="button" className="public-nav-link" onClick={() => { const newLang = lang === "zh" ? "en" : "zh"; setLang(newLang); onLangChange?.(newLang); setMenuOpen(false); }} style={{ cursor: "pointer", fontSize: "13px", letterSpacing: "2px", color: "#a3823f", padding: "8px 0" }}>{t.langSwitch}</button>
          </div>
        )}
      </nav>

      {/* ========== LINE FLOATING BUTTON ========== */}
      <div className={`line-floating ${lineOverContent ? "over-content" : ""}`} style={{ position: "fixed", bottom: "30px", right: "30px", zIndex: 99, display: "flex", alignItems: "center", gap: "12px" }}>
        {showLineTooltip && (
          <div className="line-tooltip" style={{
            background: "white", border: "1px solid rgba(6,199,85,0.2)",
            padding: "10px 16px", borderRadius: "8px", fontSize: "13px", color: "#4a443a",
            boxShadow: "0 4px 15px rgba(0,0,0,0.08)",
            letterSpacing: "1px", whiteSpace: "normal", maxWidth: "min(220px, calc(100vw - 110px))", animation: "tooltipSlide 0.4s ease-out",
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
          {/* 實心綠圓中央只放白色 LINE 字樣；textIndent 補掉字距在尾字後的空隙，文字才真正置中 */}
          <span style={{
            color: "#fff",
            fontFamily: "'Helvetica Neue', Helvetica, Arial, sans-serif",
            fontSize: "15px", fontWeight: 700, lineHeight: 1,
            letterSpacing: "1.5px", textIndent: "1.5px"
          }}>LINE</span>
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

        {/* 首屏底部消融層：整幅寬度由透明漸濃，最底部落在 rgb(245,241,233)，
            即下方 SERVICES 的 rgba(255,255,255,0.2) 疊在 #f2ede4 上的實際色，
            兩區因此完全同色接合、看不出分界。多階停點避免色帶。
            置於粒子與墨暈之後、主內容（zIndex 1）之前，故「預約體驗」按鈕不受影響。 */}
        <div className="hero-fade-out" style={{
          position: "absolute", left: 0, right: 0, bottom: 0,
          height: "clamp(150px, 26vh, 220px)",
          pointerEvents: "none",
          background: "linear-gradient(180deg," +
            " rgba(245,241,233,0) 0%," +
            " rgba(245,241,233,0.10) 20%," +
            " rgba(245,241,233,0.28) 40%," +
            " rgba(245,241,233,0.52) 58%," +
            " rgba(245,241,233,0.72) 72%," +
            " rgba(245,241,233,0.88) 84%," +
            " rgba(245,241,233,0.97) 93%," +
            " rgb(245,241,233) 100%)"
        }} />

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

          {/* 棕色加粗副標：掃光 1.6 秒，停留 5 秒後再次由左至右掃過 */}
          <h1 className="animate-in-delay-1 hero-brand-block">
            <span className="hero-fancy">{t.brandSub}</span>
            <span className="hero-fancy">{t.hero.title}</span>
          </h1>

          {/* 裝飾線 */}
          <div className="animate-in-delay-2" style={{ marginBottom: "24px" }}>
            <GoldDivider plain />
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
            {lang === "zh" ? <>取東方養護之意，循舒緩調理之法<span className="mobile-break"><br /></span>由頭開始，漸入身心。</> : <>Inspired by Eastern care, guided by a gentle touch.<br />Relaxation begins with the head.</>}
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
              fontFamily: "var(--public-font)",
              whiteSpace: lang === "zh" ? "nowrap" : "normal", textAlign: "center"
            }}>{lang === "zh" ? "五感療癒" : "Care for the senses"}</h2>
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
            {lang === "zh" ? <>香和其息，音靜其神，觸柔其體，<span className="mobile-break"><br /></span>境緩其意，養歸於心。</> : <>Aroma, sound and a gentle touch.<br />A calm space to unwind.</>}
          </p>

          {/* CTA 按鈕 */}
          <div className="animate-in-delay-4 hero-actions" style={{ width: "100%" }}>
            <button className="gold-btn" onClick={() => scrollTo("booking")} style={{
              padding: "16px 48px",
              fontSize: "14px",
              letterSpacing: "4px",
              borderRadius: "2px"
            }}>{t.hero.cta}</button><button className="outline-btn" onClick={() => scrollTo('lookup')} style={{padding:'16px 32px',fontSize:14,borderRadius:2}}>{lang === 'zh' ? '查詢預約' : 'Find booking'}</button>
          </div>
        </div>
      </section>

      {/* ========== SERVICES ========== */}
      <section ref={sectionRefs.services} className="services-section" style={{
        padding: "120px 30px", position: "relative", overflow: "hidden",
        background: "rgba(255,255,255,0.2)"
      }}>
        <div style={{ maxWidth: "900px", margin: "0 auto", position: "relative", zIndex: 1 }}>
          <div style={{ textAlign: "center", marginBottom: "80px" }} className={`services-intro ${isAnimated("services") ? "animate-in" : ""}`}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>SERVICES</div>
            <h2 style={{ fontSize: lang === "zh" ? "clamp(28px, 4vw, 38px)" : "clamp(26px, 3.5vw, 36px)", fontWeight: 500, letterSpacing: lang === "zh" ? "6px" : "3px" }}>{t.services.title}</h2>
            <GoldDivider />
            <p style={{ fontSize: "12px", letterSpacing: "2px", color: "rgba(74,68,58,0.5)", marginTop: "4px" }}>
              {lang === "zh" ? "點擊療程，查看完整內容" : "Tap a therapy to see the full ritual"}
            </p>
          </div>

          {websiteServices.map((service,groupIndex)=>{
            const rituals=serviceRituals(service);
            return <div key={service.id} style={{marginBottom:groupIndex===websiteServices.length-1?'40px':'70px'}} className={`service-group ${isAnimated("services")?`animate-in-delay-${Math.min(groupIndex+1,4)}`:""}`}>
              <div className="service-heading"><h3 className="service-name">{publicName(service,lang)}</h3><span className="service-price">{money(service.price_cents)}</span></div>
              <div className="service-vertical-list formula-list" style={{maxWidth:"520px",margin:"0 auto"}}>
                {rituals.map((ritual,index)=>{const key=`${service.code}-${index}`;return <FormulaCard key={key} stamp={ritual.stamp} name={ritual.name} sub={ritual.sub} steps={ritual.steps||[]} variant={service.duration_minutes>=120?'v120':''} isOpen={openFormula===key} onToggle={()=>toggleFormula(key)}/>;})}
                {!rituals.length&&<p className="service-contact">{lang==='zh'?(service.description||'療程內容請洽門店'):(service.description_en||'Contact us for treatment details')}</p>}
              </div>
            </div>;
          })}
          <p className="service-contact"><a href={CONFIG.LINE_URL} target="_blank" rel="noopener noreferrer">{lang === "zh" ? "療程諮詢 · 聯絡 LINE" : "Questions about treatments? Contact us on LINE"} ↗</a></p>
        </div>
      </section>

      {/* ========== BOOKING ========== */}
      <section id="booking" className="booking-section" ref={sectionRefs.booking} style={{
        padding: "120px 30px", position: "relative", overflow: "hidden",
        background: "rgba(255,255,255,0.3)"
      }}>
        <div className="booking-content" style={{ maxWidth: "700px", margin: "0 auto", position: "relative", zIndex: 1 }}>
          <div ref={bookingAnchor} className="booking-anchor" />
          <div style={{ textAlign: "center", marginBottom: "50px" }} className={isAnimated("booking") ? "animate-in" : ""}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>RESERVATION</div>
            <h2 style={{ fontSize: lang === "zh" ? "clamp(28px, 4vw, 38px)" : "clamp(26px, 3.5vw, 36px)", fontWeight: 500, letterSpacing: lang === "zh" ? "6px" : "3px" }}>{t.booking.title}</h2>
            <GoldDivider />
            <p style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.6)", letterSpacing: "3px" }}>{t.booking.subtitle}</p>
          </div>

          <div className="booking-mode" role="tablist" aria-label={lang === 'zh' ? '預約功能' : 'Booking options'}><button role="tab" aria-selected={bookingMode === 'new'} onClick={() => setBookingMode('new')}>{lang === 'zh' ? '新增預約' : 'New booking'}</button><button role="tab" aria-selected={bookingMode === 'lookup'} onClick={() => setBookingMode('lookup')}>{lang === 'zh' ? '查詢預約' : 'Find booking'}</button></div>
          {bookingMode === 'lookup' ? <BookingLookup lang={lang}/> : <>
          {(catalogError || slotError) && <p role="alert" style={{ color: "#b5523b", textAlign: "center", marginBottom: 20 }}>{catalogError || slotError}</p>}
          {!catalog && !catalogError && <p style={{ textAlign: "center" }}>{lang === "zh" ? "正在載入預約服務…" : "Loading booking services…"}</p>}
          {!bookingComplete && (
            <div className="booking-progress" style={{ display: "flex", alignItems: "center", justifyContent: "center", gap: "12px", marginBottom: "50px" }}>
              {t.booking.steps.map((step, i) => (
                <div key={i} className="booking-progress-item" style={{ display: "flex", alignItems: "center", gap: "12px" }}>
                  <div style={{ display: "flex", flexDirection: "column", alignItems: "center", gap: "8px" }}>
                    <div className={`step-dot ${i < bookingStep ? "completed" : ""} ${i === bookingStep ? "active" : ""}`} />
                    <span style={{ fontSize: "10px", letterSpacing: "1px", color: i <= bookingStep ? "#a3823f" : "rgba(0,0,0,0.2)", whiteSpace: "nowrap", fontWeight: 500 }}>{step}</span>
                  </div>
                  {i < t.booking.steps.length - 1 && <div className="booking-progress-connector" style={{ width: "30px", height: "1px", background: i < bookingStep ? "rgba(163,130,63,0.3)" : "rgba(0,0,0,0.1)", marginBottom: "20px" }} />}
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
              <p style={{ fontSize: "22px", color: "#a3823f", letterSpacing: "3px", marginBottom: "12px", fontWeight: 600 }}>{receipt?.status === "pending" ? (lang === "zh" ? "預約已送出，等待門店確認" : "Booking received, awaiting confirmation") : t.booking.success}</p>
              <p style={{ fontSize: "14px", color: "rgba(74, 68, 58, 0.7)", marginBottom: "20px", lineHeight: 1.8 }}>{receipt?.reference}<br />{t.booking.successSub}</p>
              <a href={`#manage/${receipt?.manage_token}`} style={{ color: "#a3823f", display: "block", marginBottom: 24 }}>{lang === "zh" ? "查看、取消或改期（請保存此私人連結）" : "Manage booking — save this private link"}</a>
              <div style={{ background: "white", borderRadius: "8px", padding: "28px", marginBottom: "36px", boxShadow: "0 4px 15px rgba(0,0,0,0.05)" }}>
                <p style={{ fontSize: "13px", color: "rgba(74, 68, 58, 0.7)", letterSpacing: "1px", marginBottom: "18px", lineHeight: 1.8 }}>{t.booking.successLine}</p>
                <a href={CONFIG.LINE_URL} target="_blank" rel="noopener noreferrer" style={{ textDecoration: "none" }}>
                  <button className="line-btn" style={{ padding: "12px 32px", fontSize: "14px", borderRadius: "6px" }}><LineIcon /> {t.booking.addLine}</button>
                </a>
              </div>
              <button className="outline-btn" onClick={resetBooking} style={{ padding: "12px 36px", fontSize: "13px", borderRadius: "2px" }}>{lang === "zh" ? "重新預約" : "Book again"}</button>
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
                    {services.map((service, i) => (
                      <div key={i}
                        role="button" tabIndex={0} aria-pressed={selectedService === i} onKeyDown={e => { if(e.key === "Enter" || e.key === " ") { e.preventDefault(); setSelectedService(i); setSelectedTherapist(null); } }}
                        className={`service-card booking-option-card ${selectedService === i ? "selected" : ""}`}
                        onClick={() => { setSelectedService(i); setSelectedTherapist(null); }}
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
                        }}>{lang === "en" ? service.name_en || service.name : service.name}</div>
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
                    <div role="button" tabIndex={0} aria-pressed={selectedTherapist === -1} onKeyDown={e => { if(e.key === "Enter" || e.key === " ") { e.preventDefault(); setSelectedTherapist(-1); } }} className={`therapist-card ${selectedTherapist === -1 ? "selected" : ""}`} onClick={() => setSelectedTherapist(-1)}
                      style={{ padding: "28px 20px", borderRadius: "4px", textAlign: "center" }}>
                      <div style={{ width: "56px", height: "56px", borderRadius: "50%", margin: "0 auto 14px", background: "rgba(163,130,63,0.08)", border: "1px solid rgba(163,130,63,0.1)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "20px", color: "#a3823f" }}>✦</div>
                      <div style={{ fontSize: "14px", letterSpacing: "2px", color: "#a3823f", fontWeight: 500 }}>{t.booking.anyTherapist}</div>
                    </div>
                    {therapists.map((m) => (
                      <div key={m.id} role="button" tabIndex={0} aria-pressed={selectedTherapist === m.id} onKeyDown={e => { if(e.key === "Enter" || e.key === " ") { e.preventDefault(); setSelectedTherapist(m.id); } }} className={`therapist-card ${selectedTherapist === m.id ? "selected" : ""}`} onClick={() => setSelectedTherapist(m.id)}
                        style={{ padding: "28px 20px", borderRadius: "4px", textAlign: "center" }}>
                        <div style={{ width: "56px", height: "56px", borderRadius: "50%", margin: "0 auto 14px", background: `linear-gradient(135deg, rgba(163,130,63,0.15), rgba(255,255,255,0.5))`, border: "1px solid rgba(163,130,63,0.1)", display: "flex", alignItems: "center", justifyContent: "center", fontSize: "18px", color: "#a3823f", fontWeight: 600 }}>{m.name.charAt(0)}</div>
                        <div style={{ fontSize: "14px", fontWeight: 600, letterSpacing: "2px", marginBottom: "4px", color: "#4a443a" }}>{publicName(m, lang)}</div>
                        <div style={{ fontSize: "11px", color: "rgba(74, 68, 58, 0.6)" }}>{lang === "zh" ? m.specialty : m.title === "首席調理師" ? "Lead therapist" : m.title === "資深調理師" ? "Senior therapist" : "Therapist"}</div>
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
                        const d = new Date(`${date}T12:00:00Z`);
                        const wd = lang === "zh" ? ["日","一","二","三","四","五","六"][d.getUTCDay()] : ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"][d.getUTCDay()];
                        return (
                          <div key={date} role="button" tabIndex={0} aria-label={date} onKeyDown={e=>{if(e.key === "Enter" || e.key === " "){e.preventDefault();setSelectedDate(date);}}} className={`time-chip ${selectedDate === date ? "selected" : ""}`} onClick={() => setSelectedDate(date)}
                            style={{ padding: "12px 16px", borderRadius: "4px", textAlign: "center", minWidth: "70px" }}>
                            <div style={{ fontSize: "11px", marginBottom: "4px", opacity: 0.8 }}>{wd}</div>
                            <div style={{ fontSize: "15px", fontWeight: 600 }}>{d.getUTCDate()}</div>
                          </div>
                        );
                      })}
                    </div>
                  </div>
                  <label style={{display:"block",fontSize:12,color:"#a3823f",marginBottom:24}}>{lang === "zh" ? "其他日期（含今日）" : "Another date (including today)"}<input aria-label={lang === "zh" ? "其他預約日期" : "Another booking date"} type="date" value={selectedDate} min={taipeiDate()} max={dateAfter(catalog?.settings.booking_days || 30)} onChange={e=>setSelectedDate(e.target.value)} style={{marginTop:10,maxWidth:260}} /></label>
                  {selectedDate && (
                    <div style={{ animation: "fadeInUp 0.4s ease-out" }}>
                      <label style={{ display: "block", fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "16px", fontWeight: 600 }}>{t.booking.selectTime}</label>
                      {loadingSlots ? (
                        <div style={{ textAlign: "center", padding: "30px", color: "rgba(74, 68, 58, 0.5)", fontSize: "13px" }}>{lang === "zh" ? "正在查詢可用時段…" : "Loading…"}</div>
                      ) : (
                      <>
                      {Object.entries(timeSlots).map(([period, slots]) => (
                        <div key={period} style={{ marginBottom: "20px" }}>
                          <div style={{ fontSize: "11px", color: "rgba(74, 68, 58, 0.5)", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>{t.booking[period]}</div>
                          <div style={{ display: "flex", gap: "8px", flexWrap: "wrap" }}>
                            {slots.map(time => {
                              const booked = !time.available;
                              return (
                                <div key={time.starts_at} role="button" tabIndex={booked ? -1 : 0} aria-disabled={booked} aria-pressed={selectedTime === time.starts_at} onKeyDown={e => { if(!booked && (e.key === "Enter" || e.key === " ")) { e.preventDefault(); setSelectedTime(time.starts_at); } }} className={`time-chip ${selectedTime === time.starts_at ? "selected" : ""} ${booked ? "booked" : ""}`}
                                  onClick={() => !booked && setSelectedTime(time.starts_at)}
                                  style={{ padding: "10px 18px", borderRadius: "3px", opacity: booked ? 0.4 : 1, cursor: booked ? "not-allowed" : "pointer" }}>
                                  {slotLabel(time.time_label, lang)}
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
                    <button className="gold-btn" disabled={!selectedDate || !selectedTime || loadingSlots || !!slotError} onClick={() => selectedDate && selectedTime && setBookingStep(3)}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.next}</button>
                  </div>
                </div>
              )}
              {bookingStep === 3 && (
                <div>
                  <div style={{ background: "rgba(255,255,255,0.5)", border: "1px solid rgba(163,130,63,0.1)", borderRadius: "4px", padding: "28px", marginBottom: "36px" }}>
                    <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "16px", fontWeight: 600 }}>{lang === "zh" ? "預約摘要" : "Booking summary"}</div>
                    <div style={{ display: "grid", gap: "12px" }}>
                      {[
                        [lang === "zh" ? "服務" : "Service", publicName(services[selectedService], lang)],
                        [lang === "zh" ? "技師" : "Therapist", selectedTherapist === -1 ? t.booking.anyTherapist : publicName(therapists.find(m => m.id === selectedTherapist), lang)],
                        [lang === "zh" ? "日期" : "Date", selectedDate],
                        [lang === "zh" ? "時間" : "Time", slotLabel(bookedSlots.find(s => s.starts_at === selectedTime)?.time_label, lang)],
                        [lang === "zh" ? "費用" : "Price", money(services[selectedService]?.price_cents || 0)],
                      ].map(([label, val], i) => (
                        <div key={i} style={{ display: "flex", justifyContent: "space-between", fontSize: "14px" }}>
                          <span style={{ color: "rgba(74, 68, 58, 0.6)" }}>{label}</span>
                          <span style={{ color: "#4a443a", fontWeight: 600 }}>{val}</span>
                        </div>
                      ))}
                    </div>
                  </div>
                  <div style={{ display: "flex", flexDirection: "column", gap: "20px", marginBottom: "40px" }}>
                    <input value={formName} onChange={e => setFormName(e.target.value)} maxLength={80} aria-label={t.booking.name} autoComplete="name" placeholder={lang === "zh" ? "您的姓名" : t.booking.name} />
                    <input value={formPhone} onChange={e => setFormPhone(e.target.value)} type="tel" maxLength={25} aria-label={t.booking.phone} autoComplete="tel" placeholder={lang === "zh" ? "您的手機號碼" : t.booking.phone} />
                    <textarea value={formNote} onChange={e => setFormNote(e.target.value)} maxLength={1000} rows={3} aria-label={t.booking.note} placeholder={t.booking.note} />
                  </div>
                  <div style={{ display: "flex", justifyContent: "center", gap: "20px" }}>
                    <button className="outline-btn" onClick={() => setBookingStep(2)} style={{ padding: "14px 36px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>{t.booking.prev}</button>
                    <button className="gold-btn" disabled={!formName.trim() || !formPhone.trim() || submitting || !selectedTime} onClick={handleSubmitBooking}
                      style={{ padding: "14px 48px", fontSize: "13px", letterSpacing: "3px", borderRadius: "2px" }}>
                      {submitting ? t.booking.submitting : t.booking.confirm}
                    </button>
                  </div>
                </div>
              )}
            </div>
          )}
          </>}
        </div>
      </section>

      <div style={{ textAlign: "center", padding: 20, background: "#f2ede4" }}><a href="#member" style={{ color: "#a3823f", fontSize: 13 }}>{lang === "zh" ? "會員中心 · 查看儲值餘額與療程記錄" : "Member centre · Balance and visit history (Chinese)"}</a></div>

      {/* ========== FEEDBACK（匿名意見回饋） ========== */}
      <FeedbackSection t={t} />
      <PublishedReviews lang={lang} />

      {/* ========== LOCATION ========== */}
      <section ref={sectionRefs.location} style={{ padding: "100px 30px 80px", background: "white" }}>
        <div style={{ maxWidth: "1100px", margin: "0 auto" }}>
          <div style={{ textAlign: "center", marginBottom: "50px" }}>
            <div style={{ fontSize: "11px", letterSpacing: "6px", color: "rgba(163,130,63,0.6)", marginBottom: "16px" }}>LOCATION</div>
            <h2 style={{ fontSize: "32px", fontWeight: 500, color: "#4a443a" }}>{lang === "zh" ? "交通位置" : "Find us"}</h2>
            <GoldDivider />
          </div>
          <div className="location-grid">
            <div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>{lang === "zh" ? "地址" : "Address"}</div>
                <p style={{ fontSize: "15px", color: "#4a443a" }}>{t.footer.address}</p>
              </div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>{lang === "zh" ? "營業時間" : "Opening hours"}</div>
                <p style={{ fontSize: "15px", color: "#4a443a" }}>{hoursText(catalog?.settings, lang)}</p>
              </div>
              <div style={{ marginBottom: "28px" }}>
                <div style={{ fontSize: "12px", color: "#a3823f", letterSpacing: "2px", marginBottom: "10px", fontWeight: 600 }}>{lang === "zh" ? "預約電話" : "Phone"}</div>
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
      <footer style={{ padding: "44px 30px 38px", borderTop: "1px solid rgba(163,130,63,0.1)", textAlign: "center" }}>
        {/* textIndent 補掉字距在尾字後的空隙，字串才會真正對齊中軸 */}
        <div style={{ fontSize: "16px", fontWeight: 600, color: "#a3823f", letterSpacing: "6px", textIndent: "6px" }}>{t.brand}</div>
        <div style={{ fontSize: "12px", color: "rgba(74, 68, 58, 0.5)", letterSpacing: "1px", textIndent: "1px", marginTop: "18px" }}>{t.footer.copyright}</div>
      </footer>
    </div>
  );
}
