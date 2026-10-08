import assert from 'node:assert/strict';
import { resolveStewardPeriod } from '../server/steward-period.mjs';
import { validateInput } from '../server/ask-steward.mjs';

const october = new Date('2026-10-08T01:00:00Z');
let checks = 0;
function check(name, fn) { fn(); checks++; console.log(`✓ ${name}`); }
function expect(question, expected, options = {}, now = october) { assert.deepEqual(resolveStewardPeriod({question,...options}, now).range, expected); }
check('month default ignores client clock and changes month at Taipei midnight', () => {
 expect('分析營運', {from:'2026-10-01',to:'2026-10-08'});
 expect('分析營運', {from:'2026-11-01',to:'2026-11-01'}, {}, new Date('2026-10-31T16:00:00Z'));
});
check('preset periods have inclusive exact boundaries', () => {
 expect('',{from:'2026-09-01',to:'2026-09-30'},{period:'last_month'});
 expect('',{from:'2026-09-09',to:'2026-10-08'},{period:'last_30_days'});
 expect('',{from:'2026-07-11',to:'2026-10-08'},{period:'last_90_days'});
 expect('',{from:'1900-01-01',to:'2026-10-08'},{period:'all'});
});
check('question periods override the selected preset', () => {
 expect('上個月的營運如何？',{from:'2026-09-01',to:'2026-09-30'},{period:'all'});
 expect('最近30天的預約',{from:'2026-09-09',to:'2026-10-08'},{period:'month'});
 expect('全部历史有哪些异常',{from:'1900-01-01',to:'2026-10-08'},{period:'month'});
 expect('昨天的出勤',{from:'2026-10-07',to:'2026-10-07'});
 expect('今年的營收',{from:'2026-01-01',to:'2026-10-08'});
 expect('去年',{from:'2025-01-01',to:'2025-12-31'});
});
check('week starts Monday, including cross-month cases', () => {
 expect('本週',{from:'2026-10-05',to:'2026-10-08'});
 expect('上周',{from:'2026-09-28',to:'2026-10-04'});
});
check('month/year shifts and leap years remain valid', () => {
 expect('上个月',{from:'2025-12-01',to:'2025-12-31'},{},new Date('2026-01-02T02:00:00Z'));
 expect('2024年2月',{from:'2024-02-01',to:'2024-02-29'});
 expect('2026-09 的营收',{from:'2026-09-01',to:'2026-09-30'});
 expect('9月營收',{from:'2026-09-01',to:'2026-09-30'});
});
check('explicit date period may cover several years in business mode', () => {
 expect('2024-01-01 至 2026-09-30',{from:'2024-01-01',to:'2026-09-30'});
 expect('2026/9/8',{from:'2026-09-08',to:'2026-09-08'});
});
check('legacy page range remains limited and preserved', () => {
 const range={from:'2026-10-08',to:'2026-10-14'};
 expect('規則如何設定？',range,{range});
 expect('',range,{period:'page',range,scope:'page'});
 assert.throws(()=>resolveStewardPeriod({period:'page',range:{from:'2020-01-01',to:'2026-10-08'}},october));
 assert.throws(()=>resolveStewardPeriod({period:'all',scope:'page'},october));
});
check('malformed dates, invalid ranges and unknown controls fail safely', () => {
 for(const options of [{question:'2026-02-30'},{question:'2026-13'},{question:'13月'},{question:'最近0天'},{question:'最近9999天'},{question:'2026-10-10到2026-10-01'},{question:'2026-01-01、2026-02-01、2026-03-01'},{period:'unsafe'},{scope:'everything'},{period:'page'},{period:'month',range:{from:'bad',to:'bad'}}]) assert.throws(()=>resolveStewardPeriod(options,october));
});
check('mentioning recurring rule dates does not silently select a historical month', () => {
 expect('每月1至7號提交班表，8號鎖定嗎？',{from:'2026-10-01',to:'2026-10-08'});
});
check('input strips arbitrary client state, query and role controls', () => {
 const input=validateInput({question:'分析全部歷史',page:'dashboard',scope:'business',period:'month',sql:'SELECT secret',role:'owner',staff_id:'other',state:{secret:1}},october);
 assert.equal(input.period,'all'); assert.equal(input.scope,'business');
 assert.equal('sql' in input,false); assert.equal('state' in input,false); assert.equal('staff_id' in input,false);
});
console.log(`\n${checks} steward-period checks passed.`);
