import React, { useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
import BookingLookup from './BookingLookup.jsx';
import './responsive.css';
import './public-theme.css';
const Admin = React.lazy(() => import('./Admin.jsx'));
const Shop = React.lazy(() => import('./Shop.jsx'));
const Contact = React.lazy(() => import('./Contact.jsx'));
const Member = React.lazy(() => import('./Member.jsx'));
const BookingPortal = React.lazy(() => import('./BookingPortal.jsx'));

// 路由：
// https://rouspa.tw/           → 客人网站
// https://rouspa.tw/#shop      → 產品展示
// https://rouspa.tw/#contact   → 聯繫我們
// https://rouspa.tw/#admin     → 管理后台
function Router() {
  const [route, setRoute] = useState(window.location.hash);
  const [lang, setLang] = useState(() => { try { return localStorage.getItem('rouspa-language') === 'en' ? 'en' : 'zh'; } catch { return 'zh'; } });
  useEffect(() => {
    try { localStorage.setItem('rouspa-language', lang); } catch {}
    const chineseOnly = ['#admin'].includes(route);
    document.documentElement.lang = !chineseOnly && lang === 'en' ? 'en' : 'zh-Hant';
    document.title = !chineseOnly && lang === 'en' ? 'ROU SPA | Head therapy · Meridian relaxation' : '柔療髮浴 | 東方頭療 · 經絡舒緩';
  }, [lang, route]);

  useEffect(() => {
    const handleHash = () => {
      setRoute(window.location.hash);
      window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
    };
    window.addEventListener("hashchange", handleHash);
    return () => window.removeEventListener("hashchange", handleHash);
  }, []);

  const navigateTo = (hash) => {
    window.location.hash = hash;
  };

  if (route === "#lookup") return <BookingLookup standalone lang={lang} />;
  if (route === "#member") return <Member lang={lang} />;
  if (route.startsWith("#manage/")) return <BookingPortal token={route.slice(8)} lang={lang} />;
  if (route.startsWith("#review/")) return <BookingPortal token={route.slice(8)} review lang={lang} />;
  if (route === "#admin") {
    return <Admin />;
  }
  if (route === "#shop") {
    return <Shop lang={lang} onNavigateHome={() => navigateTo("")} />;
  }
  if (route === "#contact") {
    return <Contact lang={lang} onNavigateHome={() => navigateTo("")} />;
  }
  return <App lang={lang} onNavigateShop={() => navigateTo("shop")} onNavigateContact={() => navigateTo("contact")} onLangChange={setLang} />;
}

ReactDOM.createRoot(document.getElementById('root')).render(<React.Suspense fallback={<div style={{padding:40,textAlign:"center"}}>載入中…</div>}><Router /></React.Suspense>);
