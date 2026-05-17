import { createFileRoute, useNavigate } from "@tanstack/react-router";
import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import * as Dialog from "@radix-ui/react-dialog";
import { Nav } from "../components/nav";
import { api } from "../lib/axios";

export const Route = createFileRoute("/settings")({
  component: Settings,
});

const deleteAccount = () =>
  api<void>({ url: "/users/me", method: "DELETE" });

function Settings() {
  const navigate = useNavigate();
  const [open, setOpen] = useState(false);

  const mutation = useMutation({
    mutationFn: deleteAccount,
    onSuccess: () => {
      localStorage.removeItem("access_token");
      navigate({ to: "/" });
    },
  });

  return (
    <div className="min-h-screen bg-gray-50">
      <Nav />
      <div className="max-w-3xl mx-auto px-8 py-12">
        <h1 className="text-xl font-semibold mb-8">Settings</h1>

        <div className="bg-white rounded-xl border border-gray-200 shadow-sm">
          <div className="p-6 border-b border-gray-100">
            <h2 className="text-sm font-semibold text-red-600">Danger zone</h2>
          </div>
          <div className="p-6 flex items-center justify-between">
            <div>
              <p className="text-sm font-medium">Delete account</p>
              <p className="text-xs text-gray-500 mt-0.5">
                Permanently delete your account and all data. This cannot be
                undone.
              </p>
            </div>
            <Dialog.Root open={open} onOpenChange={setOpen}>
              <Dialog.Trigger asChild>
                <button className="text-sm px-4 py-2 rounded-md border border-red-300 text-red-600 hover:bg-red-50 transition-colors">
                  Delete account
                </button>
              </Dialog.Trigger>
              <Dialog.Portal>
                <Dialog.Overlay className="fixed inset-0 bg-black/40" />
                <Dialog.Content className="fixed top-1/2 left-1/2 -translate-x-1/2 -translate-y-1/2 bg-white rounded-xl shadow-lg p-6 w-full max-w-sm flex flex-col gap-4">
                  <Dialog.Title className="text-lg font-semibold">
                    Delete account
                  </Dialog.Title>
                  <Dialog.Description className="text-sm text-gray-600">
                    This will permanently delete your account and all your data.
                    This action cannot be undone.
                  </Dialog.Description>
                  {mutation.isError && (
                    <p className="text-sm text-red-500">
                      Something went wrong. Please try again.
                    </p>
                  )}
                  <div className="flex justify-end gap-3 mt-2">
                    <Dialog.Close asChild>
                      <button className="text-sm px-4 py-2 rounded-md border border-gray-300 hover:bg-gray-50 transition-colors">
                        Cancel
                      </button>
                    </Dialog.Close>
                    <button
                      onClick={() => mutation.mutate()}
                      disabled={mutation.isPending}
                      className="text-sm px-4 py-2 rounded-md bg-red-600 text-white hover:bg-red-700 transition-colors disabled:opacity-50"
                    >
                      {mutation.isPending ? "Deleting…" : "Yes, delete"}
                    </button>
                  </div>
                </Dialog.Content>
              </Dialog.Portal>
            </Dialog.Root>
          </div>
        </div>
      </div>
    </div>
  );
}
