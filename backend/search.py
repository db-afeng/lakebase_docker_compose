"""Redis-powered full-text search for tasks using the RediSearch module."""

from redis.commands.search.field import TagField, TextField
from redis.commands.search.indexDefinition import IndexDefinition, IndexType
from redis.commands.search.query import Query

INDEX_NAME = "idx:tasks"
PREFIX = "task:"

_SPECIAL_CHARS = r"@!{}()|\-=>[]\;:'\",.<>~#$%^&*+"


def _escape(text: str) -> str:
    for ch in _SPECIAL_CHARS:
        text = text.replace(ch, f"\\{ch}")
    return text


def ensure_index(r):
    """Create the RediSearch index if it doesn't already exist."""
    try:
        r.ft(INDEX_NAME).info()
    except Exception:
        schema = (
            TextField("title", weight=2.0),
            TextField("description"),
            TagField("status"),
        )
        definition = IndexDefinition(prefix=[PREFIX], index_type=IndexType.HASH)
        r.ft(INDEX_NAME).create_index(schema, definition=definition)


def upsert_task(r, task):
    """Write-through: store task as a Redis hash so the index picks it up."""
    key = f"{PREFIX}{task.id}"
    r.hset(
        key,
        mapping={
            "title": task.title,
            "description": task.description or "",
            "status": task.status,
            "created_at": task.created_at.isoformat(),
            "updated_at": task.updated_at.isoformat(),
        },
    )


def remove_task(r, task_id: str):
    r.delete(f"{PREFIX}{task_id}")


def search_tasks(r, query_str: str, limit: int = 50):
    """
    Search tasks via RediSearch with prefix matching.
    Each whitespace-separated token gets a trailing wildcard so "gro" matches "groceries".
    """
    tokens = query_str.strip().split()
    if not tokens:
        return []

    parts = [f"{_escape(t)}*" for t in tokens if len(t) >= 1]
    if not parts:
        return []

    q = (
        Query(" ".join(parts))
        .return_fields("title", "description", "status", "created_at", "updated_at")
        .paging(0, limit)
    )
    results = r.ft(INDEX_NAME).search(q)

    tasks = []
    for doc in results.docs:
        tasks.append(
            {
                "id": doc.id.replace(PREFIX, ""),
                "title": doc.title,
                "description": getattr(doc, "description", ""),
                "status": doc.status,
                "created_at": doc.created_at,
                "updated_at": doc.updated_at,
            }
        )
    return tasks


def sync_all_tasks(r, tasks):
    """Bulk-sync every Postgres task into Redis (used on startup)."""
    pipe = r.pipeline()
    for task in tasks:
        key = f"{PREFIX}{task.id}"
        pipe.hset(
            key,
            mapping={
                "title": task.title,
                "description": task.description or "",
                "status": task.status,
                "created_at": task.created_at.isoformat(),
                "updated_at": task.updated_at.isoformat(),
            },
        )
    pipe.execute()
