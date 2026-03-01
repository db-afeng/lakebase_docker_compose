# Lakebase Branching Demo — To-Do List

A to-do list app demonstrating how Databricks Lakebase branching integrates with the local development workflow via Docker Compose.

## Architecture

| Service  | Tech                       | Port | Role                              |
|----------|----------------------------|------|-----------------------------------|
| Frontend | React 19 + TypeScript      | 5173 | UI with search, filters, toggles  |
| Backend  | Flask (Python)             | 5001 | REST API, write-through to Redis  |
| Database | PostgreSQL 17 or Lakebase  | 5432 | System of record (via Alembic)    |
| Search   | Redis Stack (RediSearch)   | 6379 | Full-text search with prefix match|

### Data flow

- **Writes** (create / update / delete) go to PostgreSQL first; on success the task is synced to Redis.
- **Reads** (task list) query PostgreSQL directly.
- **Search** queries Redis via the RediSearch module for low-latency prefix matching.

### Two database modes

| Mode | Command | Database | Use case |
|------|---------|----------|----------|
| Local | `make dev-local` | PostgreSQL 17 container | Offline development, no Databricks needed |
| Lakebase | `make dev-lakebase` | Ephemeral Lakebase branch | Test against production data, schema migration testing |

In Lakebase mode, the local PostgreSQL container is not started. The backend connects directly to a Lakebase branch that is automatically created from your production data.

## Quick start (local)

```bash
make dev-local
```

Open [http://localhost:5173](http://localhost:5173).

## Quick start (Lakebase)

### Prerequisites

- Databricks CLI >= 0.287.0, authenticated to a Lakebase-enabled workspace
- `jq` and `psql` installed

### First-time setup

```bash
make lakebase-init
```

This creates the Lakebase project `lakebase-docker-compose`, waits for the production endpoint, creates the `tododb` database, and writes the project ID into `lakebase.config`. It is idempotent and safe to re-run.

### Start development

```bash
make dev-lakebase
```

This will:
1. Derive a branch name from your git identity: `dev-{git user.name}-{git branch}` (e.g., `dev-Alex_Feng-feat/add-priority`)
2. Create the Lakebase branch (or reuse it if it already exists)
3. Generate OAuth credentials and write `.env.lakebase`
4. Start Docker Compose with the backend pointing to Lakebase

The backend runs `alembic upgrade head` on startup, so any new migrations in your git branch are applied to the Lakebase branch automatically.

## Makefile targets

| Target | Description |
|--------|-------------|
| `make dev-local` | Start with local PostgreSQL container |
| `make lakebase-init` | One-time: create Lakebase project + database |
| `make dev-lakebase` | Create/reuse Lakebase branch, start app |
| `make dev-down` | Stop Docker Compose (Lakebase branch stays alive) |
| `make dev-destroy` | Stop Compose + delete the current Lakebase branch |
| `make dev-status` | Show current Lakebase branch info |
| `make refresh-token` | Regenerate OAuth token (expires after 1 hour) |

## Schema migrations

Managed by Alembic. Migrations run automatically on container startup.

```bash
# Generate a new migration after changing models.py
docker compose exec backend alembic revision --autogenerate -m "describe change"

# Apply manually
docker compose exec backend alembic upgrade head

# Rollback one step
docker compose exec backend alembic downgrade -1
```

## How Lakebase branching works

Each `make dev-lakebase` creates an isolated database branch from production using copy-on-write storage. This means:

- Branches appear instantly regardless of database size
- You only pay for data that actually changes
- Each developer gets their own isolated copy of production data
- Schema changes (via Alembic) only affect your branch
- Switching git branches connects you to different Lakebase branches

```
production (Lakebase)
├── dev-Alice-feat/add-priority    (has new "priority" column)
├── dev-Alice-feat/fix-search      (no schema changes)
└── dev-Bob-main                   (clean copy of production)
```

## Development

Backend hot-reloads via Flask `--reload`. Frontend uses Vite HMR.

```bash
# Reset everything (local mode)
docker compose down -v && make dev-local

# View logs
docker compose logs -f backend
```
