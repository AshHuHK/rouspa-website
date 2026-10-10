function operationsTodoCount(task) {
  const count = Number(task?.count);
  return Number.isSafeInteger(count) && count > 0 ? count : 0;
}

export function activeOperationsTodos(data, allowed) {
  return (data?.todos || []).filter(task => task?.key && operationsTodoCount(task) > 0 && (!allowed || allowed(task.module)));
}

// Sum the visible, authorized reminder counts; categories are shown separately.
export function operationsTodoTotal(todos) {
  return (todos || []).reduce((total, task) => total + operationsTodoCount(task), 0);
}

// Ignore timestamps in navigation context: a later read should not repeat a
// reminder unless its underlying task set, count or urgency actually changed.
export function operationsTodoIdentity(task) {
  return JSON.stringify([task.key, task.module, Number(task.count), task.revision || '', task.severity || 'normal']);
}

export function changedOperationsTodos(previous, current) {
  if (previous === null) return [];
  const before = new Map((previous || []).map(task => [task.key, operationsTodoIdentity(task)]));
  return (current || []).filter(task => before.get(task.key) !== operationsTodoIdentity(task));
}

export function mergeOperationsToasts(previous, changed, current, limit = 3) {
  const active = new Map((current || []).map(task => [task.key, operationsTodoIdentity(task)]));
  const incoming = new Set((changed || []).map(task => task.key));
  const retained = (previous || []).filter(task => active.get(task.key) === operationsTodoIdentity(task) && !incoming.has(task.key));
  return [...(changed || []), ...retained].slice(0, Math.max(0, limit));
}
