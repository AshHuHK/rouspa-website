import './public-data-status.css';

export function PublicDataStatus({ error, loading, hasData, onRetry, lang = 'zh' }) {
  if (!error && (!loading || hasData)) return null;
  const en = lang === 'en';
  return <div className="public-data-status" role={error ? 'alert' : 'status'}>
    <p>{error ? (hasData ? (en ? 'Updates could not be loaded. Previous information is shown. ' : '更新失敗，目前保留上次成功載入的資料。') : '') + error : en ? 'Loading current store information…' : '正在載入目前門店資訊…'}</p>
    {error && <button type="button" disabled={loading} onClick={onRetry}>{loading ? en ? 'Loading…' : '載入中…' : en ? 'Try again' : '重新載入'}</button>}
  </div>;
}
