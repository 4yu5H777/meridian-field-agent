// Manual smoke check of the media readers against the real AI.generate on Lua
// (billed to the agent's organisation; not part of the test suites).
//   node scripts/media-smoke.ts <file> [more files...]
// Each file is sent as its own turn through normalizeTurn, exactly as the
// media-normalizer preprocessor does, and the outcome is printed. Uses the
// Lua CLI login and lua.skill.yaml's agent; no database, no credentials read.
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';
import { AI } from 'lua-cli';
import { normalizeTurn } from '../src/lib/media/normalize.ts';
import { DEFAULT_MEDIA_MODEL, type AiCall } from '../src/lib/media/reader.ts';

const TYPES: Record<string, string> = {
  '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.png': 'image/png', '.pdf': 'application/pdf',
  '.wav': 'audio/wav', '.ogg': 'audio/ogg', '.mp3': 'audio/mpeg', '.csv': 'text/csv',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
};
const ai: AiCall = async (input) => {
  const started = Date.now();
  try {
    return await AI.generate(input as never) as { output?: unknown; finishReason?: string };
  } catch (e) {
    // The reader error, for diagnosis (redacted; the normalizer itself never shows it).
    console.log(`  reader error after ${Date.now() - started} ms: ${String((e as Error)?.message ?? e).replace(/\S+:\/\/\S+/g, '[url]').slice(0, 300)}`);
    throw e;
  }
};

for (const file of process.argv.slice(2)) {
  const mediaType = TYPES[extname(file).toLowerCase()] ?? 'application/octet-stream';
  const data = readFileSync(file).toString('base64');
  const message = mediaType.startsWith('image/') ? { type: 'image', image: data, mediaType } : { type: 'file', data, mediaType };
  const started = Date.now();
  const out = await normalizeTurn({
    messages: [message], ai, model: process.env.MEDIA_MODEL || DEFAULT_MEDIA_MODEL,
    fetchBytes: async () => { throw new Error('no fetch in smoke'); }, aiTimeoutMs: 90_000,
  });
  console.log(`\n=== ${file.split(/[\\/]/).pop()} (${mediaType}) ${Date.now() - started} ms: ${out.log}`);
  console.log(out.action === 'block' ? `BLOCK -> ${out.response}` : `PROCEED ->\n${out.modifiedMessage?.map((m) => m.text).join('\n') ?? '(unchanged)'}`);
}
