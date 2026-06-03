import {
  createContext,
  useCallback,
  useContext,
  useRef,
  useState,
  type ReactNode,
} from "react";
import * as Dialog from "@radix-ui/react-dialog";
import { useTranslation } from "react-i18next";

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
  const { t } = useTranslation();
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

  const isDanger = options?.variant === "danger";

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
          <Dialog.Overlay
            style={{
              position: "fixed",
              inset: 0,
              background: "color-mix(in srgb, var(--text) 22%, transparent)",
              backdropFilter: "blur(2px)",
            }}
          />
          <Dialog.Content
            className="ch-card"
            style={{
              position: "fixed",
              top: "50%",
              left: "50%",
              transform: "translate(-50%, -50%)",
              width: "calc(100% - 32px)",
              maxWidth: 360,
              padding: 24,
              display: "flex",
              flexDirection: "column",
              gap: 16,
            }}
          >
            <Dialog.Title
              style={{
                margin: 0,
                fontFamily: "var(--font-display)",
                fontSize: 17,
                fontWeight: 700,
                color: "var(--text)",
              }}
            >
              {options?.title}
            </Dialog.Title>
            <Dialog.Description
              style={{
                margin: 0,
                fontSize: "var(--fs-sm)",
                color: "var(--text-muted)",
                lineHeight: 1.5,
              }}
            >
              {options?.description}
            </Dialog.Description>
            <div
              style={{
                display: "flex",
                justifyContent: "flex-end",
                gap: 8,
                marginTop: 4,
              }}
            >
              <button
                className="ch-btn ch-btn-ghost ch-btn-sm"
                onClick={() => handleClose(false)}
              >
                {options?.cancelLabel ?? t("actions.cancel")}
              </button>
              <button
                className={`ch-btn ch-btn-sm ${isDanger ? "" : "ch-btn-primary"}`}
                style={
                  isDanger
                    ? {
                        background: "#dc2626",
                        borderColor: "#dc2626",
                        color: "#fff",
                      }
                    : undefined
                }
                onClick={() => handleClose(true)}
              >
                {options?.confirmLabel ?? t("actions.confirm")}
              </button>
            </div>
          </Dialog.Content>
        </Dialog.Portal>
      </Dialog.Root>
    </ConfirmContext.Provider>
  );
}
