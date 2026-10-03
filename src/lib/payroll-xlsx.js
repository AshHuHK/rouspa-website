export async function exportPayrollXlsx({rows,from,to,rule,rates=[]}){
 const module=await import('exceljs');
 const ExcelJS=module.default||module;
 const workbook=new ExcelJS.Workbook();
 workbook.creator='ROU SPA';workbook.created=new Date();workbook.modified=new Date();
 workbook.properties={date1904:false};
 const sheet=workbook.addWorksheet('薪資明細',{views:[{state:'frozen',ySplit:2}]});
 sheet.mergeCells('A1:R1');sheet.getCell('A1').value=`柔療髮浴 薪資明細 ${from} ～ ${to}`;
 sheet.getCell('A1').font={bold:true,size:16,color:{argb:'FF6B4F2A'}};sheet.getCell('A1').alignment={horizontal:'center'};
 const headers=['員工','職稱','聘僱類型','服務堂數','服務分鐘','服務業績','商品業績','本薪','療程提成','商品提成','指定獎金','加班分鐘','加班費','其他獎金','津貼','扣款','應發合計','警示'];
 sheet.addRow(headers);
 sheet.getRow(2).font={bold:true,color:{argb:'FFFFFFFF'}};sheet.getRow(2).fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF8A7045'}};
 for(const row of rows)sheet.addRow([row.employee,row.role,row.employment_type,row.service_count,row.service_minutes,Number(row.service_sales_cents)/100,Number(row.product_sales_cents)/100,Number(row.base_cents)/100,Number(row.service_commission_cents)/100,Number(row.product_commission_cents)/100,Number(row.designated_bonus_cents)/100,row.overtime_minutes,Number(row.overtime_cents)/100,Number(row.bonus_cents)/100,Number(row.allowance_cents)/100,Number(row.deduction_cents)/100,Number(row.total_cents)/100,row.overtime_warning||'']);
 const totalRow=sheet.addRow(['合計','','',rows.reduce((n,r)=>n+Number(r.service_count),0),rows.reduce((n,r)=>n+Number(r.service_minutes),0),...['service_sales_cents','product_sales_cents','base_cents','service_commission_cents','product_commission_cents','designated_bonus_cents'].map(key=>rows.reduce((n,r)=>n+Number(r[key]),0)/100),rows.reduce((n,r)=>n+Number(r.overtime_minutes),0),...['overtime_cents','bonus_cents','allowance_cents','deduction_cents','total_cents'].map(key=>rows.reduce((n,r)=>n+Number(r[key]),0)/100),'']);
 totalRow.font={bold:true};totalRow.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFF2E8D5'}};
 [6,7,8,9,10,11,13,14,15,16,17].forEach(index=>{sheet.getColumn(index).numFmt='NT$#,##0.00;[Red]-NT$#,##0.00';});
 sheet.columns.forEach((column,index)=>{column.width=index===0?16:index===17?24:14;});
 sheet.autoFilter={from:'A2',to:'R2'};
 sheet.eachRow((row,rowNumber)=>{row.alignment={vertical:'middle',wrapText:true};if(rowNumber>1)row.height=22;row.eachCell(cell=>{cell.border={bottom:{style:'hair',color:{argb:'FFD8CAB1'}}};});});
 const rules=workbook.addWorksheet('規則與倍率');
 rules.addRow(['規則版本',rule?`v${rule.version_no} · ${rule.name}`:'']);rules.addRow(['生效日',rule?.effective_from||'']);rules.addRow(['月薪換算時薪除數',rule?.hourly_divisor||'']);rules.addRow(['包含固定提成',rule?.include_regular_commission?'是':'否']);rules.addRow(['一般月加班上限（分鐘）',rule?.monthly_overtime_limit_minutes||'']);rules.addRow(['勞資會議月上限（分鐘）',rule?.agreed_monthly_limit_minutes||'']);rules.addRow(['季度上限（分鐘）',rule?.quarterly_overtime_limit_minutes||'']);rules.addRow([]);rules.addRow(['聘僱類型','加班類型','起始分鐘','結束分鐘','倍率']);
 for(const rate of rates.filter(item=>!rule||item.rule_version_id===rule.id))rules.addRow([rate.employment_type_code,rate.overtime_type,rate.start_minute,rate.end_minute,Number(rate.multiplier_bps)/10000]);
 rules.getRow(9).font={bold:true};rules.getColumn(5).numFmt='0.00x';rules.columns.forEach(column=>column.width=24);
 const buffer=await workbook.xlsx.writeBuffer();
 const url=URL.createObjectURL(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}));
 const link=document.createElement('a');link.href=url;link.download=`柔療髮浴_薪資_${from}_${to}.xlsx`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
