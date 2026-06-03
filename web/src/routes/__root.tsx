import { createRootRoute, Outlet } from "@tanstack/react-router";
import { ConfirmProvider } from "../components/confirm-dialog";

export const Route = createRootRoute({
  component: () => (
    <ConfirmProvider>
      <div className="pb-24 md:pb-0">
        <Outlet />
      </div>
    </ConfirmProvider>
  ),
});
