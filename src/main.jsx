import React, { useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
import Admin from './Admin.jsx';
import Shop from './Shop.jsx';
import Contact from './Contact.jsx';

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

ReactDOM.createRoot(document.getElementById('root')).render(<Router />);
