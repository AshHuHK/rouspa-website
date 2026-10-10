import { useState } from 'react';
import { Empty, Field, Modal } from './OperationsShared.jsx';
import { errorText, rpc } from './lib/spa.js';

const categoryErrors = {
  PRODUCT_CATEGORY_IN_USE: '此分類仍有商品（包含草稿或封存商品）。請先選擇移往的有效分類，才可刪除。',
  PRODUCT_CATEGORY_UNAVAILABLE: '所選分類已停用或不存在，請重新載入並選擇有效分類。',
  PRODUCT_CATEGORY_CODE_TAKEN: '此分類代碼已存在，請改用另一代碼或留空自動建立。',
  PRODUCT_CATEGORY_CODE_IMMUTABLE: '分類代碼是固定識別碼；請只修改顯示名稱。',
  INVALID_CONFIRMATION: '請輸入 DELETE 才能刪除分類。',
};
function message(error) {
  return Object.entries(categoryErrors).find(([code]) => String(error?.message || '').includes(code))?.[1] || errorText(error);
}

export default function ProductCategories({ categories = [], products = [], canManage = false, onReload }) {
  const [modal, setModal] = useState(null);
  const count = id => products.filter(product => product.category_id === id).length;
  const saved = async () => { setModal(null); await onReload(); };
  const sorted = [...categories].sort((a, b) => Number(a.display_order || 0) - Number(b.display_order || 0) || a.name.localeCompare(b.name, 'zh-Hant'));
  return <section className="card">
    <div className="row" style={{ justifyContent: 'space-between', flexWrap: 'wrap' }}><div><h3>商品分類</h3><p className="muted">分類名稱、章字與排序共用於官網及 POS。停用分類會停止新展示及銷售；既有庫存和訂單保留。</p></div>{canManage && <button type="button" onClick={() => setModal({ kind: 'edit', row: null })}>新增分類</button>}</div>
    {!sorted.length ? <Empty>尚無商品分類，請先新增。</Empty> : <div className="table-wrap"><table><thead><tr><th>分類</th><th>排序</th><th>商品數</th><th>狀態</th>{canManage && <th>操作</th>}</tr></thead><tbody>{sorted.map(category => <tr key={category.id}>
      <td><strong>{category.display_mark ? `${category.display_mark} · ` : ''}{category.name}</strong><small className="table-sub">{category.name_en || category.code}</small></td><td>{category.display_order}</td><td>{count(category.id)}</td><td><span className="badge">{category.active && !category.archived_at ? '啟用' : '停用'}</span></td>
      {canManage && <td><div className="actions"><button type="button" onClick={() => setModal({ kind: 'edit', row: category })}>編輯</button><button type="button" className="danger" onClick={() => setModal({ kind: 'delete', row: category })}>刪除</button></div></td>}
    </tr>)}</tbody></table></div>}
    {modal && <Modal title={modal.kind === 'delete' ? '刪除商品分類' : `${modal.row ? '編輯' : '新增'}商品分類`} onClose={() => setModal(null)}>
      {modal.kind === 'delete' ? <DeleteCategory row={modal.row} count={count(modal.row.id)} categories={categories} onSaved={saved} /> : <EditCategory row={modal.row} onSaved={saved} />}
    </Modal>}
  </section>;
}

function CategoryForm({ action, onSaved, children, submit = '儲存分類' }) {
  const [busy, setBusy] = useState(false), [error, setError] = useState('');
  return <form onSubmit={async event => {
    event.preventDefault(); if (busy) return; setBusy(true); setError('');
    try { await action(); await onSaved(); } catch (failure) { setError(message(failure)); } finally { setBusy(false); }
  }}><fieldset disabled={busy} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>{children}{error && <p className="alert" role="alert">{error}</p>}<div className="actions"><button className="primary" disabled={busy}>{busy ? '處理中…' : submit}</button></div></fieldset></form>;
}

function EditCategory({ row, onSaved }) {
  const [form, setForm] = useState(row || { name: '', name_en: '', code: '', display_mark: '', display_order: 0, active: true });
  const set = (key, value) => setForm(previous => ({ ...previous, [key]: value }));
  return <CategoryForm action={() => rpc('spa_product_category_save', { p_payload: { id: row?.id || '', name: form.name, name_en: form.name_en || '', code: form.code || '', display_mark: form.display_mark || '', display_order: Number(form.display_order), active: Boolean(form.active) } })} onSaved={onSaved}>
    <div className="form-grid"><Field label="中文分類名稱"><input required maxLength={80} value={form.name} onChange={event => set('name', event.target.value)} /></Field>
      <Field label="英文分類名稱"><input maxLength={120} value={form.name_en || ''} onChange={event => set('name_en', event.target.value)} /></Field>
      <Field label="固定代碼（新增可留空）"><input disabled={Boolean(row)} maxLength={64} pattern="[a-z][a-z0-9_-]{1,63}" placeholder="留空由系統建立" value={form.code || ''} onChange={event => set('code', event.target.value.toLowerCase())} /></Field>
      <Field label="官網章字（最多 2 字）"><input maxLength={2} value={form.display_mark || ''} onChange={event => set('display_mark', event.target.value)} /></Field>
      <Field label="顯示排序（數字小的在前）"><input required type="number" min={-10000} max={10000} step={1} value={form.display_order} onChange={event => set('display_order', event.target.value)} /></Field>
      <Field label="分類狀態"><select value={String(form.active && !form.archived_at)} onChange={event => { set('active', event.target.value === 'true'); set('archived_at', null); }}><option value="true">啟用</option><option value="false">停用</option></select></Field></div>
    <p className="muted">名稱與章字可以修改；分類 ID 和建立後的代碼保持不變，不影響既有商品或成交快照。</p>
  </CategoryForm>;
}

function DeleteCategory({ row, count, categories, onSaved }) {
  const [target, setTarget] = useState(''), [confirmation, setConfirmation] = useState('');
  const available = categories.filter(category => category.id !== row.id && category.active && !category.archived_at);
  return <CategoryForm action={() => rpc('spa_product_category_delete', { p_category: row.id, p_target: target || null, p_confirmation: confirmation })} onSaved={onSaved} submit={count ? '移轉商品並刪除分類' : '刪除分類'}>
    <p>分類「{row.name}」目前有 {count} 個商品，包含草稿和封存商品。刪除分類不會刪商品、庫存或歷史訂單。</p>
    {count > 0 && <Field label="全部商品移往分類"><select required value={target} onChange={event => setTarget(event.target.value)}><option value="">請選擇有效分類</option>{available.map(category => <option key={category.id} value={category.id}>{category.name}</option>)}</select></Field>}
    {count > 0 && !available.length && <p className="alert">請先新增或啟用另一個分類，再移轉商品。</p>}
    <Field label="輸入 DELETE 確認"><input required pattern="DELETE" value={confirmation} onChange={event => setConfirmation(event.target.value)} autoComplete="off" /></Field>
  </CategoryForm>;
}
