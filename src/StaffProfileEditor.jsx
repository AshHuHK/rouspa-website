import { useState } from 'react';
import { Field, MutationForm } from './OperationsShared.jsx';
import { rpc, taipeiDate } from './lib/spa.js';
import { tenureLabel } from './lib/staff-tenure.js';
import { classificationPayload, staffClassification, technicianRanks } from './lib/staff-work-roles.js';

const statusNames = { active: '在職', departed: '已離職', inactive: '停用／未任職' };

export default function StaffProfileEditor({ row, data, catalog, saved }) {
  const titles = data.job_titles.filter(title => title.active && (!title.legacy || title.id === row?.job_title_id));
  const assignedTitle = row?.job_title_id ? data.job_titles.find(title => title.id === row.job_title_id) : null;
  const retiredTitle = assignedTitle && (!assignedTitle.active || assignedTitle.archived_at) ? assignedTitle : null;
  const firstTitle = titles.find(title => title.code === 'ft_probation') || titles.find(title => !title.legacy);
  const [form, setForm] = useState(row ? {
    ...row, payroll_effective_on:row.hire_date>taipeiDate()?row.hire_date:taipeiDate(), employment_status: row.employment_status || (row.active ? 'active' : 'inactive'),
    departed_on: row.departed_on || '', departure_reason: row.departure_reason || '', contract_started_on: row.contract_started_on || ''
  } : {
    name: '', name_en: '', title: firstTitle?.name || '', job_title_id: firstTitle?.id || '',
    employment_type_code: firstTitle?.allowed_employment_types?.[0] || 'full_time',
    hire_date: taipeiDate(), payroll_effective_on:taipeiDate(), employment_status: 'active', active: true,
    is_bookable: false, website_visible: false, departed_on: '', departure_reason: '', contract_started_on: ''
  });
  const [services, setServices] = useState(row ? catalog.skills.filter(skill => skill.staff_id === row.id && skill.enabled !== false).map(skill => skill.service_id) : []);
  const [classification, setClassification] = useState(() => ({
    ...staffClassification(row || {employment_type_code:'full_time'}, assignedTitle || firstTitle),
    counterEmployment: row?.employment_type_code === 'part_time' ? 'part_time' : 'full_time'
  }));
  const mapped = classificationPayload(classification, titles);
  const technician = classification.role === 'technician';
  const updateClassification = patch => {
    setClassification(current => ({...current, ...patch}));
    if (patch.role && patch.role !== 'technician') {
      setServices([]);
      setForm(current => ({...current, is_bookable:false, website_visible:false}));
    }
  };
  const set = (key, value) => setForm(previous => ({ ...previous, [key]: value }));
  const text = (label, key, type = 'text', options = {}) => <Field label={label}><input type={type} value={form[key] || ''} onChange={event => set(key, event.target.value)} {...options}/></Field>;
  const action = () => {
    if (!mapped) throw new Error('JOB_CLASSIFICATION_REQUIRED');
    return rpc('spa_staff_profile_save_v2', { p_payload: { ...form, ...mapped, id: row?.id || '',
      contract_started_on:mapped.employment_type_code==='contractor'?form.contract_started_on:'',
      contract_credited_from:mapped.employment_type_code==='contractor'?form.contract_credited_from:'',
      is_bookable: technician && form.employment_status === 'active' && !!form.is_bookable,
      website_visible: technician && form.employment_status === 'active' && !!form.website_visible,
      services: technician ? services : [] } });
  };
  return <MutationForm action={action} onSaved={saved}>
    {retiredTitle&&<p className="alert" role="alert">原職稱已停止使用。請保留歷史資料，請由店主明確選擇六階、兼職或承攬技師職稱後，才可重新接服務。</p>}
    {(assignedTitle?.legacy || assignedTitle?.code === 'ft_senior_advanced') && <p className="alert">這位人員仍使用舊職稱。請由店主選定新職級；系統不會依年資擅自升等。對應前的新制度薪資只能試算，不能完成結算。</p>}
    <p className="muted">排班模式為自由排班，職務提醒由「職務與排班提醒」集中維護。</p>
    <div className="form-grid">
      {text('姓名', 'name', 'text', { required: true, maxLength: 80 })}
      {text('英文姓名', 'name_en', 'text', { maxLength: 80 })}
      <Field label="職務"><select required value={classification.role} onChange={event => updateClassification({role:event.target.value})}>
        {!['owner','counter','technician'].includes(classification.role)&&<option value={classification.role} disabled>請重新選擇職務</option>}
        <option value="owner">店主</option><option value="counter">櫃檯</option><option value="technician">技師</option>
      </select></Field>
      {technician && <Field label="技師類型"><select value={classification.category === '01' ? 'full_time' : classification.category === '04' ? 'contractor' : 'part_time'} onChange={event => updateClassification({category:event.target.value === 'full_time' ? '01' : event.target.value === 'contractor' ? '04' : '03'})}>
        <option value="full_time">正職技師</option><option value="part_time">兼職技師</option><option value="contractor">承攬技師</option>
      </select></Field>}
      {technician && ['02','03'].includes(classification.category) && <Field label="兼職聘僱類型"><select value={classification.category} onChange={event => updateClassification({category:event.target.value})}>
        <option value="03">兼職時薪制</option><option value="02">兼職月薪制</option>
      </select></Field>}
      {technician && ['01','02'].includes(classification.category) && <Field label="技師職級"><select required value={classification.rankCode} onChange={event => updateClassification({rankCode:event.target.value})}>
        <option value="" disabled>請選擇職級</option>{technicianRanks.map(([code,name]) => <option key={code} value={code}>{name}</option>)}
      </select></Field>}
      {classification.role === 'counter' && <Field label="聘僱類型"><select value={classification.counterEmployment} onChange={event => updateClassification({counterEmployment:event.target.value})}>
        <option value="full_time">正職</option><option value="part_time">兼職</option>
      </select></Field>}
      {text('手機', 'phone', 'tel')}{text('電子郵件（選填）', 'email', 'email')}
      {text('分類生效日期', 'payroll_effective_on', 'date', {required:true, min:form.hire_date||'1900-01-01'})}{text('生日', 'birth_date', 'date')}{text('到職日', 'hire_date', 'date')}
      {mapped?.employment_type_code === 'contractor' && <>{text('承攬年資合併起日（選填）','contract_credited_from','date',{min:form.hire_date||'1900-01-01',max:form.contract_started_on||undefined})}{text('承攬合作開始日期', 'contract_started_on', 'date', { required: true, min: form.hire_date || '1900-01-01', max: form.departed_on || undefined })}<p className="muted">請填實際開始承攬的日期，用於核對承攬年資與薪資制度。</p></>}
      <Field label="工作年資"><input readOnly value={tenureLabel({hire_date:form.hire_date,departed_on:form.departed_on})} /></Field>
      <Field label="任職狀態"><select value={form.employment_status} onChange={event => {
        const value = event.target.value;
        setForm(previous => ({ ...previous, employment_status: value, active: value === 'active',
          departed_on: value === 'departed' ? previous.departed_on || taipeiDate() : '',
          departure_reason: value === 'departed' ? previous.departure_reason : '',
          is_bookable: value === 'active' && previous.is_bookable, website_visible: value === 'active' && previous.website_visible }));
      }}>{Object.entries(statusNames).map(([value, label]) => <option key={value} value={value}>{label}</option>)}</select></Field>
      {form.employment_status === 'departed' && <>
        {text('離職日期', 'departed_on', 'date', { required: true, min: form.hire_date || undefined })}
        <Field wide label="離職原因"><textarea required maxLength={1000} value={form.departure_reason} onChange={event => set('departure_reason', event.target.value)}/></Field>
      </>}
      {text('頭像網址', 'photo_url', 'url')}{text('地址', 'address')}{text('專長', 'specialty')}
      <Field label="預約接單"><select disabled={!technician || form.employment_status !== 'active'} value={String(!!form.is_bookable)} onChange={event => set('is_bookable', event.target.value === 'true')}><option value="false">不接單</option><option value="true">可接單</option></select></Field>
      <Field label="官網顯示"><select disabled={!technician || form.employment_status !== 'active'} value={String(!!form.website_visible)} onChange={event => set('website_visible', event.target.value === 'true')}><option value="false">隱藏</option><option value="true">顯示</option></select></Field>
      <Field wide label="人員介紹"><textarea maxLength={2000} value={form.bio || ''} onChange={event => set('bio', event.target.value)}/></Field>
      {technician && <Field wide label="可提供療程"><div className="os-check-grid">{catalog.services.filter(service => service.status !== 'archived').map(service => <label key={service.id}><input type="checkbox" checked={services.includes(service.id)} onChange={event => setServices(event.target.checked ? [...services, service.id] : services.filter(id => id !== service.id))}/>{service.name}</label>)}</div></Field>}
    </div>
    <p className="muted">正職及兼職月薪技師採六階；兼職時薪及承攬不設職級。店主可直接修改分類；從生效日起分段計薪，無須建立新制度。月薪按當月日數拆算，已結算金額保留。登入權限由帳號角色決定。</p>
    <p className="muted">年資按台灣日期由到職日計算，離職後截至離職日。薪資在「薪資與提成」設定。</p>
  </MutationForm>;
}
