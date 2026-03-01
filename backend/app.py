import logging
import os
import time
from datetime import datetime, timezone

import redis
from flask import Flask, jsonify, request
from flask_cors import CORS

from models import Task, db
from search import ensure_index, remove_task, search_tasks, sync_all_tasks, upsert_task

logger = logging.getLogger(__name__)

DB_CONNECT_MAX_RETRIES = int(os.environ.get("DB_CONNECT_RETRIES", "10"))
DB_CONNECT_RETRY_DELAY = int(os.environ.get("DB_CONNECT_RETRY_DELAY", "3"))

app = Flask(__name__)
CORS(app)

app.config["SQLALCHEMY_DATABASE_URI"] = os.environ.get(
    "DATABASE_URL", "postgresql://appuser:apppassword@localhost:5432/tododb"
)
app.config["SQLALCHEMY_TRACK_MODIFICATIONS"] = False
app.config["SQLALCHEMY_ENGINE_OPTIONS"] = {
    "pool_pre_ping": True,
}

db.init_app(app)
cache = redis.from_url(os.environ.get("REDIS_URL", "redis://localhost:6379/0"))

with app.app_context():
    ensure_index(cache)
    for _attempt in range(1, DB_CONNECT_MAX_RETRIES + 1):
        try:
            tasks = Task.query.all()
            if tasks:
                sync_all_tasks(cache, tasks)
            break
        except Exception:
            if _attempt == DB_CONNECT_MAX_RETRIES:
                logger.error("Failed to connect to database after %d attempts", DB_CONNECT_MAX_RETRIES)
                raise
            logger.warning(
                "Database not ready (attempt %d/%d) — retrying in %ds...",
                _attempt, DB_CONNECT_MAX_RETRIES, DB_CONNECT_RETRY_DELAY,
            )
            time.sleep(DB_CONNECT_RETRY_DELAY)


# ---------------------------------------------------------------------------
# Health / Info
# ---------------------------------------------------------------------------


@app.route("/api/health")
def health():
    pg_ok = False
    redis_ok = False
    try:
        db.session.execute(db.text("SELECT 1"))
        pg_ok = True
    except Exception:
        pass
    try:
        cache.ping()
        redis_ok = True
    except Exception:
        pass
    return jsonify({"postgres": pg_ok, "redis": redis_ok})


@app.route("/api/info")
def info():
    db_url = app.config["SQLALCHEMY_DATABASE_URI"]
    host = db_url.split("@")[1].split("/")[0] if "@" in db_url else "unknown"
    db_name = db_url.rsplit("/", 1)[-1]
    return jsonify(
        {
            "db_source": os.environ.get("DB_SOURCE", "unknown"),
            "db_host": host,
            "db_name": db_name,
        }
    )


# ---------------------------------------------------------------------------
# Task CRUD  (source of truth: PostgreSQL)
# ---------------------------------------------------------------------------


@app.route("/api/tasks", methods=["GET"])
def list_tasks():
    tasks = Task.query.order_by(Task.created_at.desc()).all()
    return jsonify({"tasks": [t.to_dict() for t in tasks], "source": "postgres"})


@app.route("/api/tasks", methods=["POST"])
def create_task():
    data = request.get_json()
    if not data or not data.get("title"):
        return jsonify({"error": "title is required"}), 400

    task = Task(
        title=data["title"],
        description=data.get("description", ""),
    )
    db.session.add(task)
    db.session.commit()

    try:
        upsert_task(cache, task)
    except Exception:
        pass

    return jsonify(task.to_dict()), 201


@app.route("/api/tasks/<task_id>", methods=["PUT"])
def update_task(task_id):
    task = db.session.get(Task, task_id)
    if not task:
        return jsonify({"error": "not found"}), 404

    data = request.get_json()
    if "title" in data:
        task.title = data["title"]
    if "description" in data:
        task.description = data["description"]
    if "status" in data:
        task.status = data["status"]

    task.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    try:
        upsert_task(cache, task)
    except Exception:
        pass

    return jsonify(task.to_dict())


@app.route("/api/tasks/<task_id>/toggle", methods=["PATCH"])
def toggle_task(task_id):
    task = db.session.get(Task, task_id)
    if not task:
        return jsonify({"error": "not found"}), 404

    task.status = "completed" if task.status == "pending" else "pending"
    task.updated_at = datetime.now(timezone.utc)
    db.session.commit()

    try:
        upsert_task(cache, task)
    except Exception:
        pass

    return jsonify(task.to_dict())


@app.route("/api/tasks/<task_id>", methods=["DELETE"])
def delete_task(task_id):
    task = db.session.get(Task, task_id)
    if not task:
        return jsonify({"error": "not found"}), 404

    db.session.delete(task)
    db.session.commit()

    try:
        remove_task(cache, task_id)
    except Exception:
        pass

    return "", 204


# ---------------------------------------------------------------------------
# Search  (source: Redis)
# ---------------------------------------------------------------------------


@app.route("/api/tasks/search")
def search():
    q = request.args.get("q", "").strip()
    if not q:
        return jsonify({"tasks": [], "source": "redis"})

    try:
        results = search_tasks(cache, q)
    except Exception:
        results = []

    return jsonify({"tasks": results, "source": "redis"})
