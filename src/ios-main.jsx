import React, { useEffect, useState } from 'react';
import ReactDOM from 'react-dom/client';
import { App as NativeApp } from '@capacitor/app';
import { Browser } from '@capacitor/browser';
import { SplashScreen } from '@capacitor/splash-screen';
import { StatusBar, Style } from '@capacitor/status-bar';
import Admin from './Admin.jsx';
import { supabase } from './lib/spa.js';
import { isNativeOperationsApp, NATIVE_CATCHUP_EVENT } from './lib/native-platform.js';
import { ApplicationBoundary } from './ApplicationBoundary.jsx';
import './responsive.css';
import './ios.css';
import './typography.css';

function OperationsApp() {
  const [privacyVisible, setPrivacyVisible] = useState(false);
  useEffect(() => {
    document.documentElement.classList.add('rou-ios-app');
    document.body.classList.add('rou-ios-body');
    let appStateListener;
    let mounted = true;
    let lifecycleVersion = 0;

    const setPrivate = visible => {
      if (!mounted) return;
      document.documentElement.classList.toggle('rou-ios-private', visible);
      setPrivacyVisible(visible);
    };

    const clearInvalidSession = async () => {
      try {
        const { error } = await supabase.auth.signOut();
        if (!error) return;
      } catch {
        // Fall through to a local clear if the server-backed sign-out fails.
      }
      await supabase.auth.signOut({ scope: 'local' }).catch(() => {});
    };

    const handleAppState = async ({ isActive }) => {
      const version = ++lifecycleVersion;
      if (!isActive) {
        setPrivate(true);
        supabase.auth.stopAutoRefresh();
        return;
      }

      // Keep private operations hidden until the server-backed session has been
      // refreshed. A revoked or expired session is cleared before revealing UI.
      setPrivate(true);
      supabase.auth.startAutoRefresh();
      try {
        const { data, error } = await supabase.auth.refreshSession();
        if (error) throw error;
        if (!mounted || version !== lifecycleVersion) return;
        if (!data.session) throw new Error('SESSION_REFRESH_EMPTY');
        window.dispatchEvent(new Event(NATIVE_CATCHUP_EVENT));
        window.dispatchEvent(new Event('online'));
        document.dispatchEvent(new Event('visibilitychange'));
      } catch {
        if (!mounted || version !== lifecycleVersion) return;
        await clearInvalidSession();
      } finally {
        if (mounted && version === lifecycleVersion) setPrivate(false);
      }
    };

    const openExternal = event => {
      if (!isNativeOperationsApp() || event.defaultPrevented || event.button > 0) return;
      const anchor = event.target.closest?.('a[href]');
      if (!anchor || anchor.hasAttribute('download')) return;
      const href = anchor.getAttribute('href');
      if (!href || !/^(https?:)/i.test(href)) return;
      event.preventDefault();
      void Browser.open({ url: href, presentationStyle: 'popover' });
    };

    document.addEventListener('click', openExternal);
    void StatusBar.setStyle({ style: Style.Dark }).catch(() => {});
    void NativeApp.addListener('appStateChange', handleAppState).then(listener => {
      if (mounted) appStateListener = listener;
      else void listener.remove();
    });
    requestAnimationFrame(() => { void SplashScreen.hide().catch(() => {}); });

    return () => {
      mounted = false;
      lifecycleVersion += 1;
      document.removeEventListener('click', openExternal);
      void appStateListener?.remove();
      document.documentElement.classList.remove('rou-ios-private');
      document.documentElement.classList.remove('rou-ios-app');
      document.body.classList.remove('rou-ios-body');
    };
  }, []);

  return <><Admin/><div className="rou-ios-privacy-screen" aria-hidden={!privacyVisible}><span className="rou-ios-privacy-mark">柔</span><strong>柔療營運</strong><small>營運資料已隱藏</small></div></>;
}

ReactDOM.createRoot(document.getElementById('root')).render(
  <React.StrictMode><ApplicationBoundary><OperationsApp /></ApplicationBoundary></React.StrictMode>,
);
