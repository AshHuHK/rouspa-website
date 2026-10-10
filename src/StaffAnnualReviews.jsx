import { useEffect, useRef, useState } from 'react';
import { rpc, errorText, dateTime } from './lib/spa.js';
import { tenureLabel } from './lib/staff-tenure.js';
import { Empty, Field, Modal, MutationForm } from './OperationsShared.jsx';

const reviewError = error => ({
  INVALID_REVIEW_CRITERIA: '考核指標須為 1–12 項，名稱、代碼與權重須有效且不可重複。',
  INVALID_REVIEW_WEIGHTS: '所有考核指標的權重合計必須剛好為 100%。',
  INVALID_REVIEW_SCORE: '分數與達標線必須介於 0–100，請核對每一項。',
  INVALID_REVIEW_YEAR: '年度必須介於 2000 年至台灣當前年份。',
  REVIEW_INCOMPLETE: '所有指標評分完整後才能發布；未完成可先儲存草稿。',
  REVIEW_VERSION_CONFLICT: '考核資料已被更新，請關閉編輯並重新載入後核對。',
  REVIEW_PUBLISHED: '已發布考核保留歷史，請使用編輯更正。',
}[error?.message] || errorText(error));

export default function StaffAnnualReviews({ staffId = null, name = '', manager = false, refreshToken, onSaved }) {
  const [packet, setPacket] = useState(null), [error, setError] = useState(''), [editor, setEditor] = useState(null);
  const sequence = useRef(0);
  async function load() {
    const request = ++sequence.current;
    try {
      const next = await rpc('spa_staff_annual_reviews', { p_staff: staffId });
      if (request === sequence.current) { setPacket(next); setError(''); }
    } catch (error) { if (request === sequence.current) setError(reviewError(error)); }
  }
  useEffect(() => { load(); return () => { sequence.current++; }; }, [staffId, refreshToken]);
  async function saved() { setEditor(null); await load(); await onSaved?.(); }
  const profile = packet?.profile;
  return <section className="card" id={manager ? undefined : 'my-annual-reviews'}>
    <div className="os-page-title"><div><p className="eyebrow">TENURE & ANNUAL REVIEW</p><h2>{manager ? `${name || profile?.name || '人員'} · 年資與年度考核` : '我的年資與年度考核'}</h2></div>
      {manager && packet && <div className="actions"><button onClick={() => setEditor({ kind: 'review', row: null })}>新增年度考核</button><button onClick={() => setEditor({ kind: 'policy' })}>考核指標與權重</button></div>}
    </div>
    {profile && <><p>到職日：{profile.hire_date || '尚未設定'} · 工作年資：{tenureLabel(profile, packet.today)}</p>
      <p className="muted">年資核對日：{profile.tenure.as_of}{profile.departed_on ? ` · 離職日：${profile.departed_on}` : ''}。年資與考核供門店判斷資格，不會自動晉升或更改薪資。</p></>}
    {error && <p className="alert" role="alert">{error}</p>}
    {!packet && !error && <Empty>正在讀取年資與考核…</Empty>}
    {packet && !packet.reviews.length && <Empty>{manager ? '尚無年度考核。請按實際表現填寫，系統不會補造歷史評分。' : '尚無已發布的年度考核。店主草稿不會顯示在員工頁。'}</Empty>}
    {(packet?.reviews || []).map(row => <article className="card" key={row.id} style={{ marginTop: 12 }}>
      <div className="os-page-title"><h3>{row.review_year} 年考核 · {row.status === 'published' ? '已發布' : '草稿'}</h3>{manager && <div className="actions"><button onClick={() => setEditor({ kind: 'review', row })}>編輯考核</button>{row.status === 'draft' && <button className="danger" onClick={() => setEditor({ kind: 'delete', row })}>刪除草稿</button>}</div>}</div>
      <p>加權總分：{row.total_score ?? '尚未完整評分'}{row.total_score != null ? `／100 · 達標線 ${row.pass_score} · ${Number(row.total_score) >= Number(row.pass_score) ? '達標' : '未達標'}` : ''}</p>
      <div className="os-table-wrap"><table><thead><tr><th>考核指標</th><th>權重</th><th>分數</th></tr></thead><tbody>{row.criteria_snapshot.map(item => <tr key={item.key}><td>{item.name}{item.description && <small className="muted" style={{ display: 'block' }}>{item.description}</small>}</td><td>{item.weight}%</td><td>{row.scores[item.key] ?? '未評分'}</td></tr>)}</tbody></table></div>
      <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{row.comment || '尚未填寫評語'}</p>
      <p className="muted">考核人：{row.reviewer_name} · 記錄日 {row.reviewed_on} · 第 {row.version} 版 · 更新 {dateTime(row.updated_at)}</p>
    </article>)}
    {manager && packet && <p className="muted">新考核使用門店現行指標；已有考核保留當時的指標與達標線。店主保存／發布後，員工本人頁會收到資料更新。</p>}
    {editor && <Modal title={{ review: '年度考核', policy: '考核指標與權重', delete: '刪除年度考核草稿' }[editor.kind]} onClose={() => setEditor(null)}>
      {editor.kind === 'review' && <AnnualReviewForm row={editor.row} packet={packet} saved={saved} />}
      {editor.kind === 'policy' && <ReviewPolicyForm policy={packet.policy} saved={saved} />}
      {editor.kind === 'delete' && <MutationForm formatError={reviewError} action={() => rpc('spa_staff_annual_review_delete', { p_id: editor.row.id, p_version: editor.row.version })} onSaved={saved} submit="確認刪除草稿"><p>{editor.row.review_year} 年草稿將被刪除，操作仍保留稽核記錄。</p></MutationForm>}
    </Modal>}
  </section>;
}

function AnnualReviewForm({ row, packet, saved }) {
  const [year, setYear] = useState(row?.review_year || Number(packet.today.slice(0, 4)));
  const [criteria, setCriteria] = useState(row?.criteria_snapshot || packet.policy.criteria);
  const [passScore, setPassScore] = useState(row?.pass_score ?? packet.policy.pass_score);
  const [scores, setScores] = useState(row?.scores || {}), [comment, setComment] = useState(row?.comment || '');
  const [state, setState] = useState(row?.status || 'draft');
  const complete = criteria.every(item => scores[item.key] !== '' && scores[item.key] != null);
  const total = complete ? criteria.reduce((sum, item) => sum + Number(scores[item.key]) * Number(item.weight) / 100, 0).toFixed(2) : null;
  const duplicate = !row && packet.reviews.some(item => item.review_year === Number(year));
  const payload = { staff_id: packet.profile.id, review_year: Number(year), version: row?.version || 0, status: state, criteria, pass_score: Number(passScore), scores: Object.fromEntries(Object.entries(scores).filter(([, value]) => value !== '' && value != null).map(([key, value]) => [key, Number(value)])), comment };
  return <MutationForm formatError={reviewError} action={() => rpc('spa_staff_annual_review_save', { p_payload: payload })} onSaved={saved} disabled={duplicate || (state === 'published' && !complete)} submit={state === 'published' ? '保存並發布考核' : '儲存考核草稿'}>
    <div className="form-grid"><Field label="考核年度"><input type="number" required min="2000" max={Number(packet.today.slice(0, 4))} disabled={!!row} value={year} onChange={event => setYear(event.target.value)} /></Field><Field label="發布狀態"><select value={state} onChange={event => setState(event.target.value)}><option value="draft">草稿（員工不可見）</option><option value="published">發布（本人可見）</option></select></Field></div>
    {duplicate && <p className="alert" role="alert">這位人員已有該年度考核，請返回列表編輯既有記錄。</p>}
    {criteria.map(item => <Field key={item.key} label={`${item.name} · 權重 ${item.weight}%`}><input type="number" min="0" max="100" step="0.01" value={scores[item.key] ?? ''} onChange={event => setScores(current => ({ ...current, [item.key]: event.target.value }))} /></Field>)}
    <Field label="達標線（0–100 分）"><input type="number" required min="0" max="100" step="0.01" value={passScore} onChange={event => setPassScore(event.target.value)} /></Field>
    <p>加權總分：{total ?? '尚未完整評分'}</p>
    <Field label="年度評語"><textarea maxLength="4000" value={comment} onChange={event => setComment(event.target.value)} /></Field>
    {row && <button type="button" onClick={() => { setCriteria(packet.policy.criteria); setPassScore(packet.policy.pass_score); setScores({}); }}>套用現行指標並清空本次評分</button>}
    <p className="muted">每項 0–100 分；總分＝各項分數 × 權重後相加，四捨五入至兩位。發布前必須完成所有指標。不完整草稿不計總分，發布不會自動調薪。</p>
  </MutationForm>;
}

function ReviewPolicyForm({ policy, saved }) {
  const [criteria, setCriteria] = useState(policy.criteria.map(item => ({ ...item }))), [passScore, setPassScore] = useState(policy.pass_score);
  const update = (index, patch) => setCriteria(current => current.map((item, i) => i === index ? { ...item, ...patch } : item));
  const weight = criteria.reduce((sum, item) => sum + Number(item.weight || 0), 0);
  return <MutationForm formatError={reviewError} action={() => rpc('spa_staff_review_policy_save', { p_criteria: criteria.map(item => ({ ...item, weight: Number(item.weight) })), p_pass_score: Number(passScore), p_version: policy.version })} onSaved={saved} disabled={weight !== 100} submit="保存門店考核制度">
    <p className="muted">初始四項各 25%、達標 70 分為門店可配置示例，附件薪資制度未指定這些數值。可依實際職務調整；不修改已保存的年度考核。</p>
    {criteria.map((item, index) => <div className="card" key={item.key} style={{ marginTop: 12 }}><div className="form-grid"><Field label="指標名稱"><input required maxLength="80" value={item.name} onChange={event => update(index, { name: event.target.value })} /></Field><Field label="權重（%）"><input required type="number" min="0.01" max="100" step="0.01" value={item.weight} onChange={event => update(index, { weight: event.target.value })} /></Field><Field wide label="考核說明"><textarea maxLength="500" value={item.description || ''} onChange={event => update(index, { description: event.target.value })} /></Field></div><button type="button" className="danger" disabled={criteria.length === 1} onClick={() => setCriteria(current => current.filter((_, i) => i !== index))}>刪除此指標</button></div>)}
    <div className="actions"><button type="button" disabled={criteria.length >= 12} onClick={() => setCriteria(current => { let index = current.length + 1; while (current.some(item => item.key === `criterion_${index}`)) index++; return [...current, { key: `criterion_${index}`, name: '', weight: 0, description: '' }]; })}>新增考核指標</button></div>
    <p className={weight === 100 ? 'muted' : 'alert'}>權重合計：{weight.toFixed(2)}%（必須為 100%）</p>
    <Field label="新考核預設達標線（0–100 分）"><input required type="number" min="0" max="100" step="0.01" value={passScore} onChange={event => setPassScore(event.target.value)} /></Field>
  </MutationForm>;
}
