import {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
  type ReactNode,
} from "react";
import * as Dialog from "@radix-ui/react-dialog";

interface ConfirmOptions {
  title: string;
  description: string;
  confirmLabel?: string;
  cancelLabel?: string;
  variant?: "danger" | "default";
}

type ConfirmFn = (options: ConfirmOptions) => Promise<boolean>;

const ConfirmContext = createContext<ConfirmFn | null>(null);

export function useConfirm(): ConfirmFn {
  const fn = useContext(ConfirmContext);
  if (!fn) throw new Error("useConfirm must be used within ConfirmProvider");
  return fn;
}

export function ConfirmProvider({ children }: { children: ReactNode }) {
  const [options, setOptions] = useState<ConfirmOptions | null>(null);
  const resolveRef = useRef<((value: boolean) => void) | null>(null);

  const confirm = useCallback<ConfirmFn>(
    (opts) =>
      new Promise<boolean>((resolve) => {
        resolveRef.current = resolve;
        setOptions(opts);
      }),
    [],
  );

  const handleClose = useCallback((value: boolean) => {
    resolveRef.current?.(value);
    resolveRef.current = null;
    setOptions(null);
  }, []);

  const variant = options?.variant ?? "default";

  return (
    <ConfirmContext.Provider value={confirm}>
      {children}
      <Dialog.Root
        open={options !== null}
        onOpenChange={(open) => {
          if (!open) handleClose(false);
        }}
      >
        <Dialog.Portal>
          <Dialog.Overlay className="fixed inset-0 bg-black/40" />
          <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
            <Dialog.Title className="text-lg font-semibold">
              {options?.title}
            </Dialog.Title>
            <Dialog.Description className="text-sm text-gray-600">
              {options?.description}
            </Dialog.Description>
            <div className="flex justify-end gap-3 mt-2">
              <button
                onClick={() => handleClose(false)}
                className="text-sm px-4 py-2 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors"
              >
                {options?.cancelLabel ?? "Cancel"}
              </button>
              <button
                onClick={() => handleClose(true)}
                className={`text-sm px-4 py-2 rounded-md transition-colors ${
                  variant === "danger"
                    ? "bg-red-600 text-white hover:bg-red-700"
                    : "bg-gray-900 text-white hover:bg-gray-700"
                }`}
              >
                {options?.confirmLabel ?? "Confirm"}
              </button>
            </div>
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </ConfirmContext.Provider>
  );
}
