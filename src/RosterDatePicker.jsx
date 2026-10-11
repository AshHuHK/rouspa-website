import { useEffect, useRef, useState } from 'react';

const minuteLabel = value => `${value >= 1440 ? '翌日 ' : ''}${String(Math.floor(value / 60) % 24).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;

// Touch keeps normal page scrolling. Two taps provide the same date range that
// a mouse drag selects, without capturing a finger's vertical scroll gesture.
export default function RosterDatePicker({ cells, month, today, selected, scheduleFor, onSelectDate, onSelectRange }) {
  const [rangeMode, setRangeMode] = useState(false), [rangeStart, setRangeStart] = useState(null);
  const mouseStart = useRef(null), pointerType = useRef(null);
  useEffect(() => {
    const stop = () => { mouseStart.current = null; };
    window.addEventListener('pointerup', stop);
    window.addEventListener('pointercancel', stop);
    return () => { window.removeEventListener('pointerup', stop); window.removeEventListener('pointercancel', stop); };
  }, []);

  function select(date) {
    if (date < today) return;
    if (!rangeMode) { onSelectDate(date); return; }
    if (!rangeStart) { onSelectDate(date); setRangeStart(date); }
    else { onSelectRange(rangeStart, date); setRangeStart(null); }
  }
  const selectedRange = selected.length > 1 ? `已選 ${selected[0]} ～ ${selected[selected.length - 1]}，共 ${selected.length} 日。` : '';
  const hint = !rangeMode ? '點選單日；滑鼠可按住拖過連續日期。' : rangeStart ? `起日 ${rangeStart}；請點選迄日。` : `${selectedRange}先點選起日，再點選迄日。`;

  return <>
    <div className="roster-selection-tools">
      <button type="button" aria-pressed={rangeMode} onClick={() => { setRangeMode(value => !value); setRangeStart(null); mouseStart.current = null; }}>{rangeMode ? '退出連續日期' : '選擇連續日期'}</button>
      {rangeMode && <button type="button" disabled={!rangeStart} onClick={() => setRangeStart(null)}>清除起日</button>}
      <p className="muted" role="status">{hint}選擇後仍須按「套用到所選日期」才會儲存。</p>
    </div>
    <div className="roster-week-labels">{['一', '二', '三', '四', '五', '六', '日'].map(day => <span key={day}>週{day}</span>)}</div>
    <div className="roster-calendar" onPointerLeave={() => { mouseStart.current = null; }}>
      {cells.map(date => {
        const schedule = scheduleFor(date), inMonth = date.startsWith(month), isSelected = selected.includes(date);
        const time = schedule.is_working ? `${minuteLabel(schedule.start_minute)}–${minuteLabel(schedule.end_minute)}` : '休班';
        return <button type="button" key={date} disabled={date < today} aria-label={`${date}，${time}`} aria-pressed={isSelected}
          className={`${inMonth ? '' : 'outside'} ${isSelected ? 'selected' : ''} ${schedule.source === 'daily' ? 'override' : ''} ${!schedule.is_working ? 'off' : ''}`}
          onPointerDown={event => {
            pointerType.current = event.pointerType;
            if (event.pointerType === 'mouse' && event.button === 0 && !rangeMode) { mouseStart.current = date; onSelectDate(date); }
          }}
          onPointerEnter={event => {
            if (event.pointerType === 'mouse' && event.buttons & 1 && mouseStart.current && date >= today && !rangeMode) onSelectRange(mouseStart.current, date);
          }}
          onClick={event => {
            // Mouse selection already occurred on pointerdown/enter. Keyboard
            // clicks have detail 0; touch clicks arrive after scrolling settles.
            if (rangeMode || event.detail === 0 || pointerType.current !== 'mouse') select(date);
          }}>
          <span>{Number(date.slice(-2))}</span><small>{time}</small><em>{schedule.source === 'daily' ? '特別' : schedule.source === 'weekly' ? '每週' : '未排'}</em>
        </button>;
      })}
    </div>
  </>;
}
