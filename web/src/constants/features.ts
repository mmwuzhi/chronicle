// Ask and webhook delivery both depend on the RAG sidecar, which is not part of
// the default Fly deployment. Keep unavailable production surfaces hidden.
export const RAG_ENABLED =
  import.meta.env.DEV || import.meta.env.VITE_ASK_ENABLED === "true";
