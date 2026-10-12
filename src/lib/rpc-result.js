// Some public identity failures are returned instead of raised so PostgreSQL
// commits abuse counters. They must still be failures for every UI caller.
export function unwrapRpcResult(data) {
  if (data && !Array.isArray(data) && typeof data === 'object' && typeof data.error === 'string') {
    const error = new Error(data.error);
    error.code = data.error;
    throw error;
  }
  return data;
}

export function isInvalidSession(error) {
  return ['PGRST301', 'PGRST302', 'PGRST303', 'AUTH_SESSION_INVALID'].includes(error?.code)
    || /JWT expired|invalid JWT|Invalid Refresh Token|Refresh Token Not Found/i.test(error?.message || '');
}
