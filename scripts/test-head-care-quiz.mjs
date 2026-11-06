import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';
import { QUIZ_CONTENT, QUIZ_SCORES, rankQuizAnswers, quizReasonsFor, quizBookableServices, resolveQuizBookingIntent } from '../src/lib/head-care-quiz.js';

const reference = await readFile(new URL('../docs/references/head-care-quiz.html', import.meta.url), 'utf8');
const context = vm.createContext({ window: {} });
for (const id of ['rou-quiz-content', 'rou-quiz-scores', 'rou-quiz-art']) {
  vm.runInContext(reference.match(new RegExp(`<script id="${id}">([\\s\\S]*?)</script>`))[1], context, { timeout: 1000 });
}
const plain = value => JSON.parse(JSON.stringify(value));
const expected = plain(context.window.ROU_QUIZ_CONTENT);
assert.deepEqual(QUIZ_SCORES, plain(context.window.ROU_QUIZ_SCORES), 'every weight and tie order matches the supplied quiz');
assert.deepEqual(QUIZ_CONTENT, { ...expected, settings: { showScoreDetail: false } }, 'all questions, answers and recommendation copy match verbatim; production hides preview score detail');
for (const [key, svg] of Object.entries(context.window.ROU_QUIZ_ART)) {
  assert.equal((await readFile(new URL(`../public/quiz/${key}.svg`, import.meta.url), 'utf8')).trim(), svg, 'retain the supplied illustrations');
}
const engine = reference.slice(reference.indexOf('(function () {'), reference.indexOf('  /* ---------- 畫面')) + '})();';
vm.runInContext(engine, context, { timeout: 1000 });
let combinations = 0, ties = 0;
for (const q1 of ['A','B','C']) for (const q2 of ['A','B','C']) for (const q3 of ['A','B','C','D']) for (const q4 of ['A','B','C','D']) {
  const answers = {q1,q2,q3,q4}, actual = rankQuizAnswers(answers), source = plain(context.window.RouQuiz.rank(answers));
  for (const field of ['totals','max','primary','also','isTie','decidedBy']) assert.deepEqual(actual[field], source[field], `reference parity ${field} ${JSON.stringify(answers)}`);
  for (const key of QUIZ_SCORES.courseOrder) for (const count of [1,3]) assert.deepEqual(quizReasonsFor(key, answers, count), plain(context.window.RouQuiz.reasonsFor(key, answers, count)));
  combinations++; if(actual.isTie)ties++;
}
assert.equal(rankQuizAnswers({q1:'A'}), null, 'incomplete quiz cannot create a recommendation');
assert.equal(rankQuizAnswers({q1:'Z',q2:'A',q3:'A',q4:'A'}), null, 'unknown answer cannot silently change scoring');
assert(ties > 0, 'exercise tied results and secondary recommendations');
const shared = {id:'live90',name:'90分方子',duration_minutes:90,price_cents:236000,active:true,status:'active',online_booking_enabled:true,website_visible:true,category_code:'duration_90',website_content:{zh:[{name:'森呼吸'},{name:'薑暖陽'},{name:'墨玉烏'}]}};
assert.deepEqual(quizBookableServices('sen',{services:[shared]}),[shared], 'a shared live 90-minute package resolves by its ritual card');
for (const patch of [{active:false},{status:'draft'},{status:'archived'},{archived_at:'2026-01-01'},{online_booking_enabled:false},{website_visible:false},{duration_minutes:120},{category_code:'add_on'},{website_content:{zh:[{name:'其他課程'}]}}]) assert.equal(quizBookableServices('sen',{services:[{...shared,...patch}]}).length,0,`never book unavailable or unrelated source ${JSON.stringify(patch)}`);
assert.equal(quizBookableServices('unknown',{services:[shared]}).length,0);
const intent = {source:'quiz',courseKey:'sen',serviceId:'live90',note:'client text ignored',price:1};
assert.deepEqual(resolveQuizBookingIntent(intent,{services:[shared]}),{serviceId:'live90',staffId:'',method:'',step:1,reason:'quiz-ready',note:'頭療測驗偏好：森呼吸'});
assert.equal(resolveQuizBookingIntent(intent,{services:[]}).step,0,'fresh catalogue removal returns to service selection');
assert.equal(resolveQuizBookingIntent({...intent,serviceId:'invented'},{services:[shared]}).note,'','untrusted ID cannot carry a preference into another service');
const source = await readFile(new URL('../src/HeadCareQuiz.jsx',import.meta.url),'utf8');
assert(!source.includes('localStorage')&&!source.includes('sessionStorage'),'answers remain in memory only');
assert(!source.includes('course.price')&&!source.includes('course.bookingUrl'),'prototype price and URL cannot be used for checkout');
console.log(`PASS: head-care quiz verbatim content, seven illustrations, ${combinations} scoring/reason combinations (${ties} ties), catalogue binding and booking intent`);
