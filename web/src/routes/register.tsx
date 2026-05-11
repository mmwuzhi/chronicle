import { createFileRoute, Link, useNavigate } from "@tanstack/react-router";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { z } from "zod/v3";
import { useRegister, useLogin } from "../api";

export const Route = createFileRoute("/register")({
  component: Register,
});

const schema = z.object({
  email: z.string().email(),
  password: z.string().min(8, "Password must be at least 8 characters"),
});
type FormData = z.infer<typeof schema>;

function Register() {
  const navigate = useNavigate();
  const login = useLogin();
  const register = useRegister({
    mutation: {
      onSuccess: async (_, vars) => {
        const res = await login.mutateAsync({ data: vars.data });
        localStorage.setItem("access_token", res.accessToken);
        navigate({ to: "/captures" });
      },
    },
  });

  const {
    register: field,
    handleSubmit,
    formState: { errors },
  } = useForm<FormData>({
    resolver: zodResolver(schema),
  });

  return (
    <div className="flex items-center justify-center min-h-screen">
      <form
        onSubmit={handleSubmit((data) => register.mutate({ data }))}
        className="w-full max-w-sm flex flex-col gap-4 p-8 bg-white rounded-xl border border-gray-200 shadow-sm"
      >
        <h1 className="text-xl font-semibold">Create account</h1>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">Email</label>
          <input
            type="email"
            autoComplete="email"
            {...field("email")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.email && (
            <p className="text-red-500 text-xs">{errors.email.message}</p>
          )}
        </div>

        <div className="flex flex-col gap-1">
          <label className="text-sm font-medium">Password</label>
          <input
            type="password"
            autoComplete="new-password"
            {...field("password")}
            className="border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-gray-900"
          />
          {errors.password && (
            <p className="text-red-500 text-xs">{errors.password.message}</p>
          )}
        </div>

        {(register.error || login.error) && (
          <p className="text-red-500 text-sm">
            Registration failed. Email may already be taken.
          </p>
        )}

        <button
          type="submit"
          disabled={register.isPending || login.isPending}
          className="bg-gray-900 text-white rounded-md py-2 text-sm font-medium hover:bg-gray-700 transition-colors disabled:opacity-50"
        >
          {register.isPending || login.isPending
            ? "Creating account…"
            : "Create account"}
        </button>

        <p className="text-center text-sm text-gray-500">
          Already have an account?{" "}
          <Link
            to="/login"
            className="text-gray-900 font-medium hover:underline"
          >
            Sign in
          </Link>
        </p>
      </form>
    </div>
  );
}
