import { createRootRoute, Outlet } from "@tanstack/react-router";
import { ConfirmProvider } from "../components/confirm-dialog";

export const Route = createRootRoute({
  component: () => (
    <ConfirmProvider>
      <div className="min-h-screen bg-gray-50 text-gray-900 pb-16 md:pb-0">
        <Outlet />
      </div>
    </ConfirmProvider>
  ),
});
