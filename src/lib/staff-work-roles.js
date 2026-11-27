const legacyTechnicianCodes = new Set(['therapist', 'senior_therapist', 'part_time']);

export const workCategoryNames = { owner: '店主', counter: '櫃台', technician: '技師', legacy: '舊職稱・待對應' };

export function isTechnician(person) {
  if (person.work_category === 'technician') return true;
  return person.legacy === true && legacyTechnicianCodes.has(person.job_title_code || person.code);
}

export function allowedEmploymentTypes(title, current) {
  const allowed = Array.isArray(title?.allowed_employment_types) ? title.allowed_employment_types : [];
  // Existing legacy assignments remain editable without inventing a new rank.
  if (title?.legacy && current?.job_title_id === title.id) return [current.employment_type_code];
  return allowed;
}

export function isCurrentStaff(person) {
  return !person.archived_at && person.active !== false &&
    (!person.employment_status || person.employment_status === 'active');
}

export function posEligibleStaff(item, catalog) {
  return (catalog.staff || []).filter(person => isCurrentStaff(person) && (
    item.item_type === 'product' || (isTechnician(person) && (catalog.skills || []).some(skill =>
      skill.staff_id === person.id && skill.service_id === item.id && skill.enabled !== false
    ))
  ));
}


export const technicianRanks = [
  ['ft_probation', '試用技師'], ['ft_junior', '初級技師'],
  ['ft_senior_junior', '資深初級技師'], ['ft_mid', '中階技師'],
  ['ft_senior_mid', '資深中階技師'], ['ft_advanced', '高階技師'],
];

export function staffClassification(person, title) {
  const role = title?.work_category || person?.work_category || 'technician';
  const category = person?.payroll_category_code || (person?.employment_type_code === 'contractor' ? '04'
    : person?.employment_type_code === 'part_time' ? (person?.pay_basis === 'monthly' ? '02' : '03') : '01');
  return {role, category, rankCode: technicianRanks.some(([code]) => code === title?.code) ? title.code : ''};
}

export function classificationPayload({role, category, rankCode, counterEmployment}, titles) {
  const code = role === 'owner' ? 'owner' : role === 'counter' ? 'reception'
    : ['01', '02'].includes(category) ? rankCode : category === '03' ? 'pt_technician' : 'contract_technician';
  const title = titles.find(row => row.code === code && row.active && !row.archived_at && !row.legacy);
  if (!title || (role === 'technician' && !['01','02','03','04'].includes(category))) return null;
  const employment = role === 'owner' ? 'owner' : role === 'counter' ? counterEmployment
    : category === '01' ? 'full_time' : category === '04' ? 'contractor' : 'part_time';
  if (!(title.allowed_employment_types || []).includes(employment)) return null;
  return {job_title_id:title.id, title:title.name, employment_type_code:employment,
    payroll_category_code:role === 'technician' ? category : null};
}
