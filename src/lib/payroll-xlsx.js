export async function exportPayrollXlsx({rows,from,to,rule,rates=[],tiers=[]}){
 const module=await import('exceljs');
 const ExcelJS=module.default||module;
 const workbook=new ExcelJS.Workbook();
 workbook.creator='ROU SPA';workbook.created=new Date();workbook.modified=new Date();workbook.properties={date1904:false};
 const sheet=workbook.addWorksheet('薪資明細',{views:[{state:'frozen',ySplit:2}]});
 const headers=['員工','任職狀態','離職日','職稱','聘僱類型','薪酬基準','出勤分鐘','完成堂數','已結帳堂數','待結帳堂數','退款堂數','服務分鐘','服務業績','商品訂單','商品業績','本薪','療程提成','商品提成','指定客服務業績','指定客加成','加班分鐘','加班費','其他獎金','津貼','扣款','應發合計','警示'];
 sheet.mergeCells(1,1,1,headers.length);sheet.getCell('A1').value=`柔療髮浴 薪資明細 ${from} ～ ${to}`;
 sheet.getCell('A1').font={bold:true,size:16,color:{argb:'FF6B4F2A'}};sheet.getCell('A1').alignment={horizontal:'center'};
 sheet.addRow(headers);sheet.getRow(2).font={bold:true,color:{argb:'FFFFFFFF'}};sheet.getRow(2).fill={type:'pattern',pattern:'solid',fgColor:{argb:'FF8A7045'}};
 for(const row of rows)sheet.addRow([row.employee,{active:'在職',departed:'已離職',inactive:'停用／未任職'}[row.employment_status]||row.employment_status,row.departed_on||'',row.role,row.employment_type,row.pay_basis,row.work_minutes,row.completed_count,row.service_count,row.unsettled_completed_count,row.refunded_service_count,row.service_minutes,Number(row.service_sales_cents)/100,row.product_order_count,Number(row.product_sales_cents)/100,Number(row.base_cents)/100,Number(row.service_commission_cents)/100,Number(row.product_commission_cents)/100,Number(row.designated_service_sales_cents||0)/100,Number(row.designated_bonus_cents)/100,row.overtime_minutes,Number(row.overtime_cents)/100,Number(row.bonus_cents)/100,Number(row.allowance_cents)/100,Number(row.deduction_cents)/100,Number(row.total_cents)/100,[row.commission_warning,row.overtime_warning].filter(Boolean).join('；')]);
 const sum=key=>rows.reduce((n,r)=>n+Number(r[key]||0),0);
 const totalRow=sheet.addRow(['合計','','','','','',sum('work_minutes'),sum('completed_count'),sum('service_count'),sum('unsettled_completed_count'),sum('refunded_service_count'),sum('service_minutes'),sum('service_sales_cents')/100,sum('product_order_count'),sum('product_sales_cents')/100,sum('base_cents')/100,sum('service_commission_cents')/100,sum('product_commission_cents')/100,sum('designated_service_sales_cents')/100,sum('designated_bonus_cents')/100,sum('overtime_minutes'),sum('overtime_cents')/100,sum('bonus_cents')/100,sum('allowance_cents')/100,sum('deduction_cents')/100,sum('total_cents')/100,'']);
 totalRow.font={bold:true};totalRow.fill={type:'pattern',pattern:'solid',fgColor:{argb:'FFF2E8D5'}};
 [13,15,16,17,18,19,20,22,23,24,25,26].forEach(index=>{sheet.getColumn(index).numFmt='NT$#,##0.00;[Red]-NT$#,##0.00';});
 sheet.columns.forEach((column,index)=>{column.width=index===0?16:index===26?24:14;});sheet.autoFilter={from:'A2',to:`AA2`};
 sheet.eachRow((row,rowNumber)=>{row.alignment={vertical:'middle',wrapText:true};if(rowNumber>1)row.height=22;row.eachCell(cell=>{cell.border={bottom:{style:'hair',color:{argb:'FFD8CAB1'}}};});});
 const rules=workbook.addWorksheet('規則與倍率');
 rules.addRow(['規則版本',rule?`v${rule.version_no} · ${rule.name}`:'']);rules.addRow(['生效日',rule?.effective_from||'']);rules.addRow(['療程計算','實際服務技師＋已完成＋已結帳＋未退款']);rules.addRow(['月薪換算時薪除數',rule?.hourly_divisor||'']);rules.addRow(['包含固定提成',rule?.include_regular_commission?'是':'否']);rules.addRow(['一般月加班上限（分鐘）',rule?.monthly_overtime_limit_minutes||'']);rules.addRow(['勞資會議月上限（分鐘）',rule?.agreed_monthly_limit_minutes||'']);rules.addRow(['季度上限（分鐘）',rule?.quarterly_overtime_limit_minutes||'']);rules.addRow([]);rules.addRow(['聘僱類型','加班類型','起始分鐘','結束分鐘','倍率']);
 for(const rate of rates.filter(item=>!rule||item.rule_version_id===rule.id))rules.addRow([rate.employment_type_code,rate.overtime_type,rate.start_minute,rate.end_minute,Number(rate.multiplier_bps)/10000]);
 rules.addRow([]);rules.addRow(['職稱','聘僱類型','指標','算法','起點（系統單位）','終點（系統單位）','提成比例']);
 for(const tier of tiers.filter(item=>!rule||item.rule_version_id===rule.id))rules.addRow([tier.job_title_name||tier.job_title_id,tier.employment_type_name||tier.employment_type_code,tier.metric,tier.calculation_mode,tier.threshold_from,tier.threshold_to,Number(tier.rate_bps)/10000]);
 rules.getRow(10).font={bold:true};rules.getColumn(5).numFmt='0.00x';rules.getColumn(7).numFmt='0.00%';rules.columns.forEach(column=>column.width=24);
 const buffer=await workbook.xlsx.writeBuffer();const url=URL.createObjectURL(new Blob([buffer],{type:'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'}));
 const link=document.createElement('a');link.href=url;link.download=`柔療髮浴_薪資_${from}_${to}.xlsx`;link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
}
