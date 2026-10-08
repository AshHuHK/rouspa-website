import { useEffect, useId, useRef, useState } from 'react';
import { supabase } from './lib/spa.js';
import './steward.css';

const manualUrl = 'https://github.com/AshHuHK/rouspa-website/blob/main/ROU_SPA_OPERATING_MANUAL.md';
const suggestions = {
 dashboard: ['目前有哪些營運事項需要優先處理？', '營運首頁的數字如何解讀？'],
 bookings: ['這段日期的預約有哪些待處理事項？', '改期與更換實際服務技師要注意什麼？'],
 customers: ['顧客、會員、儲值與套票有什麼差別？', '刪除或封存顧客會如何影響歷史紀錄？'],
 pos: ['收款與結帳前要核對哪些事項？', '儲值、套票與優惠券如何使用？'],
 team: ['排班與請假的處理流程是什麼？', '人員封存後，歷史資料如何保留？'],
 payroll: ['這段期間的薪資結算前要核對什麼？', '服務提成與工時計算有什麼規則？'],
 catalog: ['療程價格與上下架如何影響預約？', '床位、療程資格與緩衝時間如何設定？'],
 reviews: ['評價與意見回饋如何處理？', '評價優惠券的使用規則是什麼？'],
 reports: ['如何解讀這段期間的營運報表？', '營業日期與入帳日期有什麼差別？'],
 access: ['不同人員可以查看與操作哪些功能？', '帳號啟用、停用與密碼重設如何處理？'],
 settings: ['營業時間與預約範圍如何設定？', '調整門店設定前要注意什麼？'],
 self: ['我這段期間的服務與出勤如何計算？', '如何申請補打卡或班表更動？'],
};

function StewardIcon() {
 return <svg viewBox="0 0 32 32" fill="none" aria-hidden="true"><path d="M9 10h14a4 4 0 0 1 4 4v9a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4v-9a4 4 0 0 1 4-4Z"/><path d="M16 10V6M13 22c2 2 4 2 6 0M2 17v5M30 17v5"/><circle cx="11" cy="17" r="1" fill="currentColor" stroke="none"/><circle cx="21" cy="17" r="1" fill="currentColor" stroke="none"/><path d="m25 2 1 3 3 1-3 1-1 3-1-3-3-1 3-1Z"/></svg>;
}

function contextTime(value) {
 if (!value) return '';
 const date = new Date(value);
 return Number.isNaN(date.getTime()) ? '' : date.toLocaleString('zh-TW', { timeZone: 'Asia/Taipei', hour12: false, month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' });
}

function AccountSteward({ userKey, page, pageLabel, range, disabled, onAccessDenied }) {
 const [open, setOpen] = useState(false), [question, setQuestion] = useState(''), [messages, setMessages] = useState([]);
 const [busy, setBusy] = useState(false), [pendingQuestion, setPendingQuestion] = useState(''), [error, setError] = useState('');
 const surface = useRef(null), launcher = useRef(null), conversation = useRef(null), request = useRef(null), sequence = useRef(0);
 const panelId = useId(), headingId = useId(), inputId = useId(), helpId = useId();

 function cancelRequest() {
  sequence.current++; request.current?.abort(); request.current = null;
  setBusy(false); setPendingQuestion('');
 }
 function closePanel(returnFocus = false) {
  cancelRequest(); setOpen(false);
  if (returnFocus && surface.current?.contains(document.activeElement)) launcher.current?.focus();
 }
 function clearConversation() { cancelRequest(); setMessages([]); setQuestion(''); setError(''); }

 useEffect(() => () => { sequence.current++; request.current?.abort(); }, []);
 useEffect(() => {
  const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, session) => {
   if (session?.user?.id !== userKey) { clearConversation(); setOpen(false); }
  });
  return () => subscription.unsubscribe();
 }, [userKey]);
 useEffect(() => { if (disabled) closePanel(); }, [disabled]);
 useEffect(() => {
  if (!open) return;
  const outside = event => { if (!surface.current?.contains(event.target)) closePanel(); };
  document.addEventListener('pointerdown', outside);
  document.addEventListener('focusin', outside);
  return () => { document.removeEventListener('pointerdown', outside); document.removeEventListener('focusin', outside); };
 }, [open]);
 useEffect(() => {
  if (open && conversation.current) conversation.current.scrollTop = conversation.current.scrollHeight;
 }, [open, messages, pendingQuestion, error]);

 async function ask(event) {
  event?.preventDefault();
  const content = question.trim();
  if (!content || request.current || disabled) return;
  const controller = new AbortController(), turn = ++sequence.current;
  request.current = controller; setBusy(true); setPendingQuestion(content); setError('');
  const timeout = window.setTimeout(() => controller.abort(), 90000);
  try {
   const { data, error: sessionError } = await supabase.auth.getSession();
   if (controller.signal.aborted || turn !== sequence.current) return;
   if (sessionError || !data.session?.access_token || data.session.user.id !== userKey) {
    setMessages([]); setQuestion(''); throw new Error('登入狀態已變更，請重新登入後再詢問。');
   }
   const response = await fetch('/api/ask-steward', {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${data.session.access_token}` }, signal: controller.signal,
    body: JSON.stringify({ question: content, page, range: { from: range.from, to: range.to }, history: messages.slice(-12).map(({ role, content: text }) => ({ role, content: text })) }),
   });
   if (controller.signal.aborted || turn !== sequence.current) return;
   // Revoke the cached answers before reading any response body on permission loss.
   if (response.status === 401 || response.status === 403) {
    setMessages([]); setQuestion('');
    if (response.status === 403) onAccessDenied?.();
    throw new Error('登入或權限已變更，對話已清除。請重新確認帳號權限。');
   }
   const result = await response.json().catch(() => null);
   if (controller.signal.aborted || turn !== sequence.current) return;
   if (!response.ok) throw new Error(typeof result?.error === 'string' ? result.error.slice(0, 240) : '問管家暫時無法回覆，請稍後再試。');
   if (typeof result?.answer !== 'string' || !result.answer.trim()) throw new Error('這次沒有取得完整回覆，請稍後再試。');
   setMessages(items => [...items, { role: 'user', content }, { role: 'assistant', content: result.answer, context: result.context, sources: Array.isArray(result.sources) ? result.sources.slice(0, 8) : [] }].slice(-24));
   setQuestion('');
  } catch (failure) {
   if (turn === sequence.current) setError(failure.name === 'AbortError' ? '回覆等候較久，已停止這次詢問。請稍後再試。' : failure.message || '連線未成功，請稍後再試。');
  } finally {
   window.clearTimeout(timeout);
   if (turn === sequence.current) { request.current = null; setBusy(false); setPendingQuestion(''); }
  }
 }

 return <aside ref={surface} className="ops-steward" aria-label="問管家 AI 助理" onKeyDown={event => { if (event.key === 'Escape' && open) { event.stopPropagation(); closePanel(true); } }}>
  <button ref={launcher} type="button" className="ops-steward-launcher" disabled={disabled} aria-label={open ? '收合問管家 AI 助理' : '開啟問管家 AI 助理'} aria-expanded={open} aria-controls={open ? panelId : undefined} onClick={() => open ? closePanel() : setOpen(true)}><StewardIcon/><span>問管家</span><small>AI</small></button>
  {open && <section id={panelId} className="ops-steward-panel" role="region" aria-labelledby={headingId}>
   <header className="ops-steward-heading"><div><span>KIMI · 營運助理</span><h2 id={headingId}>問管家</h2></div><button type="button" className="ops-steward-close" aria-label="關閉問管家" onClick={() => closePanel(true)}>✕</button></header>
   <p className="ops-steward-intro" id={helpId}>依目前頁面與你的權限回答，僅提供建議。</p>
   <div className="ops-steward-context"><span>{pageLabel}</span><span>唯讀諮詢 · 不會更動資料</span></div>
   <div ref={conversation} className="ops-steward-conversation" role="log" aria-live="polite" aria-relevant="additions text" aria-label="與問管家的對話" aria-busy={busy}>
    {!messages.length && !pendingQuestion && <div className="ops-steward-welcome"><StewardIcon/><h3>一起釐清下一步</h3><p>詢問本頁狀況、操作步驟或門店規則。問管家會參考操作手冊與有權限讀取的最新摘要。</p><div className="ops-steward-suggestions">{(suggestions[page] || suggestions.dashboard).map(text => <button type="button" key={text} onClick={() => setQuestion(text)}>{text}<span aria-hidden="true">↗</span></button>)}</div></div>}
    {messages.map((message, index) => <article key={index} className={`ops-steward-message ${message.role}`} aria-label={message.role === 'user' ? '你的提問' : '問管家的回覆'}><strong>{message.role === 'user' ? '你' : '問管家'}</strong><div className="ops-steward-answer">{message.content.split(/\n\s*\n/).map((paragraph, paragraphIndex) => <p key={paragraphIndex}>{paragraph}</p>)}</div>{message.role === 'assistant' && <>{message.context && <p className="ops-steward-answer-context">{typeof message.context.pageLabel === 'string' ? message.context.pageLabel : pageLabel}{contextTime(message.context.asOf) ? ` · ${contextTime(message.context.asOf)}（台灣時間）` : ''}</p>}{!!message.sources?.length && <div className="ops-steward-sources" aria-label="回覆參考來源">{message.sources.filter(source => typeof source?.label === 'string').map((source, sourceIndex) => <span key={sourceIndex} title={typeof source.section === 'string' ? source.section : undefined}>{source.label}</span>)}</div>}</>}</article>)}
    {pendingQuestion && <><article className="ops-steward-message user"><strong>你</strong><p>{pendingQuestion}</p></article><p className="ops-steward-thinking" role="status">正在核對手冊與可讀取的門店摘要…</p></>}
    {error && <p className="ops-steward-error" role="alert">{error}</p>}
   </div>
   <form className="ops-steward-form" onSubmit={ask}><label htmlFor={inputId}>詢問{pageLabel}</label><textarea id={inputId} value={question} maxLength={2000} rows={2} placeholder="例如：這個頁面有哪些待處理事項？" aria-describedby={helpId} disabled={busy} onChange={event => setQuestion(event.target.value)} onKeyDown={event => { if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) { event.preventDefault(); ask(); } }}/><div className="ops-steward-form-actions"><span>Enter 送出 · Shift + Enter 換行</span><button type="submit" className="primary" disabled={busy || !question.trim()}>{busy ? '回答中…' : '詢問'}</button></div></form>
   <footer className="ops-steward-footer"><a href={manualUrl} target="_blank" rel="noopener noreferrer">查看完整操作手冊 ↗</a><button type="button" onClick={clearConversation} disabled={!messages.length && !question && !busy && !error}>清除對話</button></footer>
  </section>}
 </aside>;
}

export function AskSteward({ userKey, accessKey, ...props }) {
 if (!userKey) return null;
 // Remount before paint when account or effective permissions change. No chat is persisted.
 return <AccountSteward key={`${userKey}:${accessKey}`} userKey={userKey} {...props}/>;
}
