# Lab exercises

## Part 0 - Setup

Install Docker Desktop (Windows/macOS) or Docker Engine (Linux). Then:

```bash
cp .env.example .env      # edit the password if you like
```

Sanity check:

```bash
docker --version
docker compose version
```

---

## Part 1 - Install the stack

This is the "installation at the customer's site" step from the job posting.

```bash
./scripts/deploy.sh
```

On Windows PowerShell, run the same three things by hand:

```powershell
docker compose up -d
docker compose ps
Get-Content sql\01_schema.sql | docker exec -i overlay-sql `
  /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P 'Overlay!Lab2026' -C -b
```

**Understand before moving on:**

- `docker compose ps` - what does the `health` column say, and where did that
  health check come from? (Look at `docker-compose.yml`.)
- `docker compose logs sqlserver` - find the line where SQL Server finishes
  recovery and starts listening.
- `docker volume ls` - which volumes exist, and why is the database on a
  named volume rather than inside the container?
- `docker exec -it overlay-sql bash` then `ls /var/opt/mssql/data` - see the
  actual `.mdf` and `.ldf` files.

**Questions to be able to answer out loud:**
1. What happens to the data if you run `docker compose down`? What about
   `docker compose down -v`?
2. Why does the ingest service use `depends_on: condition: service_healthy`
   rather than just `depends_on: sqlserver`?

---

## Part 2 - Get data flowing

```bash
python3 scripts/generate_data.py
docker compose logs -f ingest
```

You should see three files ingested within about 20 seconds. Then look at what
landed:

```bash
docker exec -it overlay-sql /opt/mssql-tools18/bin/sqlcmd \
  -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d OverlayLab \
  -Q "SELECT * FROM dbo.vw_RunSummary"
```

Better: install a proper client and work through `scripts/queries.sql` there.
Being able to say you used a real tool rather than only a terminal is worth
something. Both of these are free:

- **VS Code + the MSSQL extension** (Windows, macOS, Linux). This is
  Microsoft's current recommendation - Azure Data Studio was retired in
  February 2026. Search "SQL Server (mssql)" in the Extensions marketplace.
- **SQL Server Management Studio (SSMS)** (Windows only). Heavier, but it is
  what most SQL Server administrators actually use, and it has the backup,
  restore and Activity Monitor screens as real UI rather than T-SQL.

Connect to `localhost,1433`, user `sa`, and tick "Trust server certificate" -
the container uses a self-signed cert, which is worth understanding rather than
just clicking past.

Now generate a drifting wafer and find it:

```bash
python3 scripts/generate_data.py --drift
```

Run query 4 in `scripts/queries.sql`. Slot 9 should stand out - its mean overlay
is several nanometres off zero while the others sit near zero. **That is the
whole point of the product category:** a mean that walks away from zero is a
scanner correction waiting to happen.

---

## Part 3 - The administration basics

This is the SQL Server admin knowledge the job asks for. Do each one.

**Backup and restore.**

```bash
./scripts/backup.sh                    # writes backup/OverlayLab_<stamp>.bak
```

Then destroy some data on purpose and bring it back:

```sql
DELETE FROM dbo.OverlayPoint;
SELECT COUNT(*) FROM dbo.OverlayPoint;   -- 0
```

```bash
./scripts/restore.sh OverlayLab_<stamp>.bak
```

Confirm the rows are back. Understand what `SET SINGLE_USER WITH ROLLBACK
IMMEDIATE` did and why the restore would have failed without it.

**Read the error log.**

```sql
EXEC sp_readerrorlog 0, 1, N'Error';
```

**Check sizes and free space.** Queries 5 and 6 in `scripts/queries.sql`.

**See who is connected.** Query 8. Leave your SQL client connected and run it -
you should see your own session listed.

**Run the health check.**

```powershell
.\scripts\healthcheck.ps1
```

Read the script. You wrote PowerShell at Neumann Kaffee, so this should be
familiar ground - the only new part is `docker exec` and `sqlcmd`.

---

## Part 4 - Break it on purpose

For each scenario: break it, observe the symptom, diagnose it using only logs
and the health check, fix it, then write it up in `runbook/RUNBOOK.md`.

Do not look up the answer first. Sit with the broken state.

### 4.1 Wrong password
```bash
docker compose stop ingest
# edit .env, change the password to something wrong
docker compose up -d ingest
docker compose logs -f ingest
```
What exactly does the error say? What does `docker compose ps` show? Fix it.

### 4.2 Malformed input file
```bash
python3 scripts/generate_data.py --bad
```
The service should reject one file and keep running. Where did the rejected
file go? What does `dbo.IngestLog` say about it? **This is the exact shape of a
real customer ticket** - "our data isn't appearing in the system."

### 4.3 Database gone
```sql
DROP DATABASE OverlayLab;   -- you have a backup, this is safe
```
Watch the ingest logs. What does the health check report? Restore it.

### 4.4 Port already in use
Start something else on 1433, or change the host port mapping to one that is
occupied, then `docker compose up -d`. Read the error. Understand which side of
`1433:1433` is the host.

### 4.5 Out of memory
Add to the `sqlserver` service in `docker-compose.yml`:
```yaml
    mem_limit: 1g
```
`docker compose up -d`, then `docker compose logs sqlserver`. SQL Server needs
about 2 GB minimum. What does `docker inspect overlay-sql` say under
`State.OOMKilled`? Remove the limit.

### 4.6 Log file growth
Insert data repeatedly and watch the `.ldf` grow via query 6. Then:
```sql
ALTER DATABASE OverlayLab SET RECOVERY SIMPLE;
DBCC SHRINKFILE (OverlayLab_log, 100);
```
Understand what recovery models are and why FULL without log backups fills a
disk. This is one of the most common real SQL Server support calls.

---

## Part 5 - Roll out a patch

The job says: *supporting the rollout of new software releases, including
hotfixes and patches*. So practise it.

1. Change something small in `ingest/ingest.py` - add the row count to the log
   line, say. Call it v1.1.
2. `docker compose build ingest`
3. `docker compose up -d ingest` - note that only the ingest container is
   recreated; SQL Server keeps running.
4. Verify the new behaviour in the logs.
5. Now roll back: `git checkout ingest/ingest.py`, rebuild, redeploy.

Write down the sequence you would give a customer, including how you would
verify success and how you would back out. That short procedure is a genuine
work artifact - put it in the runbook.

---

## Part 6 - Optional: Kubernetes

Only if Parts 1-5 are done. Install **k3s** on a Linux VM, or enable Kubernetes
in Docker Desktop, then deploy SQL Server as a StatefulSet with a
PersistentVolumeClaim.

The value here is not the manifest. It is being able to say: *"I deployed SQL
Server on k3s, killed the pod, and watched it come back with its data intact,
because the PVC survived the pod."* Then practise the diagnostic loop:
`kubectl get pods`, `kubectl describe pod`, `kubectl logs --previous`.

Deliberately set an image tag that does not exist and identify
`ImagePullBackOff`. Deliberately set `memory: 100Mi` and identify `OOMKilled`.

