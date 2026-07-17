import type { InfiniteData, QueryClient } from "@tanstack/react-query";
import {
  getListCapturePageInfiniteQueryKey,
  type CaptureAttachmentBody,
  type CaptureBody,
  type CapturePageBody,
  type ListCapturePageParams,
} from "@/api";

// In-place updates for the cached /captures/page infinite lists, so single-item
// mutations (edit, todo, remind, transcription progress) don't invalidate and
// serially refetch every loaded page. Each cached variant is keyed by its list
// params; membership is re-evaluated against a client-side mirror of the SQL
// filter, so an item that stops matching a filtered variant (e.g. a completed
// todo on the todo=open tab) is removed instead of lingering with stale state.

type CapturePages = InfiniteData<CapturePageBody>;

// Mirror of the ListCapturePage SQL predicate (todo facet + reminder hiding).
// Cursor/limit don't affect membership.
export function captureMatchesPageParams(
  capture: CaptureBody,
  params: ListCapturePageParams | undefined,
  now: Date = new Date(),
): boolean {
  if (params?.todo === "open" && !(capture.todoAt && !capture.doneAt)) {
    return false;
  }
  if (params?.todo === "done" && !capture.doneAt) {
    return false;
  }
  if (
    !params?.includeReminded &&
    capture.remindAt &&
    capture.remindHide &&
    new Date(capture.remindAt) > now
  ) {
    return false;
  }
  return true;
}

// Mutation responses carry attachments: null (only the page listing populates
// them) — merging keeps the attachments already shown in the list.
function mergeAttachments(next: CaptureBody, prev: CaptureBody): CaptureBody {
  return next.attachments ? next : { ...next, attachments: prev.attachments };
}

export function patchCapturePages(
  data: CapturePages,
  capture: CaptureBody,
  params: ListCapturePageParams | undefined,
): CapturePages {
  const matches = captureMatchesPageParams(capture, params);
  return {
    ...data,
    pages: data.pages.map((page) => ({
      ...page,
      items: (page.items ?? []).flatMap((item) => {
        if (item.id !== capture.id) return [item];
        return matches ? [mergeAttachments(capture, item)] : [];
      }),
    })),
  };
}

export function prependCaptureToPagesData(
  data: CapturePages,
  capture: CaptureBody,
  params: ListCapturePageParams | undefined,
): CapturePages {
  if (data.pages.length === 0 || !captureMatchesPageParams(capture, params)) {
    return data;
  }
  const [first, ...rest] = data.pages;
  return {
    ...data,
    pages: [{ ...first, items: [capture, ...(first.items ?? [])] }, ...rest],
  };
}

export function removeCaptureFromPagesData(
  data: CapturePages,
  id: string,
): CapturePages {
  return {
    ...data,
    pages: data.pages.map((page) => ({
      ...page,
      items: (page.items ?? []).filter((item) => item.id !== id),
    })),
  };
}

function updatePageVariants(
  queryClient: QueryClient,
  update: (
    data: CapturePages,
    params: ListCapturePageParams | undefined,
  ) => CapturePages,
): void {
  const baseKey = getListCapturePageInfiniteQueryKey();
  for (const [key, data] of queryClient.getQueriesData<CapturePages>({
    queryKey: baseKey,
  })) {
    if (!data) continue;
    const params = key[2] as ListCapturePageParams | undefined;
    queryClient.setQueryData(key, update(data, params));
  }
  // Patched variants stay consistent locally; marking everything stale (without
  // refetching) lets background variants reconcile server-side membership (e.g.
  // an item newly entering a filtered tab) on their next mount.
  void queryClient.invalidateQueries({
    queryKey: baseKey,
    refetchType: "none",
  });
}

export function patchCaptureInPages(
  queryClient: QueryClient,
  capture: CaptureBody,
): void {
  updatePageVariants(queryClient, (data, params) =>
    patchCapturePages(data, capture, params),
  );
}

export function prependCaptureToPages(
  queryClient: QueryClient,
  capture: CaptureBody,
): void {
  updatePageVariants(queryClient, (data, params) =>
    prependCaptureToPagesData(data, capture, params),
  );
}

export function removeCaptureFromPages(
  queryClient: QueryClient,
  id: string,
): void {
  updatePageVariants(queryClient, (data) =>
    removeCaptureFromPagesData(data, id),
  );
}

export function appendAttachmentInPages(
  queryClient: QueryClient,
  captureId: string,
  attachment: CaptureAttachmentBody,
): void {
  updatePageVariants(queryClient, (data) => ({
    ...data,
    pages: data.pages.map((page) => ({
      ...page,
      items: (page.items ?? []).map((item) =>
        item.id === captureId
          ? { ...item, attachments: [attachment, ...(item.attachments ?? [])] }
          : item,
      ),
    })),
  }));
}
