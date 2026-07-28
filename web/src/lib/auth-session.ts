export function isSameAccessToken(
  current: string | null,
  expected: string | null,
): boolean {
  return current === expected;
}
