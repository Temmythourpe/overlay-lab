#!/usr/bin/env bash
# Overlay Lab :: "install at the customer site"
# Brings the stack up and applies the database schema.
set -euo pipefail

cd "$(dirname "$0")/.."
[ -f .env ] || { echo "No .env found. Copy .env.example to .env first."; exit 1; }
# shellcheck disable=SC1091
source .env

TOOLS=/opt/mssql-tools18/bin/sqlcmd

echo "==> Starting containers"
docker compose up -d

echo "==> Waiting for SQL Server to accept connections"
for i in $(seq 1 40); do
  if docker exec overlay-sql $TOOLS -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C \
       -Q "SELECT 1" -b >/dev/null 2>&1; then
    echo "    ready after ${i} attempt(s)"
    break
  fi
  [ "$i" -eq 40 ] && { echo "    SQL Server never came up. Check: docker logs overlay-sql"; exit 1; }
  sleep 5
done

echo "==> Applying schema"
docker exec -i overlay-sql $TOOLS -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b \
  < sql/01_schema.sql

echo "==> Done. Drop CSV files into ./data and watch: docker compose logs -f ingest"
