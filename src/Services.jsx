import { useEffect } from 'react';
import { usePublicCatalog } from './lib/usePublicData.js';
import { updateBusinessSeo } from './lib/seo.js';
import { servicePageHtml } from './lib/service-content.js';
import './services.css';

export default function Services({ lang = 'zh' }) {
  const { data: catalog } = usePublicCatalog({ lang });
  useEffect(() => { if (catalog) updateBusinessSeo(catalog, 'services', lang); }, [catalog, lang]);
  return <div className="care-page" data-language={lang} dangerouslySetInnerHTML={{ __html: servicePageHtml(lang, catalog) }} />;
}
