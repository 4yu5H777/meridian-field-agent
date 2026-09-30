// Runs one or more SQL files against the database.
//
//   node --env-file=.env.owner scripts/db.mjs db/schema.sql db/seed.sql    (owner: DATABASE_URL)
//   node --env-file=.env scripts/db.mjs --as agent db/checks-agent.sql     (AGENT_DATABASE_URL)
//
// --as <agent|system|readonly> connects as that restricted role, using the
// connection string scripts/set-db-logins.mjs wrote to .env.
//
// Uses `pg` over TCP (not the Neon HTTP driver) because these files contain many
// statements and DO blocks; the HTTP driver runs one statement per request.
// The connection string is read from the environment only. It is never printed,
// and it is redacted from any error text before that text is shown.
import { readFileSync } from "node:fs";
import pg from "pg";

const args = process.argv.slice(2);
let envVar = "DATABASE_URL";
if (args[0] === "--as") {
  if (!["agent", "system", "readonly"].includes(args[1])) {
    console.error("usage: scripts/db.mjs --as <agent|system|readonly> <file.sql>...");
    process.exit(1);
  }
  envVar = `${args[1].toUpperCase()}_DATABASE_URL`;
  args.splice(0, 2);
}

const url = process.env[envVar];
if (!url) {
  console.error(`${envVar} is not set (run with: node --env-file=${["DATABASE_URL", "READONLY_DATABASE_URL"].includes(envVar) ? ".env.owner" : ".env"} scripts/db.mjs ...)`);
  process.exit(1);
}
const redact = (s) =>
  String(s).split(url).join(`[${envVar}]`).replace(/postgres(ql)?:\/\/\S+/gi, "[connection string]");

const files = args;
if (files.length === 0) {
  console.error("usage: scripts/db.mjs [--as <agent|system|readonly>] <file.sql> [more.sql ...]");
  process.exit(1);
}

// sslmode=verify-full is what pg does today for 'require'; saying so explicitly silences its warning.
const connectionString = url.replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full");
const client = new pg.Client({ connectionString });

// RAISE NOTICE output from DO blocks (guard tests use this) is shown as it arrives.
client.on("notice", (n) => console.log(`  ${n.message}`));

try {
  await client.connect();
  const { rows: [who] } = await client.query("SELECT session_user AS login");
  for (const file of files) {
    console.log(`\n=== ${file} (as ${who.login}) ===`);
    const results = await client.query(readFileSync(file, "utf8"));
    // A multi-statement file returns an array of results; print every SELECT/EXPLAIN that returned rows.
    for (const r of [results].flat()) {
      if (r.command === "EXPLAIN") console.log(r.rows.map((row) => row["QUERY PLAN"]).join("\n"));
      else if (r.command === "SELECT" && r.rows.length > 0) console.table(r.rows);
    }
  }
} catch (err) {
  console.error("SQL error:", redact(err.message));
  if (err.where) console.error("  where:", redact(err.where));
  process.exitCode = 1;
} finally {
  await client.end().catch(() => {});
}
