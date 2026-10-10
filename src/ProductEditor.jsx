import { useEffect, useRef, useState } from 'react';
import { Field } from './OperationsShared.jsx';
import { cents, errorText, rpc, supabase } from './lib/spa.js';
import { PRODUCT_PHOTO_ACCEPT, productMediaError, uploadProductPhoto, validateProductPhoto, validateProductPhotoUrl, waitForProductPhoto } from './lib/product-media.js';
import './product-editor.css';

function initialProduct(row, categories) {
  return row ? { ...row, price: Number(row.price_cents) / 100, cost: row.cost_cents == null ? '' : Number(row.cost_cents) / 100 } : {
    sku: '', name: '', name_en: '', category_id: categories.find(category => category.code === 'uncategorized' && category.active && !category.archived_at)?.id || '',
    description: '', description_en: '', image_url: '', price: 0, cost: '', barcode: '', unit_label: '件', unit_label_en: '',
    low_stock_threshold: 2, status: 'draft', website_visible: false, store_visible: false, display_order: 0,
  };
}

export default function ProductEditor({ row, categories, saved }) {
  const [fields, setFields] = useState(() => initialProduct(row, categories));
  const [file, setFile] = useState(null), [preview, setPreview] = useState('');
  const [photoError, setPhotoError] = useState(''), [imageFailed, setImageFailed] = useState(false), [urlOpen, setUrlOpen] = useState(false);
  const [busy, setBusy] = useState(false), [validating, setValidating] = useState(false), [error, setError] = useState(''), [stage, setStage] = useState('');
  const running = useRef(false), checking = useRef(false), alive = useRef(true), selection = useRef(0), upload = useRef(null), fileInput = useRef(null);
  const set = (key, value) => setFields(current => ({ ...current, [key]: value }));
  useEffect(() => { alive.current = true; return () => { alive.current = false; selection.current += 1; }; }, []);
  useEffect(() => {
    if (!file) { setPreview(''); return; }
    const url = URL.createObjectURL(file);
    setPreview(url);
    return () => URL.revokeObjectURL(url);
  }, [file]);
  const imageUrl = preview || fields.image_url || '';
  useEffect(() => { setImageFailed(false); }, [imageUrl]);

  async function choosePhoto(event) {
    const candidate = event.target.files?.[0];
    if (!candidate) return;
    const version = ++selection.current;
    setPhotoError(''); checking.current = true; setValidating(true);
    try {
      await validateProductPhoto(candidate);
      if (!alive.current || selection.current !== version) return;
      setFile(candidate); upload.current = null; setError('');
    } catch (failure) {
      if (!alive.current || selection.current !== version) return;
      setPhotoError(productMediaError(failure, errorText));
      if (fileInput.current) fileInput.current.value = '';
    } finally {
      if (alive.current && selection.current === version) { checking.current = false; setValidating(false); }
    }
  }

  function clearPhoto() {
    selection.current += 1; checking.current = false; setValidating(false); setFile(null); upload.current = null; set('image_url', ''); setPhotoError(''); setError('');
    if (fileInput.current) fileInput.current.value = '';
  }

  function editPhotoUrl(value) {
    selection.current += 1; checking.current = false; setValidating(false); setFile(null); upload.current = null; set('image_url', value); setPhotoError('');
    if (fileInput.current) fileInput.current.value = '';
  }

  async function save(event) {
    event.preventDefault();
    if (running.current || checking.current) return;
    running.current = true; setBusy(true); setError('');
    try {
      // Capture and validate the form before uploading. Inputs remain disabled
      // through both steps, keeping the final image and product draft together.
      const payload = { ...fields, id: row?.id || '', price_cents: cents(fields.price), cost_cents: fields.cost === '' ? '' : cents(fields.cost), low_stock_threshold: Number(fields.low_stock_threshold), display_order: Number(fields.display_order) };
      let photoUrl = file ? '' : validateProductPhotoUrl(fields.image_url);
      if (file) {
        setStage('正在上傳照片…');
        if (!upload.current || upload.current.file !== file) {
          const task = { file, promise: uploadProductPhoto(file, { client: supabase }) };
          upload.current = task;
          task.promise.catch(() => { if (upload.current === task) upload.current = null; });
        }
        photoUrl = (await waitForProductPhoto(upload.current.promise)).url;
        if (!alive.current) return;
        // If product saving fails, the already uploaded URL is reused on retry.
        set('image_url', photoUrl);
      }
      if (!alive.current) return;
      setStage('正在儲存商品…');
      await rpc('spa_product_save', { p_payload: { ...payload, image_url: photoUrl } });
      if (alive.current) await saved();
    } catch (failure) {
      if (alive.current) setError(failure?.code === '23505' ? '商品 SKU 已存在，請使用另一個 SKU，或開啟既有商品編輯。' : productMediaError(failure, errorText));
    } finally {
      running.current = false;
      if (alive.current) { setBusy(false); setStage(''); }
    }
  }

  return <form className="product-editor" onSubmit={save}>
    <fieldset disabled={busy || validating}>
      <section className="product-editor-section" style={{ marginTop: 0, borderTop: 0, paddingTop: 0 }}>
        <h3>產品照片</h3>
        <div className="product-photo-layout">
          <div className="product-photo-preview">{imageUrl && !imageFailed ? <img src={imageUrl} alt={`${fields.name || '產品'}照片預覽`} onError={() => setImageFailed(true)} /> : <span>{imageFailed ? '照片目前無法載入' : '尚未設定照片'}</span>}</div>
          <div className="product-photo-controls">
            <Field label="選擇產品照片"><input ref={fileInput} type="file" accept={PRODUCT_PHOTO_ACCEPT} onChange={choosePhoto} /></Field>
            <p className="muted product-preview-note">JPG、PNG、WebP，最大 5 MB。按儲存時才上傳；此處請只選公開產品照片。</p>
            {file && <p className="product-photo-status">已選擇：{file.name}</p>}
            {photoError && <p role="alert" className="product-photo-error">{photoError}</p>}
            <div className="actions"><button type="button" onClick={() => setUrlOpen(current => !current)} aria-expanded={urlOpen}>{urlOpen ? '收起照片網址' : '改用照片網址'}</button>{imageUrl && <button type="button" onClick={clearPhoto}>移除照片</button>}</div>
            {urlOpen && <Field label="照片網址"><input type="url" value={fields.image_url || ''} onChange={event => editPhotoUrl(event.target.value)} placeholder="https://…" /></Field>}
          </div>
        </div>
      </section>
      <section className="product-editor-section">
        <h3>產品資訊</h3>
        <div className="form-grid">
          <Field label="中文名稱"><input required maxLength={120} value={fields.name || ''} onChange={event => set('name', event.target.value)} /></Field>
          <Field label="英文名稱"><input maxLength={120} value={fields.name_en || ''} onChange={event => set('name_en', event.target.value)} /></Field>
          <Field label="SKU"><input required maxLength={80} value={fields.sku || ''} onChange={event => set('sku', event.target.value)} /></Field>
          <Field label="條碼"><input value={fields.barcode || ''} onChange={event => set('barcode', event.target.value)} /></Field>
          <Field label="商品分類"><select required value={fields.category_id || ''} onChange={event => set('category_id', event.target.value)}><option value="" disabled>請選分類</option>{categories.filter(category => category.active && !category.archived_at || category.id === row?.category_id).map(category => <option key={category.id} value={category.id}>{category.name}{!category.active || category.archived_at ? '（停用）' : ''}</option>)}</select></Field>
          <Field label="狀態"><select value={fields.status} onChange={event => set('status', event.target.value)}><option value="draft">草稿</option><option value="active">上架</option><option value="archived">封存</option></select></Field>
          <Field wide label="中文產品資訊"><textarea value={fields.description || ''} onChange={event => set('description', event.target.value)} placeholder="產品特色、容量／規格、成分、使用方式與注意事項" /></Field>
          <Field wide label="英文產品資訊"><textarea value={fields.description_en || ''} onChange={event => set('description_en', event.target.value)} placeholder="Product features, size, ingredients and usage" /></Field>
        </div>
      </section>
      <section className="product-editor-section">
        <h3>價格、庫存與展示</h3>
        <div className="form-grid">
          <Field label="售價 NT$（元）"><input required type="number" min="0" step="0.01" value={fields.price} onChange={event => set('price', event.target.value)} /></Field>
          <Field label="成本 NT$（元）"><input type="number" min="0" step="0.01" value={fields.cost} onChange={event => set('cost', event.target.value)} /></Field>
          <Field label="中文規格／庫存單位"><input required value={fields.unit_label || ''} onChange={event => set('unit_label', event.target.value)} placeholder="例：250 ml／瓶、盒、件" /></Field>
          <Field label="英文規格／庫存單位"><input value={fields.unit_label_en || ''} onChange={event => set('unit_label_en', event.target.value)} placeholder="例：250 ml / bottle" /></Field>
          <Field label={`低庫存提醒（${fields.unit_label || '庫存單位'}）`}><input type="number" min="0" step="1" value={fields.low_stock_threshold} onChange={event => set('low_stock_threshold', event.target.value)} /></Field>
          <Field label="排序"><input type="number" step="1" value={fields.display_order} onChange={event => set('display_order', event.target.value)} /></Field>
          <div className="wide product-display-options"><label><input type="checkbox" checked={!!fields.website_visible} onChange={event => set('website_visible', event.target.checked)} />官網顯示</label><label><input type="checkbox" checked={!!fields.store_visible} onChange={event => set('store_visible', event.target.checked)} />商店顯示</label></div>
        </div>
        <p className="muted">售價與成本輸入新台幣元；庫存數量依規格／單位計數。新增商品後可用「調庫存」入庫。</p>
      </section>
    </fieldset>
    {error && <p className="alert" role="alert">{error}</p>}
    {busy && <p role="status" aria-live="polite" className="product-photo-status">{stage}</p>}
    {validating && <p role="status" className="product-photo-status">正在檢查照片…</p>}
    <div className="actions"><button className="primary" disabled={busy || validating}>{busy ? '處理中…' : validating ? '檢查照片中…' : '儲存商品'}</button></div>
  </form>;
}
