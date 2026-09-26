# keeplix

S3-compatible object storage built with Phoenix + LiveView.

- S3 API in path style (`/:bucket/*key`) with **AWS Signature V4** (header + presigned URLs)
- Buckets + objects on the filesystem (`DATA_DIR`); accounts, buckets,
  grants, keys, audit trail and object metadata (ETag, size, content
  type) in SQLite (via Ecto); file content stays on disk
- Web UI: bucket browser, access keys, admin for users / groups / buckets / grants
- Roles: `admin` vs. `user`; bucket permissions: `read` / `write` / `admin` per user or group
- OIDC integration (e.g. authentik) via discovery + authorization code flow
- Replication: **disabled** in v0.1, `Keeplix.Replication` interface reserved for later push/pull

## Quickstart

```bash
cd keeplix
mix setup
mix phx.server
```

Admin seed via env (`ADMIN_PASSWORD` has no default — if omitted, a random
password is generated and printed; known-breached passwords are rejected):

```bash
ADMIN_PASSWORD=$(openssl rand -base64 24) ADMIN_USERNAME=admin mix ecto.setup
```

Web: <http://localhost:4000/app> (redirect from `/`), login at `/login`.

## Using S3

Endpoint: `http://localhost:4000` (path style). Create keys under `/app/keys`.

```bash
export AWS_ACCESS_KEY_ID=KB...
export AWS_SECRET_ACCESS_KEY=...
aws --endpoint-url http://localhost:4000 --region us-east-1 s3 mb s3://my-bucket
aws --endpoint-url http://localhost:4000 --region us-east-1 s3 cp file.txt s3://my-bucket/
aws --endpoint-url http://localhost:4000 --region us-east-1 s3 ls s3://my-bucket/
```

Supported: `ListBuckets`, `CreateBucket`, `DeleteBucket`, `HeadBucket`,
`ListObjectsV1/V2`, `PutObject`, `GetObject` (incl. ranges), `HeadObject`,
`DeleteObject`, `DeleteObjects`, multipart (`Create/UploadPart/Complete/Abort/ListParts`).

Notes on S3 semantics:

- Keys ending in `/` are folder markers (real 0-byte objects): they show
  up as `CommonPrefixes` in delimited listings and can be read/deleted.
- A key colliding with an existing file/directory (e.g. `a` as file plus
  `a/b`) is rejected with `400 InvalidRequest` instead of full S3
  coexistence — true same-name file+folder pairs are not supported.
- SSO account linking is strictly bound to the IdP subject (`sub`); a
  matching local username alone never links accounts (returns an error
  instead of taking over).

## Configuration (env)

| Variable | Meaning |
|---|---|
| `PORT` | HTTP port (default 4000) |
| `DATA_DIR` | Storage path (default `./data`) |
| `MAX_OBJECT_BYTES` | Max single-object size (default 5368709312 = 5 GiB) |
| `DATABASE_PATH` (prod) | SQLite file |
| `SECRET_KEY_BASE` (prod) | Phoenix secret |
| `ACCESS_KEY_ENCRYPTION_KEY` (prod) | Base64, 32 bytes: `openssl rand -base64 32`. Encrypts S3 secrets at rest. Rotate with `mix keeplix.reencrypt_keys` (see `OLD_ACCESS_KEY_ENCRYPTION_KEY`) |
| `ADMIN_USERNAME` / `ADMIN_PASSWORD` | Seed admin (no default password) |
| `OIDC_ENABLED=1` | Enable SSO |
| `OIDC_ISSUER` | e.g. `https://auth.example.com/application/o/keeplix/` |
| `OIDC_CLIENT_ID` / `OIDC_CLIENT_SECRET` | Client credentials |
| `OIDC_REDIRECT_URI` | e.g. `https://files.example.com/auth/oidc/callback` |
| `OIDC_FIRST_ADMIN=1` | Allow the very first OIDC user to become admin (default: off — seed the admin explicitly) |
| `OIDC_ADMIN_GROUPS` | Comma-separated IdP groups whose members are promoted to admin (promote-only) |
| `SESSION_ABSOLUTE_SECONDS` / `SESSION_IDLE_SECONDS` | Session lifetimes (defaults: 12h absolute, 30m idle) |
| `TRUSTED_PROXIES` | Comma-separated IPs/CIDRs trusted for `X-Forwarded-For` client detection (default: loopback). Set when running behind a reverse proxy, otherwise all clients share one rate-limit bucket |

OIDC groups from the `groups` claim are automatically created as local groups and mapped.

## Two-factor authentication (optional)

- Passkeys (WebAuthn/FIDO2) per user under `/app/profile`: platform
  authenticators and security keys supported, multiple keys per account
  with rename/remove.
- One-time backup codes (shown once) as fallback; regeneration
  invalidates old codes. Losing everything? An admin can remove a
  user's two-factor methods under `/admin/users` (audited).
- Applies to password logins only; SSO logins rely on the identity
  provider. The second step is rate-limited like password attempts.
- Origins matter: passkeys are bound to the public base URL, so set
  `PHX_HOST` (and port) correctly — otherwise registration and login
  ceremonies fail signature checks.

## Security notes

- New passwords are checked against HaveIBeenPwned (k-anonymity, SHA-1
  prefix only). Unreachable API fails open with a warning; disable with
  `config :keeplix, Keeplix.PasswordBreach, enabled: false`.
- Object downloads carry `Content-Security-Policy: sandbox` + `nosniff`;
  HTML pages carry a same-origin CSP. Sign-out uses `DELETE /logout`
  (`GET` returns 405).
- Failed/successful logins and throttling events land in the audit log.
- Streaming SigV4 chunk signatures are decoded and re-verified, so
  **TLS termination in front of the app is mandatory** — plain HTTP
  leaves chunk payloads open to on-path modification.

## Production checklist

- Terminate TLS in front of the app (the S3 API speaks plain HTTP itself).
- Set `SECRET_KEY_BASE`, `DATABASE_PATH`, `ACCESS_KEY_ENCRYPTION_KEY`, `PHX_HOST`.
- Seed the admin explicitly (see above).
- Health probe: unauthenticated `GET /health` (200 `{"status":"ok"}`, 503
  when the database is unreachable).
- Docker: `docker build -t keeplix .` then run with env file and volumes
  for `DATABASE_PATH` and `DATA_DIR`. CI (format, warnings-as-errors, tests)
  runs on every push via GitHub Actions.

## Permissions

- Admins see/change everything, can delete users/groups/buckets and manage grants (`/admin/...`).
- Regular users only see owned/shared buckets (`/app`).
- S3 requests are additionally authorized per bucket (owner = admin right).
- Bucket quotas (MB, unlimited by default) are set per bucket under `/admin/buckets`;
  the global per-object limit defaults to 5 GiB (`MAX_OBJECT_BYTES`).

## Sharing & audit

- Any object can be shared from the browser via time-limited presigned links
  (1 hour / 1 day / 7 days). Links are bound to your access key: deleting or
  rotating the key kills them. Serving links requires a correct `PHX_HOST`.
- Admin actions (users, keys, grants, buckets, quotas) land in the audit log
  (`/admin/audit`, latest 100).

## Production checklist

- Terminate TLS in front of the app (the S3 API speaks plain HTTP itself).
- Set `SECRET_KEY_BASE`, `DATABASE_PATH`, `ACCESS_KEY_ENCRYPTION_KEY`, `PHX_HOST`.
- Seed the admin explicitly: `ADMIN_USERNAME` / `ADMIN_PASSWORD`
  (otherwise a random password is generated once and printed).
- **Backup**: stop writes or accept a fuzzy copy; back up `DATABASE_PATH`
  (SQLite, including `-wal`/`-shm` sidecars or a `VACUUM INTO` snapshot)
  together with `DATA_DIR` (objects, meta sidecars, `__multipart__`).
  Restore both from the same point in time — the DB references object files.
- **Key rotation**: deploy a new `ACCESS_KEY_ENCRYPTION_KEY`, then run
  `OLD_ACCESS_KEY_ENCRYPTION_KEY=<old> mix keeplix.reencrypt_keys`.
- **Housekeeping**: `mix keeplix.gc_multiparts` removes abandoned multipart
  uploads (also triggered opportunistically on upload start).
- **Usage counters**: per-bucket `usage_bytes`/`object_count` are maintained
  incrementally. After upgrading, backfill once with
  `mix keeplix.rescan_usage` (also repairs drift).
- **Metadata upgrade**: object metadata moved from `.keeplix-meta`
  sidecars to the database. After migrating, run
  `mix keeplix.rescan_usage` once to adopt legacy files and drop stale
  sidecars.

## Replication (outlook)

`lib/keeplix/replication.ex` defines `push/3` + `pull/2` as a behaviour plus
`mode: :none | :push | :pull | :bidirectional`. Currently `{:error, :not_configured}` –
so directed sync setups can be added later without changing the core model.

## Development

```bash
mix precommit
mix test
```

Static analysis (needs a one-time PLT build, then fast):

```bash
mix dialyzer
```
