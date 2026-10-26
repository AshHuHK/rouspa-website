export function confirmedStaffPassword(password, confirmation) {
  if (password !== confirmation) throw new Error('PASSWORD_MISMATCH');
  return password;
}
