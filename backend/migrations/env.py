import logging
import os
import sys
import time
from logging.config import fileConfig

from alembic import context
from sqlalchemy import create_engine

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

config = context.config
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

from models import db

logger = logging.getLogger(__name__)
target_metadata = db.metadata

MAX_RETRIES = int(os.environ.get("DB_CONNECT_RETRIES", "10"))
RETRY_DELAY = int(os.environ.get("DB_CONNECT_RETRY_DELAY", "3"))


def get_url():
    return os.environ.get(
        "DATABASE_URL", "postgresql://appuser:apppassword@localhost:5432/tododb"
    )


def run_migrations_offline():
    context.configure(url=get_url(), target_metadata=target_metadata, literal_binds=True)
    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online():
    connectable = create_engine(get_url(), pool_pre_ping=True)
    for attempt in range(1, MAX_RETRIES + 1):
        try:
            with connectable.connect() as connection:
                context.configure(connection=connection, target_metadata=target_metadata)
                with context.begin_transaction():
                    context.run_migrations()
            return
        except Exception:
            if attempt == MAX_RETRIES:
                raise
            logger.warning(
                "Migration DB connect failed (attempt %d/%d) — retrying in %ds...",
                attempt, MAX_RETRIES, RETRY_DELAY,
            )
            time.sleep(RETRY_DELAY)


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
