import { createFileRoute } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useState } from "react";
import { useMutation } from "@tanstack/react-query";
import { api } from "../lib/axios";

export const Route = createFileRoute("/forgot-password")({
  component: ForgotPassword,
});

const schema = z.object({ email: z.string().email() });
type FormData = z.infer<typeof schema>;

const forgotPassword = (email: string) =>
  api<void>({
    url: "/auth/forgot-password",
    method: "POST",
    data: { email },
  });

function ForgotPassword() {
  const [submitted, setSubmitted] = useState(false);
  const mutation = useMutation({
    mutationFn: (email: string) => forgotPassword(email),
    onSuccess: () => setSubmitted(true),
    onError: () => setSubmitted(true), // don't reveal if email exists
  });

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({ resolver: zodResolver(schema) });

  if (submitted) {
    return (
      <div className="flex items-center justify-center min-h-screen">
        <div className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm text-center">
          <h1 className="text-xl font-semibold">Check your inbox</h1>
          <p className="text-sm text-gray-600">
            If that email is registered, a reset link is on its way.
          </p>
        </div>
      </div>
    );
  }

  return (
    <div className="flex items-center justify-center min-h-screen">
      <form
        onSubmit={handleSubmit((data) => mutation.mutate(data.email))}
        className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm"
      >
        <h1 className="text-xl font-semibold">Reset password</h1>
        <p className="text-sm text-gray-500">
          Enter your email and we'll send you a reset link.
        </p>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">Email</label>
          <input
            type="email"
            autoComplete="email"
            {...register("email")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.email && (
            <p className="text-red-500 text-xs">{errors.email.message}</p>
          )}
        </div>

        <button
          type="submit"
          disabled={mutation.isPending}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {mutation.isPending ? "Sending…" : "Send reset link"}
        </button>
      </form>
    </div>
  );
}
