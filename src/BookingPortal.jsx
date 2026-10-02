import { useEffect, useState } from 'react';
import { rpc, errorText } from './lib/spa.js';
import BookingLookup from './BookingLookup.jsx';
import { MutationForm, Field, Empty } from './OperationsShared.jsx';

export default function BookingPortal({ token, review = false, lang = 'zh' }) {
  return review ? <ReviewPortal token={token} lang={lang} /> : <BookingLookup standalone privateToken={token} lang={lang} />;
}

function ReviewPortal({ token, lang }) {
  const t = (zh, en) => lang === 'en' ? en : zh;
  const [data, setData] = useState(undefined), [error, setError] = useState('');
  const [rating, setRating] = useState('5'), [comment, setComment] = useState(''), [done, setDone] = useState(false);
  useEffect(() => {
    let live = true;
    setData(undefined);setDone(false);setError('');setRating('5');setComment('');
    rpc('spa_review_context', { p_token: token }).then(next => { if (live) setData(next); })
      .catch(e => { if (live) setError(errorText(e, lang)); });
    return () => { live = false; };
  }, [token]);
  return <div className="ops"><main style={{ maxWidth: 620 }}>
    <header><h1>{t('療程評價', 'Treatment review')}</h1><a href="#">{t('返回首頁', 'Home')}</a></header>
    {error && <p role="alert" className="alert">{error}</p>}
    {data === undefined && !error ? <Empty>{t('載入中…', 'Loading…')}</Empty> : !data ? <Empty>{t('此私人連結無效，或療程尚未完成。', 'This private link is invalid, or the treatment has not been completed.')}</Empty> :
      <div className="card"><h2>{data.service_name}</h2><p>{data.reference}</p>
        {data.therapist && <p>{t('服務技師：', 'Therapist: ')}{data.therapist}</p>}
        {done || data.submitted ? <p role="status">{t('謝謝您的評價，已提交給門店。', 'Thank you. Your review has been submitted.')}</p> :
          <MutationForm lang={lang} action={() => rpc('spa_submit_review', { p_token: token, p_rating: Number(rating), p_comment: comment })} onSaved={async () => setDone(true)} submit={t('提交評價', 'Submit review')}>
            <Field label={t('服務評分', 'Rating')}><select value={rating} onChange={e => setRating(e.target.value)}>{[5, 4, 3, 2, 1].map(n => <option key={n} value={n}>{'★'.repeat(n)} {n} / 5</option>)}</select></Field>
            <Field label={t('您的體驗（最多 1000 字）', 'Your experience (up to 1,000 characters)')}><textarea value={comment} maxLength={1000} rows={5} onChange={e => setComment(e.target.value)} /></Field>
            <p className="muted">{t('評價與本次療程綁定，每次療程可提交一次。公開前由門店審核，公開內容不會顯示姓名與手機。', 'One review per completed visit. Public reviews are moderated and omit your name and phone number.')}</p>
          </MutationForm>}
      </div>}
    <p className="muted">{t('這個連結可存取本次評價，請勿公開分享。', 'This private link gives access to this review. Please keep it private.')}</p>
  </main></div>;
}
