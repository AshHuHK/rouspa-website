import React, { useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
const Admin = React.lazy(() => import('./Admin.jsx'));
const Shop = React.lazy(() => import('./Shop.jsx'));
const Contact = React.lazy(() => import('./Contact.jsx'));
const Member = React.lazy(() => import('./Member.jsx'));
const BookingPortal = React.lazy(() => import('./BookingPortal.jsx'));

// 路由：
// https://rouspa.tw/           → 客人网站
// https://rouspa.tw/#shop      → 产品商城
// https://rouspa.tw/#contact   → 联系我们
// https://rouspa.tw/#admin     → 管理后台
function Router() {
  const [route, setRoute] = useState(window.location.hash);
  const [lang, setLang] = useState("zh");

  useEffect(() => {
    const handleHash = () => {
      setRoute(window.location.hash);
      window.scrollTo(0, 0);
    };
    window.addEventListener("hashchange", handleHash);
    return () => window.removeEventListener("hashchange", handleHash);
  }, []);

  const navigateTo = (hash) => {
    window.location.hash = hash;
  };

  if (route === "#member") return <Member />;
  if (route.startsWith("#manage/")) return <BookingPortal token={route.slice(8)} />;
  if (route.startsWith("#review/")) return <BookingPortal token={route.slice(8)} review />;
  if (route === "#admin") {
    return <Admin />;
  }
  if (route === "#shop") {
    return <Shop lang={lang} onNavigateHome={() => navigateTo("")} />;
  }
  if (route === "#contact") {
    return <Contact lang={lang} onNavigateHome={() => navigateTo("")} />;
  }
  return <App onNavigateShop={() => navigateTo("shop")} onNavigateContact={() => navigateTo("contact")} onLangChange={setLang} />;
}

ReactDOM.createRoot(document.getElementById('root')).render(<React.Suspense fallback={<div style={{padding:40,textAlign:"center"}}>載入中…</div>}><Router /></React.Suspense>);
