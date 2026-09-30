// Enables login for the restricted Meridian roles with fresh random passwords
// and writes their connection strings to .env. Nothing secret is printed.
//
//   node --env-file=.env.owner scripts/set-db-logins.mjs
//
// Run after db/roles.sql. Re-running rotates all three passwords.
//
//   meridian_agent     -> AGENT_DATABASE_URL
//   meridian_system    -> SYSTEM_DATABASE_URL
//   meridian_readonly  -> READONLY_DATABASE_URL
//
// Neon's control plane intercepts ALTER ROLE ... PASSWORD and accepts only a
// plaintext password (a pre-hashed SCRAM verifier is refused with "Neon only
// supports being given plaintext passwords"), so the password is sent as a
// literal over the TLS connection. Afterwards the script checks that
// pg_stat_statements (if installed) did not keep the literal, printing only a
// count. The connection strings reuse DATABASE_URL's host, database and options
// with the new role's name and password.
import { randomBytes } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import pg from "pg";

const ownerUrl = process.env.DATABASE_URL;
if (!ownerUrl) {
  console.error("DATABASE_URL is not set (run with: node --env-file=.env.owner scripts/set-db-logins.mjs)");
  process.exit(1);
}
const redact = (s) => String(s).replace(/postgres(ql)?:\/\/\S+/gi, "[connection string]");
// Same TLS setting as scripts/db.mjs.
const tls = (u) => u.replace(/sslmode=(require|prefer|verify-ca)/, "sslmode=verify-full");

const LOGINS = [
  ["meridian_agent", "AGENT_DATABASE_URL"],
  ["meridian_system", "SYSTEM_DATABASE_URL"],
  ["meridian_readonly", "READONLY_DATABASE_URL"],
];

const owner = new pg.Client({ connectionString: tls(ownerUrl) });
const newUrls = {};
const passwords = [];
try {
  await owner.connect();
  for (const [role, envKey] of LOGINS) {
    const password = randomBytes(24).toString("base64url"); // 32 URL-safe characters
    passwords.push(password);
    await owner.query(
      `ALTER ROLE ${owner.escapeIdentifier(role)} WITH LOGIN PASSWORD ${owner.escapeLiteral(password)}`,
    );
    const u = new URL(ownerUrl);
    u.username = role;
    u.password = password;
    newUrls[envKey] = u.toString();
    console.log(`login enabled: ${role}`);
  }

  // Did pg_stat_statements keep a password literal? Count only; never print text.
  const { rows: [ext] } = await owner.query(
    "SELECT to_regclass('pg_stat_statements') IS NOT NULL AS installed");
  if (ext.installed) {
    const { rows: [hit] } = await owner.query(
      "SELECT count(*)::int AS n FROM pg_stat_statements WHERE query LIKE ANY ($1)",
      [passwords.map((p) => `%${p}%`)]);
    console.log(`pg_stat_statements entries containing a new password: ${hit.n}`);
  } else {
    console.log("pg_stat_statements is not installed in this database");
  }
} catch (err) {
  let msg = redact(err.message);
  for (const p of passwords) msg = msg.split(p).join("[password]");
  console.error("failed:", msg);
  process.exit(1);
} finally {
  await owner.end().catch(() => {});
}

// Replace (or add) only these three keys in .env; every other line is kept as is.
const text = readFileSync(".env", "utf8");
const eol = text.includes("\r\n") ? "\r\n" : "\n";
const keys = Object.keys(newUrls);
const kept = text.split(/\r?\n/).filter((line) => !keys.some((k) => line.startsWith(`${k}=`)));
while (kept.length && kept[kept.length - 1] === "") kept.pop();
writeFileSync(".env", [...kept, ...keys.map((k) => `${k}=${newUrls[k]}`)].join(eol) + eol);
console.log(`wrote ${keys.join(", ")} to .env`);

// Prove each new login works and holds no elevated attributes.
for (const [role, envKey] of LOGINS) {
  const c = new pg.Client({ connectionString: tls(newUrls[envKey]) });
  try {
    await c.connect();
    const { rows: [r] } = await c.query(
      `SELECT session_user AS login, rolsuper, rolbypassrls, rolcreaterole, rolcreatedb
         FROM pg_roles WHERE rolname = session_user`,
    );
    const elevated = r.rolsuper || r.rolbypassrls || r.rolcreaterole || r.rolcreatedb;
    console.log(`connected as ${r.login}: ${elevated ? "ELEVATED ATTRIBUTES - STOP" : "no elevated attributes"}`);
    if (elevated) process.exitCode = 1;
  } catch (err) {
    console.error(`could not connect as ${role}:`, redact(err.message));
    process.exitCode = 1;
  } finally {
    await c.end().catch(() => {});
  }
}
