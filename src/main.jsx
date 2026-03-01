import React, { useState, useEffect } from 'react';
import ReactDOM from 'react-dom/client';
import App from './App.jsx';
import Admin from './Admin.jsx';

// 简单的 hash 路由：
// https://rouspa.tw/         → 客人网站
// https://rouspa.tw/#admin   → 管理后台
function Router() {
  const [route, setRoute] = useState(window.location.hash);

  useEffect(() => {
    const handleHash = () => setRoute(window.location.hash);
    window.addEventListener("hashchange", handleHash);
    return () => window.removeEventListener("hashchange", handleHash);
  }, []);

  if (route === "#admin") {
    return <Admin />;
  }
  return <App />;
}

ReactDOM.createRoot(document.getElementById('root')).render(<Router />);
