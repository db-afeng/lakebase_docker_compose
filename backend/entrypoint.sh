#!/bin/bash
set -e

MAX_RETRIES=${DB_CONNECT_RETRIES:-10}
RETRY_DELAY=${DB_CONNECT_RETRY_DELAY:-3}

echo "Running database migrations (will retry up to $MAX_RETRIES times)..."
for i in $(seq 1 "$MAX_RETRIES"); do
    if alembic upgrade head; then
        echo "Migrations completed successfully."
        break
    fi
    if [ "$i" -eq "$MAX_RETRIES" ]; then
        echo "ERROR: migrations failed after $MAX_RETRIES attempts." >&2
        exit 1
    fi
    echo "Attempt $i/$MAX_RETRIES failed — retrying in ${RETRY_DELAY}s..."
    sleep "$RETRY_DELAY"
done

echo "Starting Flask..."
exec flask run --host=0.0.0.0 --port=5001 --reload
