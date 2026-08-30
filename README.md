# Overlay Lab

A small, deliberately breakable data stack: **SQL Server in Docker**, a
containerised ingest service, and the scripts a support engineer would actually
use to install it, monitor it and diagnose it.

Built as a self-study project to get hands-on with SQL Server administration and
container fundamentals, modelled on the kind of system a semiconductor fab runs
for lithography process control - measurement data arriving continuously from
metrology tools, landing in a database, and being watched for problems.

---

## What it does

Metrology CSV files land in `./data`. A Python service picks them up, loads the
overlay measurements into SQL Server, and records every attempt - success or
failure - in an audit table. A health-check script reports on the whole stack in
one pass.

```
 ./data/*.csv  ──►  ingest service  ──►  SQL Server ──►  dbo.vw_RunSummary
   (metrology       (container,           (container,      mean and 3-sigma
    output)          Python)               named volume)    overlay per wafer
                          │                     ▲
                          └── dbo.IngestLog ────┘
                              (what arrived, what was rejected, why)
```

**Overlay** is the layer-to-layer alignment error on a wafer, measured in
nanometres. When the mean drifts away from zero, the lithography scanner needs a
correction; if it is not caught, the chips do not work. The data model here
mirrors that: lots, wafers, measurement runs, and per-site overlay values, with
a view that reports mean and 3-sigma per run.

## Stack

| Component | Choice | Why |
|---|---|---|
| Database | SQL Server 2022 (Developer) | Target of the exercise |
| Persistence | Named Docker volume | Database survives container recreation |
| Ingest | Python 3.12 + `pymssql`, containerised | Something to keep running and diagnose |
| Orchestration | Docker Compose | Health check gates ingest start-up |
| Monitoring | PowerShell health check | Nine checks: container, connectivity, freshness, failures, backup age, disk, error log |
| Ops | Bash scripts | Install, backup, restore |

## Quick start

```bash
cp .env.example .env
./scripts/deploy.sh              # start containers, apply schema
python3 scripts/generate_data.py # write sample metrology files
docker compose logs -f ingest    # watch them load
```

Then:

```powershell
.\scripts\healthcheck.ps1
```

```
PASS  sql container             state=running health=healthy restarts=0
PASS  ingest container          state=running
PASS  sql connectivity          login succeeded
PASS  database size             28.0 MB
PASS  data freshness            2 min old
WARN  ingest failures 24h       1 file(s) rejected - see dbo.IngestLog
FAIL  last full backup          no backup has ever been taken
PASS  disk /var/opt/mssql       12% used
PASS  sql error log 24h         clean
```

## Repository layout

```
docker-compose.yml       Two services, named volumes, health check
sql/01_schema.sql        Tables, indexes, reporting views
ingest/                  Ingest service and its Dockerfile
scripts/deploy.sh        Install: start stack, apply schema
scripts/backup.sh        Full backup, copied out to the host
scripts/restore.sh       Restore from a backup file
scripts/healthcheck.ps1  Nine-point health report, exit-coded
scripts/queries.sql      The queries a support engineer actually runs
scripts/generate_data.py Sample data, including drifting and malformed files
runbook/RUNBOOK.md       Failure modes: symptom, diagnosis, fix
LAB.md                   The exercises, in order
```

## What I set out to learn

- SQL Server administration from an operator's angle: backup and restore,
  recovery models and log growth, reading the error log, checking file sizes
  and connections
- Docker fundamentals: images versus containers, why persistence has to be a
  volume, port publishing, service-name DNS on a user-defined network,
  health checks and start-up ordering, memory limits
- The support workflow itself: diagnosing from logs first, keeping an audit
  trail so "the data never arrived" is answerable, and writing down what
  happened so the next person is faster

`runbook/RUNBOOK.md` documents six failure modes I induced deliberately -
wrong credentials, malformed input, missing database, port conflict, container
OOM kill, and unbounded log growth - each with the symptom I saw, how I
narrowed it down, and the fix.

## Cost

Nothing here requires a paid subscription:

| Component | Licence |
|---|---|
| SQL Server 2022 Developer | Free, full feature set, development and test use only |
| Docker Desktop | Free under Docker Personal for individual and small-business use |
| Docker Engine / Podman | Apache 2.0 - free with no company-size condition |
| VS Code + MSSQL extension | Free |
| Python, Git, k3s | Free and open source |

Images come from Microsoft Container Registry (anonymous pulls) and Docker Hub.

## Notes

- Developer edition, single node, sample data. This is a learning environment,
  not a production reference.
- The `sa` account is used for simplicity. Production would use a least
  privilege service account and a secret store rather than a `.env` file.
