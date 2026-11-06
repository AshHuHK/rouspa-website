import { STORE } from './lib/public-copy.js';

export default function PublicLineButton({ lang = 'zh' }) {
  return <div className="public-line-floating"><span className="public-line-tooltip">{lang === 'en' ? 'LINE chat' : 'LINE 諮詢'}</span><a href={STORE.LINE_URL} target="_blank" rel="noopener noreferrer" aria-label={lang === 'en' ? 'Contact ROU SPA on LINE' : 'LINE 聯絡柔療髮浴'}><span>LINE</span></a></div>;
}
