// Rebooking carries only catalogue identifiers in React memory. Historical
// prices, dates, contacts and private access tokens never enter the new draft.
export function canRebookBooking(booking) {
  return !!booking && ['completed', 'cancelled'].includes(booking.status)
    && typeof booking.service_id === 'string' && booking.service_id.length > 0;
}

export function createRebookingIntent(booking) {
  if (!canRebookBooking(booking)) return null;
  return { serviceId: booking.service_id, staffId: typeof booking.staff_id === 'string' ? booking.staff_id : null };
}

export function resolveRebookingIntent(intent, catalog) {
  const service = catalog?.services?.find(item => item.id === intent?.serviceId && item.active !== false
    && !['draft', 'archived'].includes(item.status) && item.online_booking_enabled !== false);
  if (!service) return { serviceId: '', staffId: '', method: '', step: 0, reason: 'service-unavailable' };
  const staff = catalog?.staff?.find(item => item.id === intent?.staffId && item.active !== false
    && (!item.employment_status || item.employment_status === 'active') && !item.archived_at && item.is_bookable !== false);
  const qualified = staff && catalog?.skills?.some(skill => skill.staff_id === staff.id && skill.service_id === service.id && skill.enabled !== false);
  return { serviceId: service.id, staffId: qualified ? staff.id : '', method: qualified ? 'staff' : '', step: 1,
    reason: qualified ? 'ready' : 'therapist-unavailable' };
}
