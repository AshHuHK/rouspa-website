import { useEffect, useRef, useState } from 'react';
import { Empty, Field } from './OperationsShared.jsx';
import { cents, errorText, money, rpc } from './lib/spa.js';
import { createRequestId } from './lib/request-id.js';
import { preserveSelectedCoupon, reconcilePosCart } from './lib/operations-drafts.js';
import { isProductCategoryAvailable } from './lib/product-categories.js';
import { posEligibleStaff } from './lib/staff-work-roles.js';

export default function PosWorkspace({ catalog, customers, onReload }) {
  const [section, setSection] = useState('all'), [category, setCategory] = useState('all'), [query, setQuery] = useState('');
  const [cart, setCart] = useState([]), [customer, setCustomer] = useState(''), [method, setMethod] = useState('cash');
  const [discount, setDiscount] = useState('0'), [note, setNote] = useState(''), [done, setDone] = useState('');
  const [error, setError] = useState(''), [busy, setBusy] = useState(false), [coupons, setCoupons] = useState([]);
  const [coupon, setCoupon] = useState(''), [couponLoading, setCouponLoading] = useState(false), [couponError, setCouponError] = useState(false);
  const running = useRef(false), attempt = useRef(null);
  useEffect(() => { setCoupon(''); setCoupons([]); setCouponError(false); }, [customer]);
  useEffect(() => {
    if (busy) return;
    let live = true;
    setCouponLoading(!!customer);
    if (customer) rpc('spa_customer_coupons_admin', { p_customer: customer }).then(rows => {
      if (live) { setCoupons(rows); setCoupon(selected => preserveSelectedCoupon(selected, rows)); setCouponError(false); }
    }).catch(value => {
      if (live) { setCouponError(true); setError(errorText(value)); if (value.message?.includes('FORBIDDEN')) { setCoupons([]); setCoupon(''); } }
    }).finally(() => { if (live) setCouponLoading(false); });
    return () => { live = false; };
  }, [customer, catalog, busy]);
  useEffect(() => { if (!busy) setCart(rows => reconcilePosCart(rows, catalog)); }, [catalog, busy]);
  const categories = (catalog.product_categories || []).filter(value => value.active && !value.archived_at);
  useEffect(() => { if (category !== 'all' && !categories.some(value => value.id === category)) setCategory('all'); }, [catalog, category]);
  const products = catalog.products.filter(value => value.status === 'active' && Number(value.inventory) > 0 && isProductCategoryAvailable(value, catalog.product_categories))
    .map(value => ({ ...value, item_type: 'product', key: `product:${value.id}` }));
  const services = catalog.services.filter(value => value.status === 'active' && value.active !== false).map(value => ({ ...value, item_type: 'service', key: `service:${value.id}` }));
  const items = [...(section !== 'services' ? products.filter(value => category === 'all' || value.category_id === category) : []), ...(section !== 'products' ? services : [])]
    .filter(value => `${value.name} ${value.sku || value.code || ''}`.toLowerCase().includes(query.toLowerCase()));
  const eligible = item => posEligibleStaff(item, catalog);
  const change = (key, update) => setCart(rows => rows.map(value => value.key === key ? { ...value, ...update } : value));
  const add = item => setCart(rows => {
    const found = rows.find(value => value.key === item.key), limit = item.item_type === 'product' ? Number(item.inventory) : 99;
    return found ? rows.map(value => value.key === item.key ? { ...value, quantity: Math.min(limit, value.quantity + 1) } : value) :
      [...rows, { ...item, quantity: 1, staff_id: '', designated_client: false, self_sourced_client: false }];
  });
  const cartInvalid = cart.some(item => !eligible(item).some(person => person.id === item.staff_id) || (
    item.item_type === 'product' ? !products.some(value => value.id === item.id) || item.quantity > Number(item.inventory) : !services.some(value => value.id === item.id)
  ));
  let discountCents = null;
  try { discountCents = cents(discount || 0); } catch {}
  const couponDiscount = Number(coupons.find(value => value.id === coupon)?.amount_cents || 0);
  const total = cart.reduce((value, item) => value + Number(item.price_cents) * item.quantity, 0) - (discountCents ?? 0) - couponDiscount;
  const canCheckout = !busy && !couponLoading && !couponError && cart.length > 0 && !cartInvalid && total >= 0 && discountCents != null && discountCents >= 0;
  async function checkout() {
    if (running.current || !canCheckout) return;
    running.current = true; setBusy(true); setError(''); setDone('');
    try {
      const payload = { p_customer: customer || null, p_items: cart.map(item => ({ item_type: item.item_type, item_id: item.id, quantity: item.quantity,
        staff_id: item.staff_id, designated_client: !!item.designated_client, self_sourced_client: !!item.self_sourced_client })),
        p_discount: discountCents, p_method: method, p_note: note, p_coupon: coupon || null, p_expected_total: total };
      const fingerprint = JSON.stringify(payload);
      if (attempt.current?.fingerprint !== fingerprint) attempt.current = { fingerprint, id: createRequestId() };
      const sale = await rpc('spa_pos_checkout_with_coupon', { ...payload, p_request: attempt.current.id });
      attempt.current = null;
      setDone(`${sale.reference} · ${money(sale.total_cents)}`);
      setCart([]); setDiscount('0'); setCoupon(''); setCoupons([]); setNote('');
      await onReload();
    } catch (value) {
      setError(errorText(value));
      if (/PRICE_CHANGED|INSUFFICIENT_INVENTORY|UNAVAILABLE|INVALID_STAFF/.test(value.message || '')) await onReload();
    } finally { running.current = false; setBusy(false); }
  }
  return <>
    <div className="os-page-title"><div><h2>門店 POS</h2><p className="muted">每筆服務指定實際技師，每筆商品指定銷售人員；折後淨額與人員歸屬直接連入薪資。</p></div></div>
    {done && <p className="success" role="status">完成收款：{done}</p>}{error && <p className="alert" role="alert">{error}</p>}
    <fieldset disabled={busy} style={{ border: 0, padding: 0, margin: 0, minWidth: 0 }}>
      <div className="toolbar"><nav>{[['all', '全部'], ['services', '服務'], ['products', '商品']].map(([id, label]) => <button key={id} className={section === id ? 'active' : ''} onClick={() => setSection(id)}>{label}</button>)}</nav>
        <input aria-label="搜尋 POS 項目" placeholder="搜尋服務、商品、代碼或 SKU" value={query} onChange={event => setQuery(event.target.value)}/>
        {section !== 'services' && <select aria-label="商品分類" value={category} onChange={event => setCategory(event.target.value)}><option value="all">全部商品分類</option>{categories.map(value => <option key={value.id} value={value.id}>{value.name}</option>)}</select>}
      </div>
      <div className="split os-pos"><section>{!items.length && <Empty>沒有可銷售項目。</Empty>}<div className="grid">{items.map(item => <button className="card os-product-button" key={item.key} disabled={!eligible(item).length} onClick={() => add(item)}>
        <span className="badge">{item.item_type === 'service' ? '服務' : item.category_name || '商品'}</span><strong>{item.name}</strong><span>{money(item.price_cents)}</span>
        <small>{item.item_type === 'service' ? `${item.duration_minutes} 分鐘 · ${eligible(item).length} 位合資格技師` : `庫存 ${item.inventory} ${item.unit_label || '件'}`}</small>
      </button>)}</div></section>
      <section className="card"><h2>本次銷售</h2>{!cart.length && <Empty>點選服務或商品，再選擇該筆提成人員。</Empty>}
        {cart.map(item => {
          const people = eligible(item), person = people.find(value => value.id === item.staff_id), isService = item.item_type === 'service';
          return <div className="os-cart-row os-cart-item" key={item.key}>
            <span><span className="badge">{isService ? '服務' : '商品'}</span> {item.name}<small>{money(item.price_cents)} × {item.quantity}</small></span>
            <div className="row"><button onClick={() => change(item.key, { quantity: Math.max(1, item.quantity - 1) })}>−</button><button onClick={() => change(item.key, { quantity: Math.min(isService ? 99 : Number(item.inventory), item.quantity + 1) })}>＋</button><button onClick={() => setCart(rows => rows.filter(value => value.key !== item.key))}>移除</button></div>
            <Field label={isService ? '實際服務技師（必選）' : '銷售人員／商品提成（必選）'}><select required value={item.staff_id} onChange={event => change(item.key, { staff_id: event.target.value, self_sourced_client: false })}>
              <option value="">{isService ? '請選實際技師' : '請選銷售人員'}</option>
              {item.staff_id && !person && <option value={item.staff_id} disabled>原人員已失效，請重新選擇</option>}
              {people.map(value => <option key={value.id} value={value.id}>{value.name} · {value.job_title_name || value.title}</option>)}
            </select></Field>
            {isService && <div className="os-check-grid">
              <label><input type="checkbox" checked={!!item.designated_client} disabled={!!item.self_sourced_client} onChange={event => change(item.key, { designated_client: event.target.checked })}/>指定客（按職稱比例加成）</label>
              {person?.employment_type_code === 'contractor' && <label><input type="checkbox" checked={!!item.self_sourced_client} onChange={event => change(item.key, { self_sourced_client: event.target.checked, designated_client: false })}/>承攬自帶客（採自帶客比例）</label>}
            </div>}
          </div>;
        })}
        <Field label="會員（可不選）"><select value={customer} onChange={event => setCustomer(event.target.value)}><option value="">散客</option>{customers.filter(value => !value.archived_at && value.status === 'active').map(value => <option key={value.id} value={value.id}>{value.name} · {value.phone}</option>)}</select></Field>
        <Field label="會員優惠券"><select disabled={!customer || couponLoading} value={coupon} onChange={event => setCoupon(event.target.value)}><option value="">{couponLoading ? '讀取優惠券…' : '不使用'}</option>{coupons.map(value => <option key={value.id} value={value.id}>{value.code} · {money(value.amount_cents)}</option>)}</select></Field>
        <Field label="折扣 NT$（元）"><input type="number" min="0" step="0.01" value={discount} onChange={event => setDiscount(event.target.value)}/></Field>
        <Field label="收款方式"><select value={method} onChange={event => setMethod(event.target.value)}><option value="cash">現金</option><option value="card">刷卡</option><option value="transfer">轉帳</option></select></Field>
        <Field label="備註"><textarea maxLength={1000} value={note} onChange={event => setNote(event.target.value)}/></Field>
        <div className="metric">應收 {money(Math.max(0, total))}</div>
        {couponDiscount > 0 && <p className="muted">已扣優惠券 {money(couponDiscount)}，成功收款後才核銷。</p>}
        {cartInvalid && <p className="alert">每筆服務與商品都必須指定有效人員；請核對人員資格、分類、上架狀態及庫存。</p>}
        {(discountCents == null || discountCents < 0) && <p className="alert">折扣請填有效的新台幣金額，最多兩位小數。</p>}
        {total < 0 && <p className="alert">總折扣不可超過本次銷售金額。</p>}
        <button className="primary" disabled={!canCheckout} onClick={checkout}>{busy ? '收款中…' : '確認收款'}</button>
      </section></div>
    </fieldset>
  </>;
}
