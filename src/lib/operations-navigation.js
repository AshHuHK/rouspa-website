export function bookingMatchesContext(row, context) {
 if (!context) return true;
 if (context.status && row.status !== context.status) return false;
 if (context.statuses && !context.statuses.includes(row.status)) return false;
 if (context.staff_id && row.staff_id !== context.staff_id) return false;
 if (context.room_id && row.room_id !== context.room_id) return false;
 if (context.unsettled && (row.status !== 'completed' || row.checkout)) return false;
 if (context.starts_before && !(new Date(row.starts_at) <= new Date(context.starts_before))) return false;
 if (context.ends_after && !(new Date(row.ends_at) > new Date(context.ends_after))) return false;
 if (context.ends_before && !(new Date(row.ends_at) <= new Date(context.ends_before))) return false;
 if (context.blocked_after && !(new Date(row.blocked_until) > new Date(context.blocked_after))) return false;
 return true;
}

export function reviewMatchesContext(row, context) {
 if (!context) return true;
 if (context.status && row.status !== context.status) return false;
 const day = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Taipei', year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date(row.created_at));
 return (!context.from || day >= context.from) && (!context.to || day <= context.to);
}
