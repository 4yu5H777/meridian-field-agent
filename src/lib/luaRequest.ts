import { Lua } from 'lua-cli';
import type { InvokedState } from './confirmation.ts';

// Readers for the parts of Lua.request that decide who is talking, for the
// prepare_order tool and the summary-integrity postprocessor. (The
// confirmation gate has its own copies and is deliberately unchanged.)
// Anything that cannot be read counts as unknown, which never identifies a rep.

export function readInvoked(): InvokedState {
  try {
    // invokedBy is newer than the lua-cli 3.39.4 types, so read it untyped.
    const request = (Lua as unknown as { request?: Record<string, unknown> } | undefined)?.request;
    if (!request) return 'unknown';
    return request.invokedBy === undefined || request.invokedBy === null ? 'no' : 'yes';
  } catch {
    return 'unknown';
  }
}

export function readRequestChannel(): string | undefined {
  try {
    const channel = (Lua as unknown as { request?: { channel?: unknown } } | undefined)?.request?.channel;
    return typeof channel === 'string' ? channel : undefined;
  } catch {
    return undefined;
  }
}
