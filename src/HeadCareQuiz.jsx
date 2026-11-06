import { useEffect, useLayoutEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { QUIZ_CONTENT as content, rankQuizAnswers, quizReasonsFor, quizBookableServices } from './lib/head-care-quiz.js';
import { usePublicCatalog } from './lib/usePublicData.js';
import { money } from './lib/spa.js';
import { STORE } from './lib/public-copy.js';
import './head-care-quiz.css';

export function QuizSpark({ className = '' }) {
  return <svg className={className} viewBox="0 0 32 32" width="28" height="28" fill="none" aria-hidden="true"><path d="M16 3c1.4 8.1 4.9 11.6 13 13-8.1 1.4-11.6 4.9-13 13C14.6 20.9 11.1 17.4 3 16 11.1 14.6 14.6 11.1 16 3Z" stroke="currentColor" strokeWidth="1.4"/><path d="m26 2 .8 3.2L30 6l-3.2.8L26 10l-.8-3.2L22 6l3.2-.8L26 2Z" fill="currentColor"/></svg>;
}

export function HeadCareQuizEntry({ lang = 'zh' }) {
  return <div className="hq-entry"><p>{lang === 'en' ? 'Not sure which ritual to choose? · Quiz in Chinese' : '還在想，哪一種頭療適合自己？'}</p><button type="button" data-head-care-quiz aria-haspopup="dialog"><QuizSpark/><span>{lang === 'en' ? 'Find your ritual in 10 seconds' : '10秒測出你的專屬課程'}</span><span aria-hidden="true">→</span></button></div>;
}

function BookingChoices({ courseKey, catalog, loading, error, onRetry, onBook, compact = false }) {
  const choices = quizBookableServices(courseKey, catalog);
  const course = content.courses[courseKey];
  return <div className={`hq-booking ${compact ? 'hq-booking-compact' : ''}`}>
    {loading && !catalog ? <p role="status">正在核對目前療程與價格…</p> : error ? <><p role="alert">{error}</p><button className="hq-button hq-secondary" onClick={onRetry}>重新讀取療程</button></> : choices.length ? <>
      {!compact && <p className="hq-booking-note">將帶入「{course.name}」偏好；日期、時段與技師於下一步選擇。</p>}
      {choices.map(service => <div className="hq-booking-choice" key={service.id}><p>{service.name} · {service.duration_minutes} 分鐘 <strong>{money(service.price_cents)}</strong></p><button className={compact ? 'hq-text-button' : 'hq-button hq-primary'} onClick={() => onBook({ courseKey, serviceId: service.id })}>{compact ? `預約${course.name}` : choices.length > 1 ? `預約${service.name}` : '立即預約'}<span aria-hidden="true"> →</span></button></div>)}
    </> : <p className="hq-booking-note">此推薦目前未開放對應的 90 分鐘線上預約，請透過 LINE 詢問門店。</p>}
    {(!choices.length || error) && <a className="hq-text-button" href={STORE.LINE_URL} target="_blank" rel="noopener noreferrer">LINE 療程諮詢 ↗</a>}
  </div>;
}

function Result({ answers, catalogResource, onBook, onRestart, onEdit }) {
  const result = rankQuizAnswers(answers);
  if (!result) return null;
  const key = result.primary, course = content.courses[key];
  const short = id => content.questions.find(q => q.id === id)?.short || id;
  return <section className="hq-screen">
    <header className="hq-result-heading"><p className="hq-eyebrow">YOUR RITUAL</p><h2 tabIndex={-1}>你的專屬頭療推薦</h2>{result.isTie && <p className="hq-tie-note">{[key, ...result.also].map(id => `「${content.courses[id].name}」`).join('和')}的分數相同，都很適合你。{result.decidedBy ? `我們依你在「${short(result.decidedBy)}」的選擇，把${course.name}列為主要推薦。` : ''}</p>}</header>
    <article className="hq-course"><img className="hq-course-art" src={`/quiz/${key}.svg`} alt={`${course.name}｜${course.subtitle} 形象圖`} width="320" height="200"/><div className="hq-course-body">
      <div>{result.isTie && <span className="hq-tag">主要推薦</span>}<h3 className="hq-course-name">{course.name}</h3><p className="hq-course-sub">{course.subtitle}</p></div>
      <div><h4 className="hq-section-label">為什麼推薦你</h4><ul className="hq-reasons">{quizReasonsFor(key, answers).map(text => <li key={text}>{text}</li>)}</ul></div>
      <div><h4 className="hq-section-label">課程特色</h4><ul className="hq-features">{course.features.map(text => <li key={text}>{text}</li>)}</ul><p className="hq-suits">{course.suits}</p></div>
      <BookingChoices courseKey={key} {...catalogResource} onBook={onBook}/><button className="hq-button hq-secondary" onClick={onRestart}>重新測驗</button>
    </div></article>
    {!!result.also.length && <div className="hq-alternatives"><h3 className="hq-section-label">{result.also.length > 1 ? '另外兩個也很適合你' : '另一個也很適合你'}</h3>{result.also.map(id => <article className="hq-alt" key={id}><img src={`/quiz/${id}.svg`} alt={`${content.courses[id].name} 形象圖`} width="320" height="200" loading="lazy"/><div><h3>{content.courses[id].name}</h3><p className="hq-course-sub">{content.courses[id].subtitle}</p><p>{quizReasonsFor(id, answers, 1)[0]}</p><BookingChoices compact courseKey={id} {...catalogResource} onBook={onBook}/></div></article>)}</div>}
    <p className="hq-care"><strong>小提醒</strong>　{content.careNote}</p><button className="hq-text-button hq-edit" onClick={onEdit}>回到上一題修改答案</button>
  </section>;
}

function QuizDialog({ onClose, onBook }) {
  const dialog = useRef(null), stage = useRef(null);
  const [step, setStep] = useState(0), [answers, setAnswers] = useState({});
  const resource = usePublicCatalog();
  useLayoutEffect(() => {
    const opener = document.activeElement, previousOverflow = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    dialog.current.showModal();
    const element = dialog.current;
    return () => { element.close(); document.body.style.overflow = previousOverflow; if (opener?.isConnected) opener.focus({ preventScroll: true }); };
  }, []);
  useLayoutEffect(() => {
    dialog.current.scrollTop = 0;
    stage.current.querySelector('h2')?.focus({ preventScroll: true });
  }, [step]);
  useEffect(() => {
    if (step !== 'loading') return;
    const timer = setTimeout(() => setStep('result'), window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 350 : 1300);
    return () => clearTimeout(timer);
  }, [step]);
  const question = typeof step === 'number' ? content.questions[step] : null;
  return createPortal(<dialog ref={dialog} className="hq-dialog" aria-labelledby="hq-dialog-title" onCancel={event => { event.preventDefault(); onClose(); }}>
    <div className="hq-top"><div><span id="hq-dialog-title">柔療髮浴 <small>ROU SPA · 頭療測驗</small></span><button className="hq-close" type="button" aria-label="關閉測驗" onClick={onClose}>×</button></div></div>
    <div ref={stage} className="hq-stage">
      {question && <section className="hq-screen" key={question.id}>
        <div className="hq-progress" aria-label={`第 ${step + 1} 題，共 4 題`}><span>{String(step + 1).padStart(2, '0')} / 04</span><div aria-hidden="true">{content.questions.map((q, i) => <i key={q.id} className={i <= step ? 'is-active' : ''}/>)}</div></div>
        <p className="hq-eyebrow">{question.label}</p><h2 className="hq-question-title" id="hq-question" tabIndex={-1}>{question.title}</h2>
        <fieldset className={question.type === 'image' ? 'hq-pictures' : 'hq-options'}><legend className="hq-sr">{question.title}</legend>{question.options.map(option => <label key={option.key} className={`hq-option ${question.type === 'image' ? 'hq-picture' : ''} ${answers[question.id] === option.key ? 'is-selected' : ''}`}>
          <input type="radio" name={question.id} value={option.key} checked={answers[question.id] === option.key} onChange={() => setAnswers(current => ({ ...current, [question.id]: option.key }))}/>
          {question.type === 'image' && <span className="hq-image"><img src={`/quiz/${option.art}.svg`} alt={option.alt} width="200" height="200"/><span className="hq-image-check" aria-hidden="true">✓</span></span>}
          <span className="hq-option-caption"><span className="hq-option-letter" aria-hidden="true">{option.key}</span><span>{option.text}</span></span>
        </label>)}</fieldset>
        <div className="hq-navigation"><button className="hq-button hq-secondary" disabled={step === 0} onClick={() => setStep(current => current - 1)}>上一題</button><button className="hq-button hq-primary" disabled={!answers[question.id]} onClick={() => setStep(step === content.questions.length - 1 ? 'loading' : step + 1)}>{step === content.questions.length - 1 ? '看我的結果' : '下一題'}</button></div><p className="hq-hint">{answers[question.id] ? '\u00a0' : '選好一個答案，就能繼續'}</p>
      </section>}
      {step === 'loading' && <section className="hq-loading" role="status"><span className="hq-loading-seal" aria-hidden="true">柔</span><h2 className="hq-sr" tabIndex={-1}>分析中</h2><p>正在為你調配專屬方子…</p></section>}
      {step === 'result' && <Result answers={answers} catalogResource={{catalog:resource.data,loading:resource.loading,error:resource.error,onRetry:resource.refresh}} onBook={onBook} onRestart={() => { setAnswers({}); setStep(0); }} onEdit={() => setStep(3)}/>}
    </div>
  </dialog>, document.body);
}

export default function HeadCareQuiz({ lang = 'zh', onBook, route }) {
  const [open, setOpen] = useState(false), [blocked, setBlocked] = useState(false);
  useEffect(() => {
    const listener = event => {
      if (!event.target.closest?.('[data-head-care-quiz]')) return;
      if (document.querySelector('[data-booking-pending="true"]')) { setBlocked(true); return; }
      setBlocked(false); setOpen(true);
    };
    document.addEventListener('click', listener);
    return () => document.removeEventListener('click', listener);
  }, []);
  useEffect(() => setOpen(false), [route]);
  return <><button className="hq-floating" type="button" data-head-care-quiz aria-haspopup="dialog" aria-label={lang === 'en' ? 'Take the head-care quiz (Traditional Chinese)' : '測一測，找到適合你的頭療'}><QuizSpark/><span>{lang === 'en' ? 'Quiz' : '測一測'}</span></button>{blocked && <div className="hq-floating-note" role="status"><p>{lang === 'en' ? 'Check the previous booking result before starting a new recommendation.' : '請先確認剛才預約的結果，再開始新的課程推薦。'}</p><button onClick={() => setBlocked(false)} aria-label={lang === 'en' ? 'Dismiss message' : '關閉提示'}>×</button></div>}{open && <QuizDialog onClose={() => setOpen(false)} onBook={intent => { setOpen(false); onBook(intent); }}/>}</>;
}
