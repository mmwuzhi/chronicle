export function hasActiveTextSelection(): boolean {
  const selection = window.getSelection();
  return Boolean(
    selection && !selection.isCollapsed && selection.toString().length > 0,
  );
}

export function isInteractiveTarget(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  return Boolean(
    target.closest(
      'a, button, input, textarea, select, audio, video, [contenteditable="true"]',
    ),
  );
}
