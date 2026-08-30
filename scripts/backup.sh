#!/usr/bin/env bash
# Overlay Lab :: take a full backup and copy it to the host.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

TOOLS=/opt/mssql-tools18/bin/sqlcmd
STAMP=$(date +%Y%m%d_%H%M%S)
NAME="OverlayLab_${STAMP}.bak"

docker exec overlay-sql $TOOLS -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q \
  "BACKUP DATABASE OverlayLab TO DISK = '/var/opt/mssql/backup/${NAME}' WITH INIT, COMPRESSION, STATS = 10;"

mkdir -p backup
docker cp "overlay-sql:/var/opt/mssql/backup/${NAME}" "backup/${NAME}"
echo "Backup written to backup/${NAME}"
ls -lh "backup/${NAME}"
