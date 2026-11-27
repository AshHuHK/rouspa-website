// Run through tabbit-cli nodejs against the local Vite server on port 5184.
// The fixture intercepts all APIs and cannot submit production data.
const fixtureUrl='http://127.0.0.1:5184/scripts/fixtures/ui-recovery.html';
let checks=0;
for(const width of [390,768,1440]){
  await page.setViewportSize({width,height:844});
  await page.goto(`${fixtureUrl}?width=${width}`,{waitUntil:'domcontentloaded'});
  const serviceButtons=page.locator('.booking-service-grid button');
  await expect(serviceButtons).toHaveCount(3);checks++;
  const serviceTops=await serviceButtons.evaluateAll(buttons=>buttons.map(button=>button.getBoundingClientRect().top));
  expect(new Set(serviceTops).size).toBe(1);checks++;
  await page.getByRole('button',{name:'測試療程',exact:false}).click();
  await page.getByRole('button',{name:'下一步',exact:true}).click();
  await expect(page.locator('.booking-method-grid button')).toHaveCount(2);checks++;
  await page.getByRole('button',{name:'挑時間',exact:false}).click();
  await page.getByRole('button',{name:'下一步',exact:true}).click();
  const before=await page.evaluate(()=>scrollY);
  await page.locator('.booking-two-months').waitFor();
  expect(Math.abs(await page.evaluate(()=>scrollY)-before)).toBeLessThan(2);checks++;
  expect(await page.locator('.booking-experience h3').evaluate(e=>e.getBoundingClientRect().top)).toBeGreaterThanOrEqual(73);checks++;
  await page.evaluate(()=>window.scrollTo(0,scrollY+200));
  const refreshBefore=await page.evaluate(()=>scrollY);
  await page.evaluate(()=>window.uiFixture.refreshBooking());
  await page.waitForFunction(()=>window.uiFixture.calendarReads>=4&&document.querySelector('.booking-two-months')?.getAttribute('aria-busy')==='false');
  expect(Math.abs(await page.evaluate(()=>scrollY)-refreshBefore)).toBeLessThan(2);checks++;
  await expect(page.locator('[aria-current="step"]')).toHaveText('3日期時段');checks++;
}
await page.evaluate(()=>{window.uiFixture.noSlots=true;});
await page.locator('.booking-calendar-grid button').nth(20).click();
await expect(page.getByRole('status').filter({hasText:'這一天目前已無可預約時段'})).toBeVisible();checks++;
await page.goto(`${fixtureUrl}?states=1`,{waitUntil:'domcontentloaded'});
await page.waitForFunction(()=>!!window.uiFixture.setCatalog);
await page.evaluate(()=>window.uiFixture.setCatalog('loading'));
await expect(page.getByRole('status')).toHaveText('正在載入預約服務…');checks++;
await page.evaluate(()=>window.uiFixture.setCatalog('empty'));
await expect(page.getByRole('status')).toContainText('目前沒有開放線上預約的療程');checks++;
await page.evaluate(()=>window.uiFixture.setCatalog('no-staff'));
await page.getByRole('button',{name:'測試療程',exact:false}).click();
await page.getByRole('button',{name:'下一步',exact:true}).click();
await page.getByRole('button',{name:/^◎ 指定技師/}).click();
await expect(page.getByRole('status')).toContainText('目前沒有可提供此療程的指定技師');checks++;
await page.goto(`${fixtureUrl}?mode=shop&fail=1`,{waitUntil:'domcontentloaded'});
await expect(page.getByRole('alert')).toBeVisible();checks++;
await page.evaluate(()=>{window.uiFixture.failShop=false;});
await page.getByRole('button',{name:'重新載入商品'}).click();
const categories=page.getByRole('group',{name:'商品分類'});
await expect(categories.getByRole('button',{name:'全部產品'})).toHaveAttribute('aria-pressed','true');checks++;
await categories.getByRole('button',{name:'茶飲',exact:true}).click();
await expect(categories.getByRole('button',{name:'茶飲',exact:true})).toHaveAttribute('aria-pressed','true');checks++;
await expect(page.locator('.product-card')).toHaveCount(1);checks++;
await expect(page.locator('.product-card')).toContainText('測試茶飲');checks++;
await page.setViewportSize({width:320,height:844});
await page.goto(`${fixtureUrl}?mode=staff&fail=1`,{waitUntil:'domcontentloaded'});
await expect(page.getByRole('alert')).toBeVisible();checks++;
await page.evaluate(()=>{window.uiFixture.failPlan=false;});
await page.getByRole('button',{name:'重新讀取班表'}).click();
const firstDay=page.locator('.schedule-month-grid button').first();
await expect(firstDay).toHaveAttribute('aria-pressed','true');checks++;
await expect(firstDay).toHaveAttribute('aria-label',/^\d{4}-\d{2}-01，上班 10:00至翌日 02:00，0 筆預約$/);checks++;
await expect(firstDay.locator('small span')).toHaveCount(2);checks++;
expect(await firstDay.locator('small').evaluate(e=>parseFloat(getComputedStyle(e).fontSize))).toBeGreaterThanOrEqual(10);checks++;
expect(await firstDay.locator('small').evaluate(e=>e.getBoundingClientRect().width<=e.parentElement.clientWidth-6)).toBe(true);checks++;
expect(await page.evaluate(()=>document.documentElement.scrollWidth)).toBe(320);checks++;
await page.setViewportSize({width:390,height:844});
for(const outcome of ['timeout','malformed','http']){
await page.goto(`${fixtureUrl}?mode=retry&outcome=${outcome}`,{waitUntil:'domcontentloaded'});
await page.getByRole('button',{name:'測試療程',exact:false}).click();
await page.getByRole('button',{name:'下一步',exact:true}).click();
await page.getByRole('button',{name:/^◎ 指定技師/}).click();
await page.locator('.booking-staff-grid button').click();
await page.getByRole('button',{name:'下一步',exact:true}).click();
await page.locator('.booking-two-months article').nth(1).locator('.booking-calendar-grid button').first().click();
await page.getByRole('button',{name:'10:00',exact:true}).click();
await page.getByRole('button',{name:'下一步',exact:true}).click();
await page.getByRole('textbox',{name:'您的姓名',exact:true}).fill('測試顧客');
await page.getByRole('textbox',{name:'您的手機號碼',exact:true}).fill('0999999999');
await page.getByRole('button',{name:'確認預約',exact:true}).click();
await expect(page.getByRole('heading',{name:'核對剛才預約結果'})).toBeVisible();checks++;
await expect(page.getByRole('link',{name:'查詢預約',exact:true})).toHaveAttribute('href','#lookup');checks++;
const frozen=await page.evaluate(()=>({slotReads:window.uiFixture.slotReads,calendarReads:window.uiFixture.calendarReads}));
await page.evaluate(()=>window.uiFixture.refreshBooking());
await expect(page.getByRole('button',{name:'再次確認剛才預約',exact:true})).toBeEnabled();checks++;
expect(await page.evaluate(()=>({slotReads:window.uiFixture.slotReads,calendarReads:window.uiFixture.calendarReads}))).toEqual(frozen);checks++;
await page.getByRole('button',{name:'再次確認剛才預約',exact:true}).click();
await expect(page.getByText('LOCAL-ONE-BOOKING')).toBeVisible();checks++;
const retry=await page.evaluate(()=>({bookings:window.uiFixture.bookings,requests:window.uiFixture.createRequests}));
expect(retry.bookings).toBe(1);checks++;
expect(retry.requests).toHaveLength(2);checks++;
expect(retry.requests[1]).toEqual(retry.requests[0]);checks++;
}
await page.goto(`${fixtureUrl}?mode=admin&fail=1`,{waitUntil:'domcontentloaded'});
await expect(page.getByRole('heading',{name:'請重新登入',exact:true})).toBeVisible();checks++;
await expect(page.getByRole('alert')).toContainText('登入狀態已失效');checks++;
expect(await page.evaluate(()=>window.uiFixture.signedOut)).toBe(0);checks++;
await page.evaluate(()=>{window.uiFixture.failSession=false;});
await page.getByRole('button',{name:'重新載入權限'}).click();
await expect(page.getByRole('heading',{name:'尚未開通管理權限'})).toBeVisible();checks++;
expect(await page.evaluate(()=>window.uiFixture.signedOut)).toBe(0);checks++;
await page.goto(`${fixtureUrl}?mode=admin&fail=1`,{waitUntil:'domcontentloaded'});
await page.getByRole('button',{name:'重新登入',exact:true}).click();
await expect(page.getByLabel('使用者名稱或電子郵件')).toBeVisible();checks++;
expect(await page.evaluate(()=>window.uiFixture.signedOut)).toBe(1);checks++;
await page.goto(`${fixtureUrl}?mode=admin&fail=1&outcome=session-read`,{waitUntil:'domcontentloaded'});
await expect(page.getByRole('heading',{name:'暫時無法確認登入'})).toBeVisible();checks++;
expect(await page.evaluate(()=>window.uiFixture.signedOut)).toBe(0);checks++;
await page.evaluate(()=>{window.uiFixture.failSession=false;});
await page.getByRole('button',{name:'重新確認帳號'}).click();
await expect(page.getByRole('heading',{name:'尚未開通管理權限'})).toBeVisible();checks++;
await page.goto(`${fixtureUrl}?mode=boundary`,{waitUntil:'domcontentloaded'});
await expect(page.getByRole('heading',{name:'頁面暫時無法顯示'})).toBeVisible();checks++;
await expect(page.getByRole('button',{name:'重新載入頁面'})).toBeEnabled();checks++;

const ownerUrl=fixtureUrl+'?mode=admin&role=owner';
const tileGeometry=locator=>locator.evaluateAll(tiles=>tiles.map(tile=>{
 const {width,height,y}=tile.getBoundingClientRect();
 return {width,height,y};
}));
await page.goto(ownerUrl,{waitUntil:'domcontentloaded'});
const dashboardTiles=page.locator('[aria-label="今日營運指標"] .ops-metric-tile');
await expect(dashboardTiles).toHaveCount(7);
for(const [width,columns] of [[1440,7],[768,7],[390,3],[320,3]]){
 await page.setViewportSize({width,height:844});
 const geometry=await tileGeometry(dashboardTiles);
 expect(geometry.filter(tile=>tile.y===geometry[0].y)).toHaveLength(columns);checks++;
 expect(geometry.every(tile=>Math.abs(tile.width-tile.height)<2)).toBe(true);checks++;
}
await expect(page.getByRole('heading',{name:'時段接客容量',exact:true})).toHaveCount(0);checks++;
await expect(page.locator('.os-hours-heading')).toHaveText('TODAY · LIVE今日營業');checks++;
await expect(page.locator('.os-hours-actions')).toContainText('10:00–翌日 02:00');checks++;
await expect(page.locator('.os-hours-actions').getByRole('button',{name:'設定今日營業／休假'})).toBeVisible();checks++;
await expect(page.getByText('目前使用每週營業時間。')).toHaveCount(0);checks++;
const ownerNav=page.getByRole('navigation',{name:'後台主要功能'});
await page.clock.install();
await ownerNav.getByRole('button',{name:'預約與日程',exact:true}).click();
const bookingTiles=page.locator('[aria-label="所選日期預約指標"] .ops-metric-tile');
await expect(bookingTiles).toHaveCount(4);
const phoneTiles=await tileGeometry(bookingTiles);
expect(phoneTiles.filter(tile=>tile.y===phoneTiles[0].y)).toHaveLength(2);checks++;
await expect(page.getByText('灰色預約', {exact:false})).toHaveCount(0);checks++;
await expect(page.getByText('目前顯示', {exact:false})).toHaveCount(0);checks++;
const processed=()=>page.evaluate(()=>window.uiFixture.adminReads.spa_admin_bookings);
const countBefore=await processed();
await page.clock.fastForward(9*60*1000);
expect(await processed()).toBe(countBefore);checks++;
await page.clock.fastForward(61*1000);
await expect.poll(processed).toBe(countBefore+1);checks++;
await page.getByRole('button',{name:'重新整理',exact:true}).click();
await expect.poll(processed).toBe(countBefore+2);checks++;
await ownerNav.getByRole('button',{name:'會員與儲值金',exact:true}).click();
const search=page.getByRole('searchbox',{name:'搜尋顧客'});
await expect(search).toBeVisible();
await expect(page.getByRole('columnheader',{name:'顧客',exact:true})).toHaveCount(0);checks++;
await search.fill('甲');
await expect(page.getByText('測試會員 甲',{exact:true})).toHaveCount(0);checks++;
await search.press('Enter');
await expect(page.getByText('測試會員 甲',{exact:true})).toBeVisible();checks++;
await expect(page.getByText('測試顧客 乙',{exact:true})).toHaveCount(0);checks++;
await search.fill('+886 922-333-444');
await page.getByRole('button',{name:'查詢',exact:true}).click();
await expect(page.getByText('測試顧客 乙',{exact:true})).toBeVisible();checks++;
await search.clear();
await expect(page.getByRole('columnheader',{name:'顧客',exact:true})).toHaveCount(0);checks++;
const readCustomers=()=>page.evaluate(()=>window.uiFixture.adminReads.spa_customers_list);
const customersBefore=await readCustomers();
await page.clock.fastForward(10*60*1000+1000);
await expect.poll(readCustomers).toBe(customersBefore+1);checks++;
await expect(page.getByRole('columnheader',{name:'顧客',exact:true})).toHaveCount(0);checks++;
await ownerNav.getByRole('button',{name:'人員與排班',exact:true}).click();
const teamCard=page.locator('.os-team-grid article').first();
await expect(teamCard).toContainText('0912000800');checks++;
await expect(teamCard.getByText(/未填電子郵件|年資|薪資規則|年度考核/)).toHaveCount(0);checks++;
await expect(teamCard.getByRole('button',{name:'排班日曆'})).toBeEnabled();checks++;
await ownerNav.getByRole('button',{name:'薪資與提成',exact:true}).click();
await expect(page.getByLabel('試算版本').locator('option')).toHaveText(['目前生效制度','v8 · 2027第一版薪資制度（草稿）']);checks++;
await page.getByRole('button',{name:'結算紀錄',exact:true}).click();
await page.getByRole('button',{name:'核對原週期',exact:true}).click();
await expect(page.getByLabel('試算版本')).toHaveValue('rule-5');checks++;

for(const role of ['therapist','manager','restricted']){
 await page.goto(fixtureUrl+`?mode=admin&role=${role}`,{waitUntil:'domcontentloaded'});
 const workspace=page.locator('.staff-workspace');
 await expect(workspace.getByRole('button',{name:'上班打卡'})).toBeEnabled();checks++;
 await expect(workspace.getByRole('button',{name:'下班打卡'})).toBeDisabled();checks++;
 await expect(page.getByRole('navigation',{name:'後台主要功能'})).toHaveCount(0);checks++;
 await expect(workspace.getByRole('heading',{name:'我的薪資與績效',exact:true})).toBeVisible();checks++;
 await expect(workspace.getByText('年度考核',{exact:false})).toHaveCount(0);checks++;
 const sections=await workspace.locator(':scope > section, :scope > #my-attendance').evaluateAll(items=>items.map(item=>item.id||item.getAttribute('aria-label')));
 expect(sections.slice(0,2)).toEqual(['my-attendance','個人班表']);checks++;
 if(role==='restricted'){
  await expect(workspace.locator('#staff-bookings, #staff-reviews, #staff-dashboard')).toHaveCount(0);checks++;
  expect(await page.evaluate(()=>Object.keys(window.uiFixture.adminReads))).not.toContain('spa_admin_bookings');checks++;
 }else{
  expect(sections.indexOf('staff-bookings')).toBeLessThan(sections.indexOf('staff-self'));checks++;
  await expect(workspace.locator('#staff-bookings')).toBeVisible();checks++;
  if(role==='therapist'){
   const bookings=workspace.locator('#staff-bookings');
   await expect(bookings.getByLabel('技師篩選')).toHaveCount(0);checks++;
   await bookings.getByRole('button',{name:'查看排程',exact:true}).click();
   await expect(bookings.locator('tbody tr')).toHaveCount(1);checks++;
   await expect(bookings.locator('tbody')).not.toContainText('其他技師');checks++;
  }
 }
}
await page.goto(fixtureUrl+'?mode=admin&role=therapist&working=1',{waitUntil:'domcontentloaded'});
const attendance=page.locator('#my-attendance');
await expect(attendance.getByRole('button',{name:'下班打卡'})).toBeEnabled();checks++;
await expect(attendance.getByRole('button',{name:'上班打卡'})).toBeDisabled();checks++;
await expect(attendance.getByText('異常原因／備註',{exact:false})).toHaveCount(0);checks++;
for (const [start,end] of [['2026-10-06T22:00','2026-10-06T23:00'],['2026-10-07T00:20','2026-10-07T01:20']]){
 await attendance.getByLabel('開始休息（台灣時間）').fill(start);
 await attendance.getByLabel('結束休息（台灣時間）').fill(end);
 await attendance.getByRole('button',{name:'確認送出'}).click();
 if(start.includes('22:00'))await attendance.getByRole('button',{name:'＋ 新增第二段休息'}).click();
}
await expect(attendance.getByText('合計休息 120 分鐘')).toBeVisible();checks++;
await expect(attendance.locator('.attendance-break-section input')).toHaveCount(0);checks++;
await attendance.getByLabel('補打卡原因').fill('昨晚忘記打下班卡');
await attendance.getByRole('button',{name:'送出',exact:true}).click();
await expect(attendance.getByRole('status').filter({hasText:'已送交店主審核'})).toBeVisible();checks++;
for(const [width,countFour,countFive] of [[1440,4,4],[390,2,2]]){
 await page.setViewportSize({width,height:844});
 for(const [name,items,columns] of [['今日營運指標',4,countFour],['選定日期營運指標',4,countFour],['個人服務指標',4,countFive]]){
  const match=page.locator('[aria-label="'+name+'"] .ops-metric-tile');
  await expect(match).toHaveCount(items);checks++;
  const geometry=await tileGeometry(match);
  expect(geometry.filter(tile=>tile.y===geometry[0].y)).toHaveLength(columns);checks++;
  expect(geometry.every(tile=>Math.abs(tile.width-tile.height)<2)).toBe(true);checks++;
 }
}
await expect(page.getByRole('heading',{name:'我的評價',exact:true})).toHaveCount(0);checks++;
expect(await page.evaluate(()=>Object.keys(window.uiFixture.adminReads))).not.toContain('spa_reviews_admin');checks++;
await page.goto(ownerUrl,{waitUntil:'domcontentloaded'});
await page.getByRole('navigation',{name:'後台主要功能'}).getByRole('button',{name:'人員與排班',exact:true}).click();
await page.getByRole('button',{name:'職務與排班提醒',exact:true}).click();
const reminderDialog=page.getByRole('dialog',{name:'職務與排班提醒'});
const fullTimeReminder=reminderDialog.getByLabel('正職人員排班提醒文字');
await fullTimeReminder.fill('排班提醒可以自行修改。');
await fullTimeReminder.locator('..').locator('..').getByRole('button',{name:'儲存提醒',exact:true}).click();
await expect.poll(()=>page.evaluate(()=>window.uiFixture.reminders[0].reminder_text)).toBe('排班提醒可以自行修改。');checks++;
await reminderDialog.getByRole('button',{name:'關閉',exact:true}).click();
const review=page.locator('#attendance-review');
await expect(review.getByLabel('半月審核批次')).toBeVisible();checks++;
await review.getByLabel('選取本批次待審核紀錄').check();
await review.getByRole('button',{name:'核准所選 2 筆'}).click();
await page.getByRole('dialog').getByLabel('批次審核說明').fill('核對半月工時與休息');
await page.getByRole('dialog').getByRole('button',{name:'確認核准 2 筆'}).click();
await expect(page.getByRole('dialog')).toHaveCount(0);checks++;
expect((await page.evaluate(()=>window.uiFixture.batchRequest)).p_rows).toHaveLength(2);checks++;
for(const width of [320,375,390,430,1440]){
 await page.setViewportSize({width,height:844});
 await page.goto(fixtureUrl+'?mode=home',{waitUntil:'domcontentloaded'});
 const cards=page.locator('.onsite-service-list .formula-card');
 await expect(cards).toHaveCount(3);checks++;
 await expect(cards.locator('.formula-price')).toHaveText(['NT$1,200','NT$1,200','NT$520']);checks++;
 await expect(cards.locator('.onsite-duration')).toHaveText(['60分','60分','40分']);checks++;
 const prices=await cards.locator('.formula-price').evaluateAll(items=>items.map(el=>{
  const r=el.getBoundingClientRect(),card=el.closest('.formula-card').getBoundingClientRect();
  return {fits:r.left>=card.left&&r.right<=card.right&&el.scrollWidth<=el.clientWidth,visible:r.width>40&&r.right<=innerWidth};
 }));
 expect(prices.every(row=>row.fits&&row.visible)).toBe(true);checks++;
 const map=page.locator('iframe[title="柔療髮浴嘉義門店位置"]');
 await map.evaluate(frame=>{frame.loading='eager';});
 await expect(page.frameLocator('iframe[title="柔療髮浴嘉義門店位置"]').getByTestId('isolated-map')).toHaveText('Local map placeholder');checks++;
}
await page.goto(fixtureUrl+'?mode=staff',{waitUntil:'domcontentloaded'});
await page.waitForFunction(()=>typeof window.uiFixture?.reloadPlan==='function');
for(const [role,name] of [['full_time','正職人員'],['contractor','承攬人員'],['part_time_hourly','兼職時薪人員'],['part_time_monthly','兼職月薪人員']]){
 await page.evaluate(role=>{window.uiFixture.scheduleRole=role;window.uiFixture.reloadPlan();},role);
 const banner=page.getByRole('complementary',{name:'職務排班提醒'});
 await expect(banner.getByRole('heading')).toHaveText(name+'排班提醒');checks++;
 if(role==='contractor')await expect(banner.getByText('以上受僱人員的排班規範均不影響依法享有的請假權益。')).toHaveCount(0);
 else await expect(banner.getByText('以上受僱人員的排班規範均不影響依法享有的請假權益。')).toBeVisible();
 checks++;
}
await page.getByLabel('開始',{exact:true}).fill('10:17');
await page.getByLabel('結束',{exact:true}).fill('11:02');
await expect(page.getByLabel('開始',{exact:true})).toHaveValue('10:17');checks++;
await page.evaluate(()=>{window.uiFixture.reminders.find(row=>row.role_code===window.uiFixture.scheduleRole).reminder_text='';window.uiFixture.reloadPlan();});
await expect(page.getByRole('complementary',{name:'職務排班提醒'})).toHaveCount(0);checks++;
await expect(page.getByText('每日最多',{exact:false})).toHaveCount(0);checks++;
for(const width of [320,1440]){
 await page.setViewportSize({width,height:1000});
 await page.goto(fixtureUrl+'?mode=hr',{waitUntil:'domcontentloaded'});
 await expect(page.getByLabel('職務',{exact:true}).locator('option')).toHaveText(['店主','櫃檯','技師']);checks++;
 await expect(page.getByLabel('技師職級',{exact:true}).locator('option')).toHaveText(['請選擇職級','試用技師','初級技師','資深初級技師','中階技師','資深中階技師','高階技師']);checks++;
 await page.getByLabel('技師類型',{exact:true}).selectOption('part_time');
 await expect(page.getByLabel('兼職聘僱類型')).toHaveValue('03');checks++;
 await expect(page.getByLabel('技師職級',{exact:true})).toHaveCount(0);checks++;
 await page.getByLabel('兼職聘僱類型').selectOption('02');
 await page.getByLabel('技師職級',{exact:true}).selectOption('ft_mid');
 await page.getByLabel('姓名',{exact:true}).fill('測試月薪');
 await page.getByRole('button',{name:'儲存',exact:true}).click();
 await expect.poll(()=>page.evaluate(()=>window.uiFixture.hrPayload?.payroll_category_code)).toBe('02');checks++;
 expect((await page.evaluate(()=>window.uiFixture.hrPayload)).employment_type_code).toBe('part_time');checks++;
 expect((await page.evaluate(()=>window.uiFixture.hrPayload)).job_title_id).toBe('ft_mid');checks++;
 await page.getByLabel('技師類型',{exact:true}).selectOption('contractor');
 await expect(page.getByLabel('技師職級',{exact:true})).toHaveCount(0);checks++;
 await expect(page.getByLabel('承攬合作開始日期')).toBeVisible();checks++;
 await page.getByLabel('職務',{exact:true}).selectOption('counter');
 await expect(page.getByLabel('技師類型',{exact:true})).toHaveCount(0);checks++;
 await expect(page.getByLabel('聘僱類型',{exact:true}).locator('option')).toHaveText(['正職','兼職']);checks++;
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);checks++;
}
for(const width of [320,1440]){
 await page.setViewportSize({width,height:1000});
 await page.goto(fixtureUrl+'?mode=monthly-pay',{waitUntil:'domcontentloaded'});
 await expect(page.getByRole('spinbutton',{name:/02 兼職統一月薪/})).toHaveCount(0);checks++;
 await expect(page.getByRole('columnheader')).toHaveText(['職級','01 起抽','02 起抽']);checks++;
 await expect(page.getByText('個人起抽（選填）')).toHaveCount(0);checks++;
 const threshold=page.getByRole('spinbutton',{name:'01 正職服務門檻（小時）'});
 await expect(threshold).toBeEnabled();checks++;
 await threshold.fill('72');
 await page.getByRole('button',{name:'儲存制度',exact:true}).click();
 await expect.poll(()=>page.evaluate(()=>window.uiFixture.noticeSave?.p_settings.full_time_threshold_minutes)).toBe(4320);checks++;
 expect((await page.evaluate(()=>window.uiFixture.noticeSave.p_ranks)).every(rank=>rank.monthly_base_cents===2520000)).toBe(true);checks++;
 expect(await page.evaluate(()=>document.documentElement.scrollWidth<=innerWidth)).toBe(true);checks++;
}
return {checks,productionRequests:0};
