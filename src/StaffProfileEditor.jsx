import { useState } from 'react';
import { Field, MutationForm } from './OperationsShared.jsx';
import { rpc, taipeiDate } from './lib/spa.js';
import { tenureLabel } from './lib/staff-tenure.js';
import { allowedEmploymentTypes, isTechnician, workCategoryNames } from './lib/staff-work-roles.js';

const statusNames = { active: '在職', departed: '已離職', inactive: '停用／未任職' };

export default function StaffProfileEditor({ row, data, catalog, saved }) {
  const titles = data.job_titles.filter(title => title.active && (!title.legacy || title.id === row?.job_title_id));
  const firstTitle = titles.find(title => title.code === 'ft_probation') || titles.find(title => !title.legacy);
  const [form, setForm] = useState(row ? {
    ...row, employment_status: row.employment_status || (row.active ? 'active' : 'inactive'),
    departed_on: row.departed_on || '', departure_reason: row.departure_reason || '', contract_started_on: row.contract_started_on || ''
  } : {
    name: '', name_en: '', title: firstTitle?.name || '', job_title_id: firstTitle?.id || '',
    employment_type_code: firstTitle?.allowed_employment_types?.[0] || 'full_time',
    hire_date: taipeiDate(), employment_status: 'active', active: true,
    is_bookable: false, website_visible: false, departed_on: '', departure_reason: '', contract_started_on: ''
  });
  const [services, setServices] = useState(row ? catalog.skills.filter(skill => skill.staff_id === row.id && skill.enabled !== false).map(skill => skill.service_id) : []);
  const title = titles.find(value => value.id === form.job_title_id);
  const employmentOptions = allowedEmploymentTypes(title, row);
  const technician = isTechnician({ ...title, job_title_code: title?.code });
  const set = (key, value) => setForm(previous => ({ ...previous, [key]: value }));
  const selectTitle = id => {
    const next = titles.find(value => value.id === id);
    const types = allowedEmploymentTypes(next, row);
    const canServe = isTechnician({ ...next, job_title_code: next?.code });
    setForm(previous => ({ ...previous, job_title_id: id, title: next?.name || '',
      employment_type_code: types.includes(previous.employment_type_code) ? previous.employment_type_code : types[0] || '',
      is_bookable: canServe && previous.is_bookable, website_visible: canServe && previous.website_visible }));
    if (!canServe) setServices([]);
  };
  const text = (label, key, type = 'text', options = {}) => <Field label={label}><input type={type} value={form[key] || ''} onChange={event => set(key, event.target.value)} {...options}/></Field>;
  const action = () => {
    if (!title || !employmentOptions.includes(form.employment_type_code)) throw new Error('INVALID_TITLE_EMPLOYMENT');
    return rpc('spa_staff_profile_save_v2', { p_payload: { ...form, id: row?.id || '',
      is_bookable: technician && form.employment_status === 'active' && !!form.is_bookable,
      website_visible: technician && form.employment_status === 'active' && !!form.website_visible,
      services: technician ? services : [] } });
  };
  return <MutationForm action={action} onSaved={saved}>
    {title?.legacy && <p className="alert">這位人員仍使用舊職稱。請由店主選定新職級；系統不會依年資擅自升等。對應前的新制度薪資只能試算，不能完成結算。</p>}
    <div className="form-grid">
      {text('姓名', 'name', 'text', { required: true, maxLength: 80 })}
      {text('英文姓名', 'name_en', 'text', { maxLength: 80 })}
      <Field label="職務／技師職級"><select required value={form.job_title_id || ''} onChange={event => selectTitle(event.target.value)}>
        <option value="" disabled>請選職稱</option>
        {Object.entries(workCategoryNames).map(([category, label]) => <optgroup key={category} label={label}>
          {titles.filter(item => item.work_category === category).map(item => <option key={item.id} value={item.id}>{item.name}</option>)}
        </optgroup>)}
      </select></Field>
      <Field label="聘僱類型"><select required disabled={employmentOptions.length === 1} value={form.employment_type_code || ''} onChange={event => set('employment_type_code', event.target.value)}>
        {data.employment_types.filter(item => employmentOptions.includes(item.code)).map(item => <option key={item.code} value={item.code}>{item.name}</option>)}
      </select></Field>
      {text('手機', 'phone', 'tel')}{text('電子郵件（選填）', 'email', 'email')}
      {text('生日', 'birth_date', 'date')}{text('到職日', 'hire_date', 'date')}
      {form.employment_type_code === 'contractor' && <>{text('承攬合作開始日期', 'contract_started_on', 'date', { required: true, min: form.hire_date || '1900-01-01', max: form.departed_on || undefined })}<p className="muted">請填實際開始承攬的日期。合作前的正職服務不計入承攬 100 堂；缺日期時只能試算，不能結算，不會用到職日代填。</p></>}
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
    <p className="muted">店主為單一職位；櫃台只可正職／兼職；正職技師採七階，兼職及承攬技師各一職位。登入權限另由帳號角色決定。</p>
    <p className="muted">年資按台灣日期由到職日即時計算，離職後截至離職日；未填到職日顯示待補，不猜歷史資料。年資及年度考核不會自動晉升或調薪。薪資僅在「薪資與提成」設定。</p>
  </MutationForm>;
}
