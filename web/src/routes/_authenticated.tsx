import { createFileRoute, Outlet, redirect } from "@tanstack/react-router";
import { rememberPostAuthRedirect } from "@/lib/post-auth-redirect";

export const Route = createFileRoute("/_authenticated")({
  beforeLoad: ({ location }) => {
    if (localStorage.getItem("access_token")) return;
    rememberPostAuthRedirect(location.href);
    throw redirect({ to: "/login", replace: true });
  },
  component: Outlet,
});
