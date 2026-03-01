import { useState, useEffect } from "react";

// ⚠️ 确保这里的值和 App.jsx 里的 CONFIG 一致
const CONFIG = {
  SUPABASE_URL: "https://etiggwqxacnlrgokfsjt.supabase.co/",
  SUPABASE_ANON_KEY: "etiggwqxacnlrgokfsjt",
};

const THERAPISTS = ["林雅芳", "陳柏翰", "王詩涵", "張家豪"];
const THERAPIST_COLORS = ["#e8935a", "#5a9ee8", "#9ee85a", "#e85aab"];

export default function AdminDashboard() {
  const [authenticated, setAuthenticated] = useState(false);
  const [password, setPassword] = useState("");
  const [bookings, setBookings] = useState([]);
  const [loading, setLoading] = useState(false);
  const [selectedDate, setSelectedDate] = useState(() => {
    const d = new Date(); d.setDate(d.getDate() + 1);
    return d.toISOString().split("T")[0];
  });
  const [filterTherapist, setFilterTherapist] = useState("all");
  const [view, setView] = useState("schedule"); // schedule | list

  // 简单密码保护（你可以改成你自己的密码）
  const ADMIN_PASSWORD = "rouhe2026";

  const handleLogin = () => {
    if (password === ADMIN_PASSWORD) {
      setAuthenticated(true);
    } else {
      alert("密碼錯誤");
    }
  };

  // 加载预约数据
  const fetchBookings = async () => {
    setLoading(true);
    try {
      const res = await fetch(
        `${CONFIG.SUPABASE_URL}/rest/v1/bookings?booking_date=eq.${selectedDate}&order=booking_time.asc`,
        {
          headers: {
            apikey: CONFIG.SUPABASE_ANON_KEY,
            Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
          },
        }
      );
      if (res.ok) {
        const data = await res.json();
        setBookings(data);
      }
    } catch (err) {
      console.error("Failed to fetch bookings:", err);
    }
    setLoading(false);
  };

  // 取消预约
  const cancelBooking = async (id) => {
    if (!confirm("確定要取消這筆預約嗎？")) return;
    try {
      await fetch(`${CONFIG.SUPABASE_URL}/rest/v1/bookings?id=eq.${id}`, {
        method: "PATCH",
        headers: {
          "Content-Type": "application/json",
          apikey: CONFIG.SUPABASE_ANON_KEY,
          Authorization: `Bearer ${CONFIG.SUPABASE_ANON_KEY}`,
        },
        body: JSON.stringify({ status: "cancelled" }),
      });
      fetchBookings();
    } catch (err) {
      console.error("Failed to cancel:", err);
    }
  };

  useEffect(() => {
    if (authenticated) fetchBookings();
  }, [authenticated, selectedDate]);

  // 生成接下来14天
  const getDateOptions = () => {
    const days = [];
    const today = new Date();
    for (let i = 0; i <= 14; i++) {
      const d = new Date(today); d.setDate(today.getDate() + i);
      days.push(d.toISOString().split("T")[0]);
    }
    return days;
  };

  const timeSlots = [
    "10:00","10:30","11:00","11:30",
    "13:00","13:30","14:00","14:30","15:00","15:30","16:00","16:30",
    "17:00","17:30","18:00","18:30","19:00","19:30","20:00"
  ];

  const getBookingAt = (therapistIdx, time) => {
    return bookings.find(
      b => b.therapist_index === therapistIdx && b.booking_time === time && b.status === "confirmed"
    );
  };

  const filteredBookings = bookings.filter(b => {
    if (filterTherapist === "all") return true;
    return b.therapist_index === parseInt(filterTherapist);
  });

  const confirmedCount = bookings.filter(b => b.status === "confirmed").length;
  const cancelledCount = bookings.filter(b => b.status === "cancelled").length;

  // Login screen
  if (!authenticated) {
    return (
      <div style={{ fontFamily: "'Noto Serif TC', Georgia, serif", background: "#0a0a08", color: "#e8e0d0", minHeight: "100vh", display: "flex", alignItems: "center", justifyContent: "center" }}>
        <style>{`@import url('https://fonts.googleapis.com/css2?family=Noto+Serif+TC:wght@300;400;500;600&display=swap');`}</style>
        <div style={{ textAlign: "center", maxWidth: "360px", padding: "40px" }}>
          <div style={{ fontSize: "28px", color: "#c9a96e", letterSpacing: "6px", marginBottom: "8px" }}>柔禾養生</div>
          <div style={{ fontSize: "12px", color: "rgba(201,169,110,0.4)", letterSpacing: "3px", marginBottom: "40px" }}>管理後台</div>
          <input
            type="password" value={password} onChange={e => setPassword(e.target.value)}
            onKeyDown={e => e.key === "Enter" && handleLogin()}
            placeholder="請輸入管理密碼"
            style={{
              width: "100%", padding: "14px 18px", background: "rgba(201,169,110,0.04)",
              border: "1px solid rgba(201,169,110,0.15)", color: "#e8e0d0", borderRadius: "4px",
              fontSize: "15px", outline: "none", marginBottom: "20px", fontFamily: "inherit"
            }}
          />
          <button onClick={handleLogin} style={{
            width: "100%", padding: "14px", background: "linear-gradient(135deg, #c9a96e, #a3823f)",
            color: "#0a0a08", border: "none", borderRadius: "4px", fontSize: "14px",
            fontWeight: 500, letterSpacing: "3px", cursor: "pointer", fontFamily: "inherit"
          }}>登入</button>
        </div>
      </div>
    );
  }

  return (
    <div style={{ fontFamily: "'Noto Serif TC', Georgia, serif", background: "#0a0a08", color: "#e8e0d0", minHeight: "100vh", padding: "20px" }}>
      <style>{`
        @import url('https://fonts.googleapis.com/css2?family=Noto+Serif+TC:wght@300;400;500;600&display=swap');
        * { margin: 0; padding: 0; box-sizing: border-box; }
        .admin-btn { padding: 8px 16px; border: 1px solid rgba(201,169,110,0.2); background: transparent; color: #c9a96e; cursor: pointer; border-radius: 3px; font-family: inherit; font-size: 12px; letter-spacing: 1px; transition: all 0.3s; }
        .admin-btn:hover { background: rgba(201,169,110,0.1); }
        .admin-btn.active { background: rgba(201,169,110,0.15); border-color: #c9a96e; }
        .admin-btn.danger { border-color: rgba(255,100,100,0.3); color: #ff6b6b; }
        .admin-btn.danger:hover { background: rgba(255,100,100,0.1); }
      `}</style>

      {/* Header */}
      <div style={{ maxWidth: "1200px", margin: "0 auto", marginBottom: "30px" }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "16px" }}>
          <div>
            <span style={{ fontSize: "20px", color: "#c9a96e", letterSpacing: "4px" }}>柔禾養生</span>
            <span style={{ fontSize: "12px", color: "rgba(201,169,110,0.4)", marginLeft: "16px", letterSpacing: "2px" }}>管理後台</span>
          </div>
          <div style={{ display: "flex", gap: "10px", alignItems: "center", flexWrap: "wrap" }}>
            <button className={`admin-btn ${view === "schedule" ? "active" : ""}`} onClick={() => setView("schedule")}>排班表</button>
            <button className={`admin-btn ${view === "list" ? "active" : ""}`} onClick={() => setView("list")}>預約列表</button>
            <button className="admin-btn" onClick={() => setAuthenticated(false)}>登出</button>
          </div>
        </div>
      </div>

      <div style={{ maxWidth: "1200px", margin: "0 auto" }}>
        {/* Date selector & stats */}
        <div style={{ display: "flex", gap: "20px", marginBottom: "24px", flexWrap: "wrap", alignItems: "center" }}>
          <div>
            <label style={{ fontSize: "12px", color: "rgba(201,169,110,0.5)", letterSpacing: "1px", marginRight: "10px" }}>日期</label>
            <select value={selectedDate} onChange={e => setSelectedDate(e.target.value)}
              style={{ padding: "8px 12px", background: "rgba(201,169,110,0.06)", border: "1px solid rgba(201,169,110,0.15)", color: "#e8e0d0", borderRadius: "3px", fontSize: "14px", fontFamily: "inherit" }}>
              {getDateOptions().map(d => {
                const dt = new Date(d);
                const wd = ["日","一","二","三","四","五","六"][dt.getDay()];
                return <option key={d} value={d}>{d} (週{wd})</option>;
              })}
            </select>
          </div>
          <div style={{ display: "flex", gap: "16px", fontSize: "13px" }}>
            <span style={{ color: "rgba(201,169,110,0.6)" }}>已確認: <span style={{ color: "#c9a96e", fontWeight: 500 }}>{confirmedCount}</span></span>
            <span style={{ color: "rgba(150,150,150,0.5)" }}>已取消: {cancelledCount}</span>
          </div>
          {loading && <span style={{ fontSize: "12px", color: "rgba(201,169,110,0.3)" }}>載入中...</span>}
        </div>

        {/* ===== SCHEDULE VIEW ===== */}
        {view === "schedule" && (
          <div style={{ overflowX: "auto" }}>
            <table style={{ width: "100%", borderCollapse: "collapse", minWidth: "600px" }}>
              <thead>
                <tr>
                  <th style={{ padding: "12px 16px", textAlign: "left", fontSize: "12px", color: "rgba(201,169,110,0.5)", letterSpacing: "1px", borderBottom: "1px solid rgba(201,169,110,0.1)", width: "80px" }}>時段</th>
                  {THERAPISTS.map((name, i) => (
                    <th key={i} style={{ padding: "12px 16px", textAlign: "center", fontSize: "13px", color: THERAPIST_COLORS[i], letterSpacing: "1px", borderBottom: "1px solid rgba(201,169,110,0.1)" }}>
                      {name}
                    </th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {timeSlots.map(time => (
                  <tr key={time} style={{ borderBottom: "1px solid rgba(201,169,110,0.04)" }}>
                    <td style={{ padding: "10px 16px", fontSize: "13px", color: "rgba(201,169,110,0.6)", fontFamily: "'Cormorant Garamond', serif", fontWeight: 500 }}>{time}</td>
                    {THERAPISTS.map((_, ti) => {
                      const booking = getBookingAt(ti, time);
                      return (
                        <td key={ti} style={{ padding: "6px 10px", textAlign: "center" }}>
                          {booking ? (
                            <div style={{
                              background: `rgba(${THERAPIST_COLORS[ti] === "#e8935a" ? "232,147,90" : THERAPIST_COLORS[ti] === "#5a9ee8" ? "90,158,232" : THERAPIST_COLORS[ti] === "#9ee85a" ? "158,232,90" : "232,90,171"},0.12)`,
                              border: `1px solid rgba(${THERAPIST_COLORS[ti] === "#e8935a" ? "232,147,90" : THERAPIST_COLORS[ti] === "#5a9ee8" ? "90,158,232" : THERAPIST_COLORS[ti] === "#9ee85a" ? "158,232,90" : "232,90,171"},0.25)`,
                              borderRadius: "4px", padding: "8px", position: "relative"
                            }}>
                              <div style={{ fontSize: "12px", fontWeight: 500, marginBottom: "2px" }}>{booking.customer_name}</div>
                              <div style={{ fontSize: "10px", color: "rgba(232,224,208,0.4)" }}>{booking.service}</div>
                              <div style={{ fontSize: "10px", color: "rgba(232,224,208,0.3)", marginTop: "2px" }}>{booking.phone}</div>
                              <button className="admin-btn danger" onClick={() => cancelBooking(booking.id)}
                                style={{ position: "absolute", top: "4px", right: "4px", padding: "2px 6px", fontSize: "10px" }}>✕</button>
                            </div>
                          ) : (
                            <div style={{ fontSize: "11px", color: "rgba(201,169,110,0.08)" }}>—</div>
                          )}
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {/* ===== LIST VIEW ===== */}
        {view === "list" && (
          <div>
            <div style={{ marginBottom: "16px" }}>
              <label style={{ fontSize: "12px", color: "rgba(201,169,110,0.5)", letterSpacing: "1px", marginRight: "10px" }}>技師篩選</label>
              <select value={filterTherapist} onChange={e => setFilterTherapist(e.target.value)}
                style={{ padding: "8px 12px", background: "rgba(201,169,110,0.06)", border: "1px solid rgba(201,169,110,0.15)", color: "#e8e0d0", borderRadius: "3px", fontSize: "13px", fontFamily: "inherit" }}>
                <option value="all">全部技師</option>
                {THERAPISTS.map((name, i) => <option key={i} value={i}>{name}</option>)}
              </select>
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: "12px" }}>
              {filteredBookings.length === 0 && (
                <div style={{ textAlign: "center", padding: "40px", color: "rgba(201,169,110,0.2)", fontSize: "14px" }}>該日期暫無預約</div>
              )}
              {filteredBookings.map(b => (
                <div key={b.id} style={{
                  background: b.status === "cancelled" ? "rgba(80,80,80,0.05)" : "rgba(201,169,110,0.03)",
                  border: `1px solid ${b.status === "cancelled" ? "rgba(80,80,80,0.1)" : "rgba(201,169,110,0.1)"}`,
                  borderRadius: "6px", padding: "18px 22px",
                  opacity: b.status === "cancelled" ? 0.5 : 1,
                  display: "flex", justifyContent: "space-between", alignItems: "center", flexWrap: "wrap", gap: "12px"
                }}>
                  <div style={{ flex: 1, minWidth: "200px" }}>
                    <div style={{ display: "flex", alignItems: "center", gap: "12px", marginBottom: "6px" }}>
                      <span style={{ fontSize: "15px", fontWeight: 500 }}>{b.customer_name}</span>
                      <span style={{
                        fontSize: "10px", padding: "2px 8px", borderRadius: "2px",
                        background: b.status === "confirmed" ? "rgba(107,142,35,0.12)" : "rgba(255,100,100,0.1)",
                        color: b.status === "confirmed" ? "#8fac50" : "#ff6b6b",
                        border: `1px solid ${b.status === "confirmed" ? "rgba(107,142,35,0.2)" : "rgba(255,100,100,0.2)"}`
                      }}>{b.status === "confirmed" ? "已確認" : "已取消"}</span>
                    </div>
                    <div style={{ fontSize: "12px", color: "rgba(201,169,110,0.5)", display: "flex", gap: "16px", flexWrap: "wrap" }}>
                      <span>⏰ {b.booking_time}</span>
                      <span>💆 {b.therapist}</span>
                      <span>📋 {b.service}</span>
                      {b.tea && <span>🍵 {b.tea}</span>}
                    </div>
                    <div style={{ fontSize: "12px", color: "rgba(201,169,110,0.3)", marginTop: "4px" }}>
                      📱 {b.phone} {b.note && `· 📝 ${b.note}`}
                    </div>
                  </div>
                  {b.status === "confirmed" && (
                    <button className="admin-btn danger" onClick={() => cancelBooking(b.id)}>取消預約</button>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
