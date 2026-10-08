import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState } from 'react';
import { useOperationsSnapshot } from './lib/useOperationsSnapshot.js';
import { activeOperationsTodos, changedOperationsTodos, mergeOperationsToasts, operationsTodoIdentity } from './lib/operations-notifications.js';
import './notifications.css';

const severityLabels = { urgent: '待處理', normal: '待核對', waiting: '等待確認' };
const connectionLabels = { connecting: '正在連線…', disconnected: '連線中斷，提醒保留上次狀態', offline: '目前離線，提醒保留上次狀態', error: '即時連線未成功，可手動更新', unauthenticated: '請重新登入以更新提醒' };

function BellIcon() {
  return <svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9ZM9 20a3 3 0 0 0 6 0"/></svg>;
}

function ReminderToast({ task, identity, onDismiss, onNavigate, canOpen }) {
  const element = useRef(null);
  const [paused, setPaused] = useState(false);
  useEffect(() => {
    if (paused) return;
    const timer = window.setTimeout(() => onDismiss(identity), 8000);
    return () => window.clearTimeout(timer);
  }, [identity, paused, onDismiss]);
  return <article ref={element} className={`ops-notification-toast ${task.severity || 'normal'}`} role="status" aria-live="polite" aria-atomic="true"
    onMouseEnter={() => setPaused(true)} onMouseLeave={() => setPaused(element.current?.contains(document.activeElement))}
    onFocusCapture={() => setPaused(true)} onBlurCapture={event => { if (!event.currentTarget.contains(event.relatedTarget)) setPaused(false); }}>
    <div className="ops-notification-toast-heading"><span>{severityLabels[task.severity] || severityLabels.normal}有更新</span><button type="button" className="ops-notification-close" onClick={() => onDismiss(identity)} aria-label={`關閉${task.title}彈出提醒`}>✕</button></div>
    <p><strong>{task.title}</strong><b>{task.count}</b></p>
    <button type="button" className="ops-notification-open" disabled={!canOpen} onClick={() => { onNavigate(task.module, task.context); onDismiss(identity); }}>前往查看 <span aria-hidden="true">↗</span></button>
  </article>;
}

function AccountNotifications({ userKey, allowed, onNavigate, onAccessDenied }) {
  const { data, busy, error, forbidden, refresh, status } = useOperationsSnapshot({ userKey });
  const [open, setOpen] = useState(false), [toasts, setToasts] = useState([]);
  const previous = useRef(null), bell = useRef(null);
  const accessDenied = useRef(false);
  const panelId = useId(), headingId = useId();
  const todos = useMemo(() => activeOperationsTodos(data, allowed), [data, allowed]);
  const current = new Map(todos.map(task => [task.key, task]));
  const canOpen = task => !!onNavigate && (!allowed || allowed(task.module));
  const dismiss = useCallback(identity => setToasts(items => items.filter(task => operationsTodoIdentity(task) !== identity)), []);

  // Permission loss must clear Admin's cached page/form before the next paint,
  // even when the main page's refresh is paused for an editor or modal.
  useLayoutEffect(() => {
    const firstDenial = forbidden && !accessDenied.current;
    accessDenied.current = forbidden;
    if (firstDenial) onAccessDenied?.();
  }, [forbidden, onAccessDenied]);

  useEffect(() => {
    if (!data) { previous.current = null; setToasts([]); return; }
    const changed = changedOperationsTodos(previous.current, todos);
    previous.current = todos;
    setToasts(items => open ? [] : mergeOperationsToasts(items, changed, todos));
  }, [data, todos, open]);

  function closePanel() { setOpen(false); bell.current?.focus(); }
  function navigate(task) { if (canOpen(task)) { onNavigate(task.module, task.context); setOpen(false); } }
  // Filter at render as well as in the effect: revoked/resolved reminders must
  // disappear immediately, including while an old toast is still in state.
  const visibleToasts = toasts.filter(task => current.has(task.key) && operationsTodoIdentity(current.get(task.key)) === operationsTodoIdentity(task));
  const connectionNote = status === 'connected' ? '資料變更時同步更新' : connectionLabels[status] || '正在建立即時連線…';
  const connectionBadge = error ? '更新失敗' : status === 'offline' ? '離線' : status === 'connecting' ? '連線中' : '未連線';

  return <aside className="ops-notifications" aria-label="營運待辦提醒">
    {open && <section id={panelId} className="ops-notification-panel" role="region" aria-labelledby={headingId} onKeyDown={event => { if (event.key === 'Escape') { event.stopPropagation(); closePanel(); } }}>
      <div className="ops-notification-panel-heading"><div><p>營運待辦</p><h2 id={headingId}>{data?.is_owner ? '待辦提醒' : '我的工作提醒'}</h2></div><button type="button" className="ops-notification-close" onClick={closePanel} aria-label="關閉待辦提醒">✕</button></div>
      <p className="ops-notification-summary">{todos.length} 類提醒 · 點選後前往原處理頁面</p>
      <div className="ops-notification-list">
        {!data && busy && <p className="ops-notification-empty" role="status">正在讀取提醒…</p>}
        {data && !todos.length && <p className="ops-notification-empty">目前沒有需要處理的提醒。</p>}
        {todos.map(task => <button type="button" key={task.key} className={`ops-notification-task ${task.severity || 'normal'}`} disabled={!canOpen(task)} onClick={() => navigate(task)}>
          <span><small>{severityLabels[task.severity] || severityLabels.normal}</small><strong>{task.title}</strong></span><b>{task.count}</b><i aria-hidden="true">↗</i>
        </button>)}
      </div>
      <div className="ops-notification-footer"><p role="status">{error ? `${error}${data ? ' 提醒保留上次成功讀取的狀態。' : ''}` : connectionNote}</p><button type="button" disabled={busy} onClick={() => refresh()}>{busy ? '更新中…' : '更新提醒'}</button></div>
    </section>}
    {!open && !!visibleToasts.length && <div className="ops-notification-toasts">{visibleToasts.map(item => {
      const task = current.get(item.key), identity = operationsTodoIdentity(task);
      return <ReminderToast key={identity} task={task} identity={identity} onDismiss={dismiss} onNavigate={onNavigate} canOpen={canOpen(task)}/>;
    })}</div>}
    <button ref={bell} type="button" className={`ops-notification-bell ${todos.length ? 'has-tasks' : ''}`} aria-expanded={open} aria-controls={open ? panelId : undefined} aria-label={`待辦提醒，${todos.length} 類${open ? '，已展開' : ''}${error || status !== 'connected' ? `，${error || connectionNote}` : ''}`} onClick={() => { setOpen(value => !value); setToasts([]); }}>
      <BellIcon/><span>待辦提醒</span><b>{todos.length} 類</b>{(error || status !== 'connected') && <small className="ops-notification-connection" aria-hidden="true">{connectionBadge}</small>}
    </button>
  </aside>;
}

export function OperationsNotifications({ userKey, enabled = true, allowed, onNavigate, onAccessDenied }) {
  if (!enabled || !userKey) return null;
  // Changing account remounts local baseline, dismissals and all toast timers.
  return <AccountNotifications key={String(userKey)} userKey={userKey} allowed={allowed} onNavigate={onNavigate} onAccessDenied={onAccessDenied}/>;
}
