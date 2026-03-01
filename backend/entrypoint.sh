#!/bin/bash
set -e

echo "Running database migrations..."
alembic upgrade head

echo "Starting Flask..."
exec flask run --host=0.0.0.0 --port=5001 --reload
