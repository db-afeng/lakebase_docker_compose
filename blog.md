# Lakebase Branching Meets Docker: The Migration Safety Net I Wish I Had Years Ago

Before I became a Solutions Architect at Databricks, I was a backend software engineer and for a few years of my past life, I found myself BFF's with our BFF(backend-for-frontend) microservice; the service where all our alembic database migrations lived. I knew that codebase back to front. Every model, every relationship, every migration file with my name on it. It was a love-hate relationship: I loved owning a critical piece of the system, and I dreaded that *every single release* seemed to surface another migration issue. A column rename that broke a view nobody remembered existed. A data backfill that timed out against production volumes. A migration that passed locally, passed staging, and then deadlocked against a table with ten million rows and an index nobody had accounted for.

The core problem was never the migration tooling. Alembic worked fine. The problem was that our non-prod databases were *fiction*. We had separate Postgres instances for dev and staging that were technically as old as production, but had drifted significantly over time, littered with artifacts from day-to-day development, half-rolled-back experiments, columns from features that never shipped, and data distributions that looked nothing like what was in prod. A migration would pass against dev, pass against staging, and then fail against production because production was the one environment nobody could safely test against.

Lakebase branching changes this equation entirely. In this post I'll walk through integrating Lakebase into a Docker Compose workflow, not to replace your local Postgres container, but to add a layer of confidence that catches the failures you'd otherwise discover at the worst possible time.

---

## Purpose

This post demonstrates how to plug Databricks Lakebase into an existing Docker-based development workflow with minimal friction. The companion repo ([`lakebase_docker_compose`](https://github.com/alexfeng-db/lakebase_docker_compose)) is a working example you can clone and run today.

By the end you'll have two `make` targets (one for fully offline local development, one that swaps the database container for a Lakebase branch) and you'll understand *why* that second target will save you from migration disasters.

---

## Why Lakebase Branching?

### The Traditional Workflow

If you've worked on any modern backend team, this architecture shouldnt feel too far off:

```
docker-compose.yml
├── frontend        (React / Next.js / etc.)
├── backend         (Flask / Express / Spring)
├── postgres        (local container)
└── redis / memcached / etc.
```

You run `docker compose up`, a fresh Postgres container is created from an empty image, and your entrypoint script runs `alembic upgrade head` (or the equivalent). Every migration is applied sequentially against an empty database. If everything exits cleanly, you declare it working.

Here's what this setup gets right:

- **Fast iteration.** Containers start in seconds.
- **Isolation.** Each developer has their own database. No stepping on each other's data.
- **Portability.** No external dependencies. Works on an airplane.

And here's what it misses:

- **Empty databases lie.** A migration that adds a `NOT NULL` column with no default will succeed on an empty table and fail on a production table with 50 million rows.
- **Data-dependent edge cases are invisible.** Foreign key constraints, unique violations, data type mismatches on existing data — none of these surface until deployment.
- **Staging environments are stale.** If your team maintains a shared staging database, it's perpetually weeks behind production and has its own data drift problems.
- **Reproducing production is expensive.** Managed Postgres offerings like RDS or Azure Database are big, expensive beasts. Spinning up a faithful replica of production — same data, same volume, same indexes — means paying for a second full-size instance, waiting >15 minutes for a snapshot restore, and doing it again every time prod moves forward. It just isn't feasible.

It’s not that our current approach is wrong because of these constraints. These are trade-offs we’ve collectively worked around, largely shaped by how databases have operated over the past decade. Yes, cloud databases have given us more flexibility, but in practice, spinning up replicas is still slow and expensive enough that we’ve had to reserve them for higher-value use cases. We’ve deliberately drawn the line at local development to keep costs under control and maintain a reasonable developer experience. As a result, there's been little choice but to rely on a shared development database and be extremely disciplined in how we manage deployments. That’s meant carefully reviewing migrations, coordinating merge order, testing as thoroughly as possible, and accepting that every so often, something would still break when it hit production.

### The New Workflow: Lakebase Branching

This is where Lakebase truly changes the game. Lakebase is Databricks' managed PostgreSQL-compatible database, and one of its killer features is branching. You can branch a database the same way you branch code instantly, and with copy-on-write storage so branches don't cost you anything extra. The constraints that forced us into shared dev databases and crossed fingers at deployment time simply don't apply anymore:

1. **Creates instantly**, regardless of database size. A 500 GB production database branches in seconds, not hours. No snapshot restores, no waiting.
2. **Costs almost nothing**. Copy-on-write means you only pay for data you actually change on the branch. Read paths serve from the parent's storage —> no duplicated costs.
3. **Contains real production data and schema**. Your migration runs against actual rows, constraints, and indexes, not a drifted dev database or an empty stand-in.
4. **Is completely isolated**. Production is never affected. Writes to the branch never touch are completely isolated from the parent and when you're done, delete the branch and it's gone.

The idea isn't to throw away your local Postgres container. You still want that for offline development, rapid prototyping, and situations where you're iterating on application logic and don't need real data underneath. What Lakebase branching gives you is a **pre-deployment validation step**: before you merge a PR that includes a migration, you run it against a branch of production and confirm it works.

This is the "shift left" that actually matters. You aren't just running your migration against *a* Postgres database, you're running it against *your* Postgres database, with all its data, constraints, and accumulated history.

### What This Saves You

In my backend engineering days, I'd estimate that 30% of our deployment-related incidents were migration failures. The recovery playbook was always the same: roll back the application, manually reverse the migration (praying the `alembic downgrade()` function was correct), figure out what went wrong, fix it, and try again — usually under time pressure with stakeholders watching.

With Lakebase branching in the loop, those failures surface on your laptop, on your branch, days before the PR is merged. The cost of failure drops from "site incident" to "oh, I need to add a default value to this column." That's a categorically different experience.

---

## Step-by-Step: Integrating Lakebase into a Docker Compose Project

Let's walk through the companion repo. It's intentionally simple, to-do list app so the pattern is easy to extract and apply to your own codebase.

### Architecture

| Service  | Tech                      | Port | Role                              |
|----------|---------------------------|------|-----------------------------------|
| Frontend | React 19 + TypeScript     | 5173 | UI with search, filters, CRUD     |
| Backend  | Flask + SQLAlchemy        | 5001 | REST API, Alembic migrations      |
| Database | PostgreSQL 17 or Lakebase | 5432 | System of record                  |
| Cache    | Redis Stack (RediSearch)  | 6379 | Full-text search                  |

The data flow is straightforward: writes go to Postgres (or Lakebase), reads come from Postgres, and search queries hit Redis via the RediSearch module. Alembic manages all schema migrations.

### Project Structure

```
lakebase_docker_compose/
├── docker-compose.yml       # Services: frontend, backend, redis, postgres
├── Makefile                 # dev-local, dev-lakebase, dev-destroy, etc.
├── lakebase.config          # Lakebase project settings (checked into git)
├── .env.lakebase            # Generated credentials (git-ignored)
├── scripts/
│   ├── db_init.sh           # One-time Lakebase project setup
│   └── lakebase-branch.sh   # Branch creation + credential management
├── backend/
│   ├── app.py               # Flask API
│   ├── models.py            # SQLAlchemy models
│   ├── entrypoint.sh        # Runs alembic upgrade head, then starts Flask
│   ├── migrations/
│   │   └── versions/
│   │       └── 0001_create_tasks_table.py
│   └── Dockerfile
└── frontend/
    ├── src/App.tsx
    └── Dockerfile
```

### Step 1: Docker Compose with Dual-Mode Database

The key insight is using Docker Compose **profiles** to make the local Postgres container optional:

```yaml
services:
  postgres:
    image: postgres:17
    profiles: ["local"]          # Only starts when --profile local is used
    environment:
      POSTGRES_DB: tododb
      POSTGRES_USER: appuser
      POSTGRES_PASSWORD: apppassword
    ports:
      - "5432:5432"
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U appuser -d tododb"]
      interval: 5s
      timeout: 3s
      retries: 5

  backend:
    build:
      context: ./backend
    ports:
      - "5001:5001"
    environment:
      DATABASE_URL: ${DATABASE_URL:-postgresql://appuser:apppassword@postgres:5432/tododb}
      DB_SOURCE: ${DB_SOURCE:-local-postgres}
    depends_on:
      postgres:
        condition: service_healthy
        required: false           # Backend starts even if postgres isn't in the profile
      redis:
        condition: service_healthy
```

When you run `make dev-local`, Docker Compose activates the `local` profile and the Postgres container starts alongside everything else. When you run `make dev-lakebase`, the profile isn't activated, the Postgres container stays off, and the backend picks up `DATABASE_URL` from `.env.lakebase` — which points to your Lakebase branch.

The `required: false` on the `depends_on` is what makes this work cleanly. Without it, Docker Compose would error out when the postgres service isn't in the active profile.

### Step 2: Lakebase Configuration

The `lakebase.config` file is checked into git and contains configruations that `make lakebase-init` sets lakebase project up with:

```bash
LAKEBASE_PROJECT_NAME=lakebase-docker-compose
LAKEBASE_PARENT_BRANCH=production
LAKEBASE_DATABASE=tododb
LAKEBASE_PROFILE=DEFAULT
LAKEBASE_PROJECT_ID=<populated by `make lakebase-init`>
```

The `LAKEBASE_PROJECT_ID` is populated by the one-time `make lakebase-init` command. Everything else is set once and shared across the team.

### Step 3: One-Time Initialization

Before any developer can use Lakebase branching, the project needs to exist:

```bash
make lakebase-init
```

The `db_init.sh` script handles:

1. **Creating the Lakebase project** (or detecting it already exists)
2. **Waiting for the production endpoint** to become active
3. **Creating the application database** (`tododb`) via `psql`
4. **Writing the project ID** back to `lakebase.config`

This is idempotent — safe to run multiple times.

### Step 4: Branch Creation Tied to Git Context

This is where it gets interesting. The `lakebase-branch.sh` script derives the Lakebase branch name directly from your git identity:

```bash
GIT_USER=$(git config user.name | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')
GIT_BRANCH=$(git branch --show-current)
LAKEBASE_BRANCH="dev-${GIT_USER}-${GIT_BRANCH}"
```

So if Alice is working on `feat/add-priority`, her Lakebase branch is `dev-alice-feat/add-priority`. Bob on `main` gets `dev-bob-main`. Each developer, each git branch, gets its own isolated copy of production:

```
production (Lakebase)
├── dev-alice-feat/add-priority    (has new "priority" column)
├── dev-alice-fix/search-index     (no schema changes)
└── dev-bob-main                   (clean copy of production)
```

The script is also smart about reuse. If the branch already exists (because you ran `make dev-lakebase` earlier and the TTL hasn't expired), it skips creation and just refreshes the OAuth credentials.

### Step 5: Credential Generation and `.env.lakebase`

After creating the branch, the script generates short-lived OAuth credentials via the Databricks CLI and writes them to `.env.lakebase`:

```bash
DATABASE_URL=postgresql://user%40databricks.com:oauth-token@endpoint.lakebase.databricks.com:5432/tododb?sslmode=require
DB_SOURCE=lakebase/dev-alice-feat/add-priority
LAKEBASE_BRANCH_PATH=projects/lakebase-docker-compose/branches/dev-alice-feat/add-priority
```

This file is in `.gitignore`. Docker Compose picks it up via `--env-file .env.lakebase`, and the backend connects to the Lakebase branch instead of a local container.

### Step 6: Migrations Run Automatically

The backend's `entrypoint.sh` runs `alembic upgrade head` before starting Flask:

```bash
#!/bin/bash
set -e
echo "Running database migrations..."
for i in $(seq 1 "$MAX_RETRIES"); do
    if alembic upgrade head; then
        echo "Migrations completed successfully."
        break
    fi
    echo "Attempt $i/$MAX_RETRIES failed — retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done
echo "Starting Flask..."
exec flask run --host=0.0.0.0 --port=5001 --reload
```

This is unchanged between local and Lakebase modes. The same entrypoint, the same migration tooling, the same Alembic config. The only difference is the `DATABASE_URL` environment variable — one points to `postgres:5432` inside the Docker network, the other points to a Lakebase endpoint over the internet.

That's the entire integration. No changes to application code, no Lakebase SDK, no special migration runner. It's just Postgres.

### Step 7: The Makefile Ties It Together

```makefile
dev-local:                  ## Start with local PostgreSQL container
	docker compose --profile local up --build -d

dev-lakebase:               ## Start with an ephemeral Lakebase branch
	@./scripts/lakebase-branch.sh
	docker compose --env-file .env.lakebase up --build -d

dev-destroy:                ## Stop containers + delete the Lakebase branch
	@# ... deletes branch via databricks CLI, removes .env.lakebase
	docker compose --profile local down
```

Two commands. Same application. Different database backends.

### The Developer Experience

Here's what a typical session looks like:

```bash
# Start working on a new feature
git checkout -b feat/add-priority

# Write your migration
docker compose exec backend alembic revision --autogenerate -m "add priority column"

# Test locally first (fast, offline)
make dev-local

# Happy with the code? Test the migration against real production data.
make dev-lakebase

# The migration runs against a copy of prod. If it fails, you find out now.
# If it succeeds, you have high confidence the production deploy will too.

# Done for the day — clean up
make dev-destroy
```

---

## What This Isn't

I want to be explicit: Lakebase branching is not a replacement for local development databases. Your local Postgres container is still the right tool for:

- **Offline work.** Airplane, coffee shop with bad WiFi, VPN down
- **First-pass development.** When you're sketching out a new feature, you don't need production data. You need speed.

What Lakebase branching adds is a **validation layer between "it works on my machine" and "it works in production."** Think of it as the database equivalent of running integration tests against a realistic environment before merging. Your local Postgres catches syntax errors and logic bugs. Lakebase catches data-dependent failures, constraint violations on real data, and migration ordering issues that only manifest at scale.

Used together, you get the speed of local development *and* the confidence of testing against production.

---

## Conclusion

After watching migrations fail across deployments from dev all the way up to prod, Lakebase branching feels like the missing piece.

The integration is lightweight: a config file, a shell script, a profile flag in Docker Compose. No changes to your application code, your ORM, or your migration tooling. You keep your local Postgres container for fast, offline development. You add Lakebase branching for the moment before you merge, when you need to answer the question: *will this migration actually work against production?*

That answer used to cost us a deployment slot, a maintenance window, and sometimes a 2 AM incident. Now it costs a `make` command and sixty seconds.

And unlike replicating a database on RDS or Azure where you're waiting on snapshot restores and paying for a full duplicate instance, Lakebase branches are near-instant and use copy-on-write storage, so you only pay for the data you actually change. Every developer on the team can have their own branch of production running simultaneously without multiplying your database bill. That's the part that makes this practical rather than theoretical: the economics and speed make it something you actually use on every PR, not something you reserve for quarterly release candidates.

### Learn More

If Lakebase branching is interesting to you, there's a lot more to explore beyond what this post covers:

- [Databricks Lakebase Documentation](https://docs.databricks.com/en/lakebase/index.html) — full feature overview, including managed endpoints, auto-scaling, and Unity Catalog integration
- [Lakebase Branching Guide](https://docs.databricks.com/en/lakebase/branch.html) — deep dive into branch creation, TTLs, and copy-on-write semantics
- [Databricks CLI Reference](https://docs.databricks.com/en/dev-tools/cli/postgres-commands.html) — all the `databricks postgres` commands used in this post

The companion repo is available at [github.com/alexfeng-db/lakebase_docker_compose](https://github.com/alexfeng-db/lakebase_docker_compose). Clone it, swap in your own Databricks workspace, and try it against your own stack.
