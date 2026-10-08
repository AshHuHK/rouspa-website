// Read paths may replace catalogue arrays while an operator still has a draft.
export function preserveSelectedCoupon(selected, coupons) {
  return selected && coupons.some(coupon => coupon.id === selected && (!coupon.status || coupon.status === 'active')) ? selected : '';
}

export function reconcilePosCart(cart, catalog) {
  return cart.map(row => {
    const current = (row.item_type === 'service' ? catalog.services : catalog.products).find(item => item.id === row.id);
    return current ? { ...row, price_cents: current.price_cents, inventory: current.inventory } : row;
  });
}

export function weeklyRosterFields(row) {
  return { working: !!row, start: row?.start_minute ?? 600, end: row?.end_minute ?? 1080 };
}

function sameWeeklyRoster(left, right) {
  return !!left && !!right && left.working === right.working && (!left.working || Number(left.start) === Number(right.start) && Number(left.end) === Number(right.end));
}

export function reconcileWeeklyRoster(previous, draft, incoming, { reset = false, dirty = false } = {}) {
  const preserve = dirty && !reset;
  return {
    draft: preserve ? draft : incoming,
    dirty: preserve && !sameWeeklyRoster(draft, incoming),
    officialChanged: preserve && !!previous && !sameWeeklyRoster(previous, incoming),
  };
}
