// Local-only connectivity check against the Docker container from `npm run db:local:up`.
// Deliberately hardcoded: does not read .env or DATABASE_URL.
import pg from "pg";

const client = new pg.Client({
  host: "localhost",
  port: 5432,
  user: "postgres",
  password: "localonly",
  database: "postgres",
});

try {
  await client.connect();
  const { rows } = await client.query("SELECT version()");
  console.log("Connected to local Postgres:", rows[0].version);
} catch (err) {
  console.error("Local Postgres connection failed:", err.message);
  process.exitCode = 1;
} finally {
  await client.end().catch(() => {});
}
