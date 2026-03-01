# Lakebase Branching Demo — To-Do List

A to-do list app demonstrating local development with Docker Compose, designed to showcase Databricks Lakebase branch-based workflows.

## Architecture

| Service  | Tech                       | Port | Role                              |
|----------|----------------------------|------|-----------------------------------|
| Frontend | React 19 + TypeScript      | 5173 | UI with search, filters, toggles  |
| Backend  | Flask (Python)             | 5001 | REST API, write-through to Redis  |
| Database | PostgreSQL 17              | 5432 | System of record (via Alembic)    |
| Search   | Redis Stack (RediSearch)   | 6379 | Full-text search with prefix match|

### Data flow

- **Writes** (create / update / delete) go to PostgreSQL first; on success the task is synced to Redis.
- **Reads** (task list) query PostgreSQL directly.
- **Search** queries Redis via the RediSearch module for low-latency prefix matching.

## Quick start

```bash
docker compose up --build
```

Open [http://localhost:5173](http://localhost:5173).

## Schema migrations

Managed by Alembic. The entrypoint runs `alembic upgrade head` automatically on startup.

```bash
# Generate a new migration after changing models.py
docker compose exec backend alembic revision --autogenerate -m "describe change"

# Apply manually
docker compose exec backend alembic upgrade head

# Rollback one step
docker compose exec backend alembic downgrade -1
```

## Development

Backend hot-reloads via Flask `--reload`. Frontend uses Vite HMR.

```bash
# Reset everything
docker compose down -v && docker compose up --build

# View logs
docker compose logs -f backend
```
