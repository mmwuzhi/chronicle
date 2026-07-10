import { useCallback, useEffect, useRef, useState } from "react";

interface MutationToastState {
  message: string | null;
  show: (message: string) => void;
}

export function useMutationToast(): MutationToastState {
  const [message, setMessage] = useState<string | null>(null);
  const timerRef = useRef<number | null>(null);

  useEffect(
    () => () => {
      if (timerRef.current != null) window.clearTimeout(timerRef.current);
    },
    [],
  );

  // Stable so callbacks built on it (e.g. the feed's onMutationError) don't
  // break the memoized capture cards.
  const show = useCallback((nextMessage: string) => {
    if (timerRef.current != null) window.clearTimeout(timerRef.current);
    setMessage(nextMessage);
    timerRef.current = window.setTimeout(() => setMessage(null), 4000);
  }, []);

  return { message, show };
}
