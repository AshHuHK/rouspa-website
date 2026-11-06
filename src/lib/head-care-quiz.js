import { QUIZ_CONTENT as content, QUIZ_SCORES as scores } from './head-care-quiz-content.js';
import { servicePresentationCards } from './catalog-presentation.js';

export { QUIZ_CONTENT, QUIZ_SCORES } from './head-care-quiz-content.js';
const order = scores.courseOrder;
const points = (key, question, answers) => scores.table[question]?.[answers[question]]?.[order.indexOf(key)] || 0;

export function rankQuizAnswers(answers) {
  if (!content.questions.every(q => q.options.some(option => option.key === answers[q.id]))) return null;
  const totals = Object.fromEntries(order.map(key => [key, content.questions.reduce((total, q) => total + points(key, q.id, answers), 0)]));
  const max = Math.max(...Object.values(totals));
  const tied = order.filter(key => totals[key] === max);
  const sorted = [...tied].sort((a, b) => {
    for (const question of scores.tieBreak) {
      const difference = points(b, question, answers) - points(a, question, answers);
      if (difference) return difference;
    }
    return order.indexOf(a) - order.indexOf(b);
  });
  const decidedBy = tied.length > 1 ? scores.tieBreak.find(question => sorted.slice(1).some(key => points(key, question, answers) !== points(sorted[0], question, answers))) || null : null;
  return { totals, max, primary: sorted[0], also: sorted.slice(1), isTie: tied.length > 1, decidedBy };
}

export function quizReasonsFor(key, answers, count = 3) {
  const reasons = content.questions.map((q, index) => ({ points: points(key, q.id, answers), index, text: content.reasons[key]?.[q.id + answers[q.id]] }))
    .filter(row => row.text).sort((a, b) => b.points - a.points || a.index - b.index).slice(0, count).map(row => row.text);
  if (reasons.length < Math.min(2, count) && content.courses[key]) reasons.push(content.courses[key].fallbackReason);
  return reasons;
}

// A ritual can be a published card inside a shared 90-minute package. Resolve
// its current ID and price; never guess an ID, another duration or a hidden card.
export function quizBookableServices(key, catalog) {
  const name = content.courses[key]?.name;
  if (!name) return [];
  const normalized = value => String(value || '').normalize('NFKC').replace(/\s/g, '');
  return (catalog?.services || []).filter(service => service.id && service.active !== false && !service.archived_at
    && !['draft', 'archived'].includes(service.status) && service.online_booking_enabled !== false
    && service.website_visible !== false && Number(service.duration_minutes) === 90
    && (!service.category_code || service.category_code === 'duration_90')
    && (normalized(service.name) === normalized(name) || servicePresentationCards(service, 'zh').some(card => normalized(card.name) === normalized(name))));
}

export function resolveQuizBookingIntent(intent, catalog) {
  const service = quizBookableServices(intent?.courseKey, catalog).find(row => row.id === intent?.serviceId);
  if (!service) return { serviceId: '', staffId: '', method: '', step: 0, reason: 'quiz-unavailable', note: '' };
  return { serviceId: service.id, staffId: '', method: '', step: 1, reason: 'quiz-ready', note: `頭療測驗偏好：${content.courses[intent.courseKey].name}` };
}
