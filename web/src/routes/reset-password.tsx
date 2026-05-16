import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useMutation } from "@tanstack/react-query";
import { api } from "../lib/axios";

export const Route = createFileRoute("/reset-password")({
  validateSearch: z.object({ token: z.string().default("") }),
  component: ResetPassword,
});

const schema = z
  .object({
    password: z.string().min(8, "Password must be at least 8 characters"),
    confirmPassword: z.string().min(1, "Please confirm your password"),
  })
  .refine((d) => d.password === d.confirmPassword, {
    message: "Passwords do not match",
    path: ["confirmPassword"],
  });
type FormData = z.infer<typeof schema>;

const resetPassword = (token: string, password: string) =>
  api<void>({
    url: "/auth/reset-password",
    method: "POST",
    data: { token, password },
  });

function ResetPassword() {
  const { token } = Route.useSearch();
  const navigate = useNavigate();
  const mutation = useMutation({
    mutationFn: (password: string) => resetPassword(token, password),
    onSuccess: () => navigate({ to: "/login" }),
  });

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  if (!token) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm text-center">
          <h1 className="text-xl font-semibold">Invalid link</h1>
          <p className="text-sm text-gray-600">
            Use the link from your reset email.
          </p>
          <Link
            to="/forgot-password"
            className="mt-2 text-sm text-gray-900 font-medium hover:underline"
          >
            Request a new link
          </Link>
        </div>
      </div>
    );
  }

  return (
    <div className="flex items-center justify-center min-h-screen">
      <form
        onSubmit={handleSubmit((data) => mutation.mutate(data.password))}
        className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm"
      >
        <h1 className="text-xl font-semibold">Choose a new password</h1>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">New password</label>
          <input
            type="password"
            autoComplete="new-password"
            {...register("password")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.password && (
            <p className="text-red-500 text-xs">{errors.password.message}</p>
          )}
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">Confirm new password</label>
          <input
            type="password"
            autoComplete="new-password"
            {...register("confirmPassword")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.confirmPassword && (
            <p className="text-red-500 text-xs">
              {errors.confirmPassword.message}
            </p>
          )}
        </div>

        {mutation.isError && (
          <p className="text-red-500 text-sm">
            This link is invalid or has expired.
          </p>
        )}

        <button
          type="submit"
          disabled={mutation.isPending}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {mutation.isPending ? "Saving…" : "Set new password"}
        </button>
      </form>
    </div>
  );
}
