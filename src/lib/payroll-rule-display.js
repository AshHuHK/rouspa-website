const hiddenSettlementVersions=new Set([1,3,5,6,7]);

export function payrollRuleDisplayName(rule){
 return Number(rule?.version_no)===8&&rule.name==='技師薪資制度告知書 03-1'
  ?'2027第一版薪資制度':rule?.name;
}

export function showSettlementVersion(rule){
 return !hiddenSettlementVersions.has(Number(rule?.version_no));
}


export function payrollRuleStatus(rule, today) {
 if (rule?.status === 'draft') return '制度草稿';
 if (rule?.status === 'active') return rule.effective_from > today ? '正式・待生效' : '正式・生效中';
 return '歷史版本';
}
