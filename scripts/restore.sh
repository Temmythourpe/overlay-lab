#!/usr/bin/env bash
# Overlay Lab :: restore from a backup file living inside the container.
# Usage: ./scripts/restore.sh OverlayLab_20260825_101500.bak
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck disable=SC1091
source .env

[ $# -eq 1 ] || { echo "Usage: $0 <backup-file-name>"; exit 1; }
NAME="$1"
TOOLS=/opt/mssql-tools18/bin/sqlcmd

# If the file only exists on the host, push it back into the container first.
if [ -f "backup/${NAME}" ]; then
  docker cp "backup/${NAME}" "overlay-sql:/var/opt/mssql/backup/${NAME}"
fi

docker exec overlay-sql $TOOLS -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -b -Q \
  "ALTER DATABASE OverlayLab SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
   RESTORE DATABASE OverlayLab FROM DISK = '/var/opt/mssql/backup/${NAME}' WITH REPLACE, STATS = 10;
   ALTER DATABASE OverlayLab SET MULTI_USER;"

echo "Restored from ${NAME}"
