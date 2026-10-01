import { useEffect, useState } from 'react';
import { rpc, errorText } from './lib/spa.js';
import BookingLookup from './BookingLookup.jsx';
import { MutationForm, Field, Empty } from './OperationsShared.jsx';

export default function BookingPortal({ token, review = false }) {
  return review ? <ReviewPortal token={token} /> : <BookingLookup standalone privateToken={token} />;
}

function ReviewPortal({ token }) {
  const [data, setData] = useState(undefined), [error, setError] = useState('');
  const [rating, setRating] = useState('5'), [comment, setComment] = useState(''), [done, setDone] = useState(false);
  useEffect(() => {
    let live = true;
    setData(undefined);setDone(false);setError('');setRating('5');setComment('');
    rpc('spa_review_context', { p_token: token }).then(next => { if (live) setData(next); })
      .catch(e => { if (live) setError(errorText(e)); });
    return () => { live = false; };
  }, [token]);
  return <div className="ops"><main style={{ maxWidth: 620 }}>
    <header><h1>療程評價</h1><a href="#">返回首頁</a></header>
    {error && <p role="alert" className="alert">{error}</p>}
    {data === undefined && !error ? <Empty>載入中…</Empty> : !data ? <Empty>此私人連結無效，或療程尚未完成。</Empty> :
      <div className="card"><h2>{data.service_name}</h2><p>{data.reference}</p>
        {data.therapist && <p>服務技師：{data.therapist}</p>}
        {done || data.submitted ? <p role="status">謝謝您的評價，已提交給門店。</p> :
          <MutationForm action={() => rpc('spa_submit_review', { p_token: token, p_rating: Number(rating), p_comment: comment })} onSaved={async () => setDone(true)} submit="提交評價">
            <Field label="服務評分"><select value={rating} onChange={e => setRating(e.target.value)}>{[5, 4, 3, 2, 1].map(n => <option key={n} value={n}>{'★'.repeat(n)} {n} 分</option>)}</select></Field>
            <Field label="您的體驗（最多 1000 字）"><textarea value={comment} maxLength={1000} rows={5} onChange={e => setComment(e.target.value)} /></Field>
            <p className="muted">評價與本次療程綁定，每次療程可提交一次。公開前由門店審核，公開內容不會顯示姓名與手機。</p>
          </MutationForm>}
      </div>}
    <p className="muted">這個連結可存取本次評價，請勿公開分享。</p>
  </main></div>;
}
