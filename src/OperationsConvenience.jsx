import { useOperationsSnapshot } from './lib/useOperationsSnapshot.js';
import { activeOperationsTodos, operationsTodoTotal } from './lib/operations-notifications.js';
import './convenience.css';

const taskLabels={urgent:'待處理',normal:'待核對',waiting:'等待確認'};

export function OperationsConvenience({refreshToken,onNavigate,allowed,userKey,staffPage=false}){
 const {data,busy,error}=useOperationsSnapshot({userKey,refreshToken});
 const canOpen=module=>!!onNavigate&&(!allowed||allowed(module));
 const go=(module,context)=>{if(canOpen(module))onNavigate(module,context);};
 const todos=activeOperationsTodos(data,allowed),todoTotal=operationsTodoTotal(todos);
 return <div className="ops-convenience">
  <section className="card ops-todo-center" aria-labelledby="ops-todo-title">
   <div className="ops-convenience-heading">
    <h2 id="ops-todo-title">{staffPage?'我的工作提醒':'營運待辦中心'}</h2>
    {data&&<span className="ops-todo-total">{todoTotal} 項待辦 · {todos.length} 類提醒</span>}
   </div>
   {error&&<p className="alert" role="alert">{error}{data?'；以下保留上次成功讀取的狀態。':''}</p>}
   {!data&&busy&&<p className="empty" role="status">正在讀取待辦…</p>}
   {data&&(todos.length?<div className="ops-todo-grid">{todos.map(task=><button key={task.key} className={`ops-todo ${task.severity}`} disabled={!canOpen(task.module)} onClick={()=>go(task.module,task.context)}><span className="ops-todo-tag">{taskLabels[task.severity]||taskLabels.normal}</span><strong className="ops-todo-count">{task.count}</strong><h3>{task.title}</h3><p>{task.description}</p><span className="ops-todo-open">{task.severity==='waiting'?'查看狀態':'前往查看'} <i aria-hidden="true">↗</i></span></button>)}</div>:<p className="empty">目前沒有需要處理的提醒。</p>)}
  </section>
 </div>;
}
