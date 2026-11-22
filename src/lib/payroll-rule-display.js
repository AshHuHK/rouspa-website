const hiddenSettlementVersions=new Set([1,3,5,6,7]);

export function payrollRuleDisplayName(rule){
 return Number(rule?.version_no)===8&&rule.name==='技師薪資制度告知書 03-1'
  ?'2027第一版薪資制度':rule?.name;
}

export function showSettlementVersion(rule){
 return !hiddenSettlementVersions.has(Number(rule?.version_no));
}
