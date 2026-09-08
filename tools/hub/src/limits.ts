/** Shared byte ceilings. Kept out of `lan-server.ts` so `tools.ts` can reuse them without pulling in the HTTPS server. */

/** Bodies (and imported files) above this are refused rather than buffered. */
export const MAX_BODY = 20 * 1024 * 1024;
/** `/pair` is unauthenticated, so its budget is far smaller than `/sync`'s. */
export const MAX_PAIR_BODY = 8 * 1024;
