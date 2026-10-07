import { useEffect, useState } from 'react';
import { publicRpc } from './lib/spa.js';
import { updateBusinessSeo } from './lib/seo.js';
import { servicePageHtml } from './lib/service-content.js';
import './services.css';

export default function Services({ lang = 'zh' }) {
  const [catalog, setCatalog] = useState(null);
  useEffect(() => {
    let live = true;
    publicRpc('spa_catalog').then(data => { if (live) setCatalog(data); }).catch(() => {});
    return () => { live = false; };
  }, []);
  useEffect(() => { if (catalog) updateBusinessSeo(catalog, 'services', lang); }, [catalog, lang]);
  return <div className="care-page" data-language={lang} dangerouslySetInnerHTML={{ __html: servicePageHtml(lang, catalog) }} />;
}
