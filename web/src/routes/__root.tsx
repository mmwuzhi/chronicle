import { createRootRoute, Outlet } from "@tanstack/react-router";
import { ConfirmProvider } from "../components/confirm-dialog";

export const Route = createRootRoute({
  component: () => (
    <ConfirmProvider>
      <div className="min-h-screen bg-gray-50 text-gray-900">
        <Outlet />
      </div>
    </ConfirmProvider>
  ),
});
