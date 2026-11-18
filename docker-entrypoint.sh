#!/usr/bin/env bash
# AccOps container entrypoint: Xvfb + backend + frontend dev server.
set -eo pipefail

BACKEND_PORT="${GAM_PORT:-17893}"
FRONTEND_PORT="${VITE_DEV_PORT:-17894}"

export DISPLAY=:99
export VITE_DEV_PROXY_TARGET="http://127.0.0.1:${BACKEND_PORT}"

# Vite also reads .env files, so write the proxy target/port there too.
printf 'VITE_DEV_PROXY_TARGET=http://127.0.0.1:%s\nVITE_DEV_PORT=%s\n' \
  "$BACKEND_PORT" "$FRONTEND_PORT" > /app/frontend/.env

# Virtual display for headed Chrome (Google login blocks headless)
Xvfb :99 -screen 0 1920x1080x24 >/tmp/xvfb.log 2>&1 &
echo "Xvfb pid $!"

# Fresh-database bootstrap (upstream migrations assume a pre-existing
# database: the "initial" migration only DROPs legacy tables/columns and
# every later migration drops/adds columns that a fresh DB never had,
# so `alembic upgrade head` dies on an empty database with
# `table "invite_results" does not exist`. The ORM metadata already
# describes the exact post-migration schema — including all indexes —
# so on a database with no alembic_version table we create the schema
# from the models and stamp the chain at head. Existing databases are
# untouched; the app's own run_migrations() still applies future
# upstream migrations on top.)
cd /app/backend
uv run --no-sync python - <<'PYEOF' 2>&1 | tee -a /tmp/accops-bootstrap.log
import os
from sqlalchemy import inspect
from alembic import command
from alembic.config import Config
import models.database as db
from models.orm import Base

if not inspect(db.engine).has_table('alembic_version'):
    print('[bootstrap] fresh database: creating schema from ORM metadata', flush=True)
    Base.metadata.create_all(db.engine)
    cfg = Config(os.path.join(os.path.dirname(db.__file__), '..', 'alembic.ini'))
    command.stamp(cfg, 'head')
    print('[bootstrap] schema created and stamped at head', flush=True)
else:
    print('[bootstrap] database already initialized, skipping', flush=True)
PYEOF

uv run --no-sync python run.py >/tmp/accops-backend.log 2>&1 &
BACKEND_PID=$!
echo "backend pid $BACKEND_PID (127.0.0.1:${BACKEND_PORT})"

cd /app/frontend
pnpm dev --port "$FRONTEND_PORT" --strictPort >/tmp/accops-frontend.log 2>&1 &
FRONTEND_PID=$!
echo "frontend pid $FRONTEND_PID (0.0.0.0:${FRONTEND_PORT})"

# Wait until both answer, then keep the container alive on them.
for _ in $(seq 1 60); do
  if curl -fs -o /dev/null "http://127.0.0.1:${FRONTEND_PORT}/" \
     && curl -fs -o /dev/null "http://127.0.0.1:${BACKEND_PORT}/docs"; then
    echo "AccOps ready: frontend :${FRONTEND_PORT}, backend :${BACKEND_PORT}"
    break
  fi
  sleep 2
done

wait -n "$BACKEND_PID" "$FRONTEND_PID"
