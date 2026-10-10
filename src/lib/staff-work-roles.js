const legacyTechnicianCodes = new Set(['therapist', 'senior_therapist', 'head_therapist', 'part_time']);

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
