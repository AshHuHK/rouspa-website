import { useEffect } from 'react';
import { usePublicCatalog } from './lib/usePublicData.js';
import { updateBusinessSeo } from './lib/seo.js';
import { servicePageHtml } from './lib/service-content.js';
import { PublicDataStatus } from './PublicDataStatus.jsx';
import './services.css';

export default function Services({ lang = 'zh' }) {
  const { data: catalog, error, loading, refresh } = usePublicCatalog({ lang });
  useEffect(() => { if (catalog) updateBusinessSeo(catalog, 'services', lang); }, [catalog, lang]);
  return <><div className="care-data-status"><PublicDataStatus error={error} loading={loading} hasData={!!catalog} onRetry={refresh} lang={lang}/></div><div className="care-page" data-language={lang} dangerouslySetInnerHTML={{ __html: servicePageHtml(lang, catalog) }} /></>;
}
