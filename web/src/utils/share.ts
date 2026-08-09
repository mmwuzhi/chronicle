export function buildCaptureShareURL(id: string, secret: string): string {
  const url = new URL(`/s/${encodeURIComponent(id)}`, window.location.origin);
  url.hash = secret;
  return url.toString();
}

export function isCaptureShareExpired(expiresAt: string | null): boolean {
  return expiresAt !== null && new Date(expiresAt).getTime() <= Date.now();
}
