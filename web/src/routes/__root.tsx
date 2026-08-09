import { createRootRoute, Outlet } from "@tanstack/react-router";
import { ConfirmProvider } from "@/components/confirm-dialog";
import { NotFoundPage } from "@/components/NotFoundPage";

export const Route = createRootRoute({
  notFoundComponent: NotFoundPage,
  component: () => (
    <ConfirmProvider>
      <div className="pb-24 md:pb-0">
        <Outlet />
      </div>
    </ConfirmProvider>
  ),
});
