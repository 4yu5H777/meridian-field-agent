import { env } from 'lua-cli';
import type { LuaTool } from 'lua-cli';
import { neon } from '@neondatabase/serverless';
import { z } from 'zod';

// Read-only connectivity check against Neon over HTTPS (Neon's HTTP query endpoint via fetch).
// Connects as meridian_agent (AGENT_DATABASE_URL), never the owner. Never returns or logs the URL; any echo of it in an error message is redacted.
export default class NeonPingTool implements LuaTool {
  name = 'neon_ping';
  description = 'Check that the agent can reach the Neon database. Runs SELECT 1 and version() only.';
  inputSchema = z.object({});

  async execute() {
    const url = env('AGENT_DATABASE_URL');
    if (!url) return { ok: false, error: 'AGENT_DATABASE_URL is not set' };

    const started = Date.now();
    try {
      const sql = neon(url);
      const rows = await sql`SELECT 1 AS one, version() AS version`;
      const row = rows[0] as { one: number; version: string };
      return { ok: row.one === 1, version: row.version, latencyMs: Date.now() - started, transport: 'https (neon http driver)' };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      const redacted = message.split(url).join('[AGENT_DATABASE_URL]').replace(/postgres(ql)?:\/\/[^\s'"]+/gi, '[connection string]');
      return { ok: false, error: redacted, errorName: err instanceof Error ? err.name : 'unknown', latencyMs: Date.now() - started };
    }
  }
}
