export function isInactiveBooking(booking, now = Date.now()) {
  return ['completed', 'cancelled', 'no_show'].includes(booking.status)
    || Date.parse(booking.ends_at || booking.starts_at) <= now;
}
export function canChangeBooking(booking, now = Date.now()) {
  return ['pending', 'confirmed'].includes(booking.status)
    && !isInactiveBooking(booking, now)
    && booking.can_change !== false
    && Date.parse(booking.change_before) >= now;
}
