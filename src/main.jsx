import React, { useState, useEffect, useRef } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
import BookingLookup from './BookingLookup.jsx';
import { applySeo, routeFromLocation } from './lib/seo.js';
import { createRebookingIntent } from './lib/rebooking.js';
import './responsive.css';
import './public-theme.css';
import './public-navigation.css';
const Admin = React.lazy(() => import('./Admin.jsx'));
const Services = React.lazy(() => import('./Services.jsx'));
const Shop = React.lazy(() => import('./Shop.jsx'));
const Contact = React.lazy(() => import('./Contact.jsx'));
const Member = React.lazy(() => import('./Member.jsx'));
const BookingPortal = React.lazy(() => import('./BookingPortal.jsx'));

// 路由：
// https://www.rouspa.tw/          → 客人網站
// https://www.rouspa.tw/shop/     → 產品展示（可被搜尋引擎索引）
// https://www.rouspa.tw/contact/  → 聯繫我們（可被搜尋引擎索引）
// https://www.rouspa.tw/#admin    → 管理後台（noindex）
function Router() {
  const [route, setRoute] = useState(() => routeFromLocation());
  const [rebookingIntent, setRebookingIntent] = useState(null), rebookingSequence = useRef(0);
  const [lang, setLang] = useState(() => { try { return localStorage.getItem('rouspa-language') === 'en' ? 'en' : 'zh'; } catch { return 'zh'; } });
  useEffect(() => {
    try { localStorage.setItem('rouspa-language', lang); } catch {}
    applySeo(route, lang);
  }, [lang, route]);

  useEffect(() => {
    if (window.location.hash === '#shop' || window.location.hash === '#contact') {
      const cleanPath = window.location.hash === '#shop' ? '/shop/' : '/contact/';
      window.history.replaceState({}, '', cleanPath);
    }
    const syncRoute = () => {
      setRoute(routeFromLocation());
      window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
    };
    syncRoute();
    window.addEventListener('hashchange', syncRoute);
    window.addEventListener('popstate', syncRoute);
    return () => { window.removeEventListener('hashchange', syncRoute); window.removeEventListener('popstate', syncRoute); };
  }, []);

  const navigateTo = (path) => {
    window.history.pushState({}, '', path);
    setRoute(routeFromLocation());
    window.scrollTo({ top: 0, left: 0, behavior: 'instant' });
  };
  const rebook = (booking) => {
    const intent = createRebookingIntent(booking);
    if (!intent) return;
    setRebookingIntent({ ...intent, id: ++rebookingSequence.current });
    navigateTo('/#booking');
  };
  const rebookingApplied = (id) => setRebookingIntent(current => current?.id === id ? null : current);
  useEffect(() => { if (route !== 'home') setRebookingIntent(null); }, [route]);

  if (route === 'lookup') return <BookingLookup standalone lang={lang} onRebook={rebook} />;
  if (route === 'member') return <Member lang={lang} onRebook={rebook} />;
  if (route === 'manage') return <BookingPortal token={window.location.hash.slice(8)} lang={lang} onRebook={rebook} />;
  if (route === 'review') return <BookingPortal token={window.location.hash.slice(8)} review lang={lang} />;
  if (route === 'admin') {
    return <Admin />;
  }
  if (route === 'services') return <Services lang={lang} />;
  if (route === 'shop') {
    return <Shop lang={lang} onNavigateHome={() => navigateTo('/')} />;
  }
  if (route === 'contact') {
    return <Contact lang={lang} onNavigateHome={() => navigateTo('/')} />;
  }
  return <App lang={lang} onNavigateShop={() => navigateTo('/shop/')} onNavigateContact={() => navigateTo('/contact/')} onLangChange={setLang} onRebook={rebook} rebookingIntent={rebookingIntent} onRebookingApplied={rebookingApplied} />;
}

ReactDOM.createRoot(document.getElementById('root')).render(<React.Suspense fallback={<div style={{padding:40,textAlign:"center"}}>載入中…</div>}><Router /></React.Suspense>);
