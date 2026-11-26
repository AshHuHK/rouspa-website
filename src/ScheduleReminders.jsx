import {useState} from 'react';
import {Field,MutationForm,Empty} from './OperationsShared.jsx';
import {rpc} from './lib/spa.js';

export function ScheduleReminder({value}) {
 if(!value?.text?.trim())return null;
 return <aside className="staff-schedule-reminder" aria-label="職務排班提醒">
  <h3>{value.name}排班提醒</h3>
  <p>{value.text}</p>
  {value.role_code!=='contractor'&&<p className="staff-schedule-rights">以上受僱人員的排班規範均不影響依法享有的請假權益。</p>}
 </aside>;
}

function ReminderForm({row,saved}) {
 const [text,setText]=useState(row.reminder_text);
 return <section className="schedule-reminder-editor">
  <h3>{row.name}</h3>
  <MutationForm action={()=>rpc('spa_schedule_reminder_save',{p_role:row.role_code,p_text:text,p_version:row.version})} onSaved={saved} submit="儲存提醒">
   <Field label={row.name+'排班提醒文字'}><textarea rows={5} maxLength={4000} value={text} onChange={event=>setText(event.target.value)}/></Field>
   <div className="actions"><button type="button" disabled={!text} onClick={()=>setText('')}>清空文字</button></div>
  </MutationForm>
 </section>;
}

export function ScheduleReminderSettings({rows=[],saved}) {
 return <div className="schedule-reminder-settings">
  <p>所有職務均為自由排班。提醒依人員目前生效的薪資類別讀取，尚未分配者依聘僱類型與薪酬方式判斷。</p>
  <p className="muted">每個職務共用一份文字。清空後按儲存，員工日曆即隱藏該提醒。</p>
  {!rows.length&&<Empty>尚未載入職務排班提醒。</Empty>}
  {rows.map(row=><ReminderForm key={row.role_code+':'+row.version} row={row} saved={saved}/>)}
 </div>;
}
