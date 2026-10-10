import { useState } from 'react';
import { Field, MutationForm } from './OperationsShared.jsx';
import { cents, rpc } from './lib/spa.js';
import { workCategoryNames } from './lib/staff-work-roles.js';

const keyOf = profile => `${profile.job_title_id}|${profile.employment_type_code}`;
const initial = profile => ({
  pay_basis: profile.pay_basis || 'monthly', base_pay: Number(profile.base_pay_cents || 0) / 100,
  service_commission: Number(profile.service_commission_bps || 0) / 100,
  product_commission: Number(profile.product_commission_bps || 0) / 100,
  designated_bonus: Number(profile.designated_client_bonus_bps || 0) / 100,
  minimum_attendance: Number(profile.minimum_attendance_minutes || 0) / 60,
  minimum_service: Number(profile.minimum_service_minutes || 0) / 60,
  commission_start: Number(profile.commission_start_service_minutes || 0) / 60,
  service_commission_mode: profile.service_commission_mode || 'none',
  self_sourced: Number(profile.self_sourced_commission_bps || 0) / 100,
  contractor_count_scope: profile.contractor_count_scope || 'lifetime',
  service_policy_status: profile.service_policy_status || 'confirmed', active: profile.active ?? true
});

export default function PayrollPolicyEditor({ data, rule, saved }) {
  const profiles = (data.compensation_profiles || []).filter(profile => !profile.legacy && profile.rule_version_id === rule?.id);
  const [selected, setSelected] = useState(profiles[0] ? keyOf(profiles[0]) : '');
  const profile = profiles.find(value => keyOf(value) === selected) || profiles[0];
  if (!profile) return <p className="alert">此版本沒有可編輯的新制職稱設定。歷史制度保留原規則；請切換正在使用的新版本。</p>;
  return <><Field label="職稱 × 聘僱類型"><select value={keyOf(profile)} onChange={event => setSelected(event.target.value)}>
    {Object.entries(workCategoryNames).filter(([category]) => category !== 'legacy').map(([category, label]) => <optgroup key={category} label={label}>
      {profiles.filter(value => value.work_category === category).map(value => <option key={keyOf(value)} value={keyOf(value)}>{value.job_title_name} · {value.employment_type_name}</option>)}
    </optgroup>)}
  </select></Field><ProfileFields key={`${rule.id}:${keyOf(profile)}`} profile={profile} rule={rule} saved={saved}/></>;
}

function ProfileFields({ profile, rule, saved }) {
  const [form, setForm] = useState(() => initial(profile));
  const set = (key, value) => setForm(previous => ({ ...previous, [key]: value }));
  const technician = profile.work_category === 'technician', contractor = profile.employment_type_code === 'contractor';
  const percent = value => Math.round(Number(value || 0) * 100), minutes = value => Math.round(Number(value || 0) * 60);
  const action = () => rpc('spa_compensation_profile_save_v3', { p_rule: rule.id, p_payload: {
    job_title_id: profile.job_title_id, employment_type_code: profile.employment_type_code,
    pay_basis: contractor ? 'session' : form.pay_basis, base_pay_cents: contractor ? 0 : cents(form.base_pay || 0),
    service_commission_bps: technician ? percent(form.service_commission) : 0,
    product_commission_bps: percent(form.product_commission), designated_client_bonus_bps: technician ? percent(form.designated_bonus) : 0,
    minimum_attendance_minutes: technician ? minutes(form.minimum_attendance) : 0,
    minimum_service_minutes: technician ? minutes(form.minimum_service) : 0,
    commission_start_service_minutes: technician ? minutes(form.commission_start) : 0,
    service_commission_mode: technician ? form.service_commission_mode : 'none',
    self_sourced_commission_bps: contractor ? percent(form.self_sourced) : 0,
    contractor_count_scope: contractor ? form.contractor_count_scope : null,
    service_policy_status: form.service_policy_status, active: form.active
  } });
  const number = (label, key, max, step = '0.01') => <Field label={label}><input required type="number" min="0" max={max} step={step} value={form[key]} onChange={event => set(key, event.target.value)}/></Field>;
  const editable = rule.status === 'active';
  return <MutationForm action={action} onSaved={saved} disabled={!editable} submit="儲存此版本職稱薪資">
    <div className="payroll-editor-heading"><div><span className="badge">v{rule.version_no}</span><strong>{profile.job_title_name} · {profile.employment_type_name}</strong></div><small>同職稱共用，登入權限不影響抽成資格。</small></div>
    <fieldset disabled={!editable} className="payroll-policy-fields">
      <h3>基本薪酬與商品抽成</h3>
      {!technician && <p className="muted">附件未規定店主／櫃台的本薪，既有設定保留，缺少設定需店主填寫後啟用。這兩種職務不產生服務抽成。</p>}
      <div className="form-grid">
        <Field label="基本薪酬方式"><select disabled={contractor} value={form.pay_basis} onChange={event => set('pay_basis', event.target.value)}>
          <option value="monthly">月薪</option><option value="hourly">時薪</option><option value="session">每堂薪酬</option>
        </select></Field>
        {contractor ? <Field label="承攬基本薪酬"><input readOnly value="無底薪／時薪，按服務抽成"/></Field> : number(`基本薪酬 NT$（${form.pay_basis === 'hourly' ? '每小時' : form.pay_basis === 'session' ? '每堂' : '每月'}）`, 'base_pay', 100000000)}
        {number('商品銷售抽成（%，新成交快照）', 'product_commission', 100)}
        <Field label="設定狀態"><select value={String(form.active)} onChange={event => set('active', event.target.value === 'true')}><option value="true">已核對／啟用</option><option value="false">未完成設定／停用</option></select></Field>
      </div>
      {technician && <>
        <h3>服務抽成</h3><p className="muted">每堂只歸實際技師，依成交順序累計；跨級距的收入按該堂分鐘分段，不回頭重算前面的服務。</p>
        <div className="form-grid">
          <Field label="普通服務抽成方式"><select value={form.service_commission_mode} onChange={event => set('service_commission_mode', event.target.value)}><option value="ordered_tiers">依此職稱累進階梯</option><option value="flat">固定比例</option><option value="none">不計普通服務抽成</option></select></Field>
          {form.service_commission_mode === 'flat' && number('固定服務比例（%）', 'service_commission', 100)}
          {number('指定客加成（該堂服務淨收入 %）', 'designated_bonus', 100)}
          {number('服務抽成資格：核准出勤至少（小時）', 'minimum_attendance', 1666, '0.01')}
          {number(profile.employment_type_code==='part_time'?'服務抽成資格：服務時數超過（小時）':'服務抽成資格：服務時數至少（小時）', 'minimum_service', 1666, '0.01')}
          {form.service_commission_mode === 'flat' && number('固定比例服務起算門檻（小時）', 'commission_start', 1666, '0.01')}
          {contractor && <>
            {number('自帶客抽成（該堂服務淨收入 %）', 'self_sourced', 100)}
            <Field label="承攬堂數累計範圍"><select value={form.contractor_count_scope} onChange={event => set('contractor_count_scope', event.target.value)}><option value="lifetime">合作期間累計，不按月重置</option><option value="period">每個自然月重新累計</option></select></Field>
          </>}
          <Field label="制度條款核對"><select value={form.service_policy_status} onChange={event => set('service_policy_status', event.target.value)}><option value="confirmed">已確認</option><option value="needs_confirmation">待確認，禁止結算</option></select></Field>
        </div>
        {form.service_commission_mode === 'ordered_tiers' && <p className="muted">各職級每階的起點、終點與比例，請到「職稱抽成階梯」編輯；前段不抽成的區間也會明確列出。</p>}
        {form.service_commission_mode === 'none' && <p className="muted">此選項只停普通服務抽成；指定客加成與承攬自帶客另依設定及資格計算。若全部停用，請將各比例設為 0。</p>}
        {contractor && <p className="muted">自帶客需在實際訂單明細由店主確認；該堂採自帶客比例，不另疊加普通抽成及指定客加成。滿五年僅為申請合作的參考，不自動轉制。</p>}
      </>}
    </fieldset>
    <p className="muted">金額用 NT$ 元，比例用 %，門檻用小時。商品按成交時保存的比例計算，後來改設定不追溯改寫已售商品抽成。版本及已結算來源快照保留。</p>
  </MutationForm>;
}
