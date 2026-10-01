import { useEffect, useRef, useState, cloneElement, isValidElement } from 'react';
import { supabase, rpc, errorText } from './lib/spa.js';
import './operations.css';
export function useSession() {
  const [session, setSession] = useState(undefined);
  useEffect(() => {
    let live = true;
    supabase.auth.getSession().then(({ data }) => { if (live) setSession(data.session); });
    const { data: { subscription } } = supabase.auth.onAuthStateChange((_event, next) => { if (live) setSession(next); });
    return () => { live = false; subscription.unsubscribe(); };
  }, []);
  return session;
}
export function Login({ title = '管理後台' }) {
  const [loginName, setLoginName] = useState(''); const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false); const [error, setError] = useState('');
  async function login(e) {
    e.preventDefault(); setBusy(true); setError('');
    try {
      if (loginName.includes('@')) { const {error} = await supabase.auth.signInWithPassword({email:loginName.trim(),password});if(error)throw error; }
      else {
        const {data,error} = await supabase.functions.invoke('staff-login',{body:{username:loginName,password}});
        if(error){let code='';try{code=(await error.context?.json())?.error||'';}catch{}throw new Error(code||'ACCOUNT_SERVICE_UNAVAILABLE');}
        if(data?.error)throw new Error(data.error);
        if(!data?.access_token||!data?.refresh_token)throw new Error('INVALID_LOGIN');
        const {error:sessionError}=await supabase.auth.setSession({access_token:data.access_token,refresh_token:data.refresh_token});if(sessionError)throw sessionError;
      }
    }
    catch (err) { setError(errorText(err)); } finally { setBusy(false); }
  }
  return <div className="ops"><div className="login card"><h1>柔療髮浴</h1><p>{title}</p><p className="muted">請使用門店為您建立的帳號登入。</p><form onSubmit={login}><label>使用者名稱或電子郵件<input autoComplete="username" required maxLength={254} value={loginName} onChange={e=>setLoginName(e.target.value)}/></label><label>密碼<input type="password" autoComplete="current-password" required value={password} onChange={e=>setPassword(e.target.value)}/></label>{error&&<p role="alert" className="alert">{error}</p>}<button className="primary" disabled={busy}>{busy?'登入中…':'登入'}</button></form><p><a href="#">返回首頁</a></p></div></div>;
}
export function Field({ label, children, wide = false }) {
 const control=isValidElement(children)&&['input','select','textarea'].includes(children.type)
  ?cloneElement(children,{'aria-label':children.props['aria-label']||label}):children;
 return <label className={wide?'wide':''}>{label}{control}</label>;
}
export function Modal({ title, children, onClose }) {
  const ref = useRef(null);
  useEffect(()=>{ref.current.showModal();},[]);
  return <dialog ref={ref} onCancel={e=>{e.preventDefault();onClose();}}><div className="row" style={{justifyContent:'space-between'}}><h2>{title}</h2><button type="button" onClick={onClose} aria-label="關閉">✕</button></div>{children}</dialog>;
}
export function Empty({ children = '目前沒有記錄。' }) { return <p className="empty">{children}</p>; }
export function Method({ value, onChange }) { return <select value={value} onChange={e=>onChange(e.target.value)}><option value="cash">現金</option><option value="card">刷卡（已在店內收款）</option><option value="transfer">轉帳（已核對入帳）</option></select>; }
export function MutationForm({ action, onSaved, children, submit = '儲存' }) {
  const [busy,setBusy]=useState(false),[error,setError]=useState('');
  const request=useRef(crypto.randomUUID());
  return <form onSubmit={async e=>{e.preventDefault();if(busy)return;setBusy(true);setError('');try{await action(request.current);await onSaved();}catch(err){setError(errorText(err));}finally{setBusy(false);}}}>{children}{error&&<p className="alert" role="alert">{error}</p>}<div className="actions"><button className="primary" disabled={busy}>{busy?'處理中…':submit}</button></div></form>;
}
export function PrivateLink({ path, label }) {
  const [copied,setCopied]=useState(false),[error,setError]=useState('');
  const url=`${location.origin}${location.pathname}#${path}`;
  return <div className="actions"><a className="button" href={url} target="_blank" rel="noreferrer">{label}</a><button type="button" onClick={async()=>{try{await navigator.clipboard.writeText(url);setCopied(true);}catch{setError('複製失敗，請開啟連結後複製網址。');}}}>{copied?'已複製':'複製私人連結'}</button>{error&&<span role="alert">{error}</span>}</div>;
}
export { rpc };
