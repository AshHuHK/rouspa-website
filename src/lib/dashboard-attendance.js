const epoch=value=>{
 const result=Date.parse(value);
 return Number.isFinite(result)?result:null;
};

export const attendanceStatusLabels={
 working:'上班中',
 completed:'已下班',
 on_leave:'休假中',
 upcoming:'尚未到班',
 late:'遲到未到',
 absent:'整班未到',
};

export function dashboardAttendanceBoundaries(packet){
 const grace=Number(packet?.grace_minutes)||0;
 return (packet?.staff||[]).flatMap(row=>{
  const start=epoch(row.shift_start),end=epoch(row.shift_end);
  const boundaries=[start==null?null:start+grace*60000,end];
  for(const leave of row.time_off||[])boundaries.push(epoch(leave.starts_at),epoch(leave.ends_at));
  return boundaries.filter(Number.isFinite);
 });
}

export function dashboardAttendanceStatus(row,now=Date.now(),graceMinutes=0){
 if(row.open_clock_in)return 'working';
 if(Number(row.attendance_count)>0)return 'completed';
 const leave=(row.time_off||[]).some(item=>{
  const start=epoch(item.starts_at),end=epoch(item.ends_at);
  return start!=null&&end!=null&&start<=now&&now<end;
 });
 if(leave)return 'on_leave';
 const start=epoch(row.shift_start),end=epoch(row.shift_end);
 if(start==null||end==null)return 'upcoming';
 if(now<start+Number(graceMinutes||0)*60000)return 'upcoming';
 return now<end?'late':'absent';
}

export function summarizeDashboardAttendance(packet,now=Date.now()){
 const grace=Number(packet?.grace_minutes)||0;
 const staff=(packet?.staff||[]).map(row=>({...row,display_status:dashboardAttendanceStatus(row,now,grace)}));
 const count=status=>staff.filter(row=>row.display_status===status).length;
 const working=count('working'),completed=count('completed'),onLeave=count('on_leave'),upcoming=count('upcoming'),late=count('late'),absent=count('absent');
 return {staff,scheduled:staff.length,arrived:working+completed,working,completed,onLeave,upcoming,late,absent,lateMissing:late+absent};
}
