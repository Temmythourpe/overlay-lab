# Support runbook

Failure modes hit while building and operating this stack: the symptom observed,
how it was narrowed down, and the fix. Most of these were not planned - they
happened.

Environment: Windows 11, Docker Desktop (WSL2 backend), SQL Server 2022
Developer edition in a container, SSMS as the client.

---

## 1. Every docker command fails: cannot find the file specified

**Symptom** - `docker pull` and every other command fails with
`failed to connect to the docker API at npipe:////./pipe/dockerDesktopLinuxEngine`.

**Diagnosis** - `docker version` printed a Client block but no Server block, so
the CLI was working and the daemon was absent. Not a misconfiguration:
`docker context ls` confirmed the CLI was pointed at `desktop-linux` correctly.
`wsl -l -v` showed the `docker-desktop` distro present but `Stopped`.

**Cause** - the installer creates the backend WSL distro, but only the Docker
Desktop application starts it. Installing it does not start it, and it does not
necessarily resume after a reboot.

**Fix** - launch Docker Desktop, wait for "Engine running".

**Prevention** - enable "Start Docker Desktop when you sign in".

**Takeaway** - a Client block with no Server block is the signature of "client
healthy, service down". Establishing that split is the first move on any
connectivity ticket.

---

## 2. Deployment fails: schema file not found

**Symptom** - `Get-Content sql\01_schema.sql` returned
`Cannot find path ... because it does not exist`.

**Diagnosis** - `Get-ChildItem -Recurse` showed all 17 files present but flat in
the root directory instead of in `sql\`, `ingest\`, `scripts\` and `runbook\`.

**Fix** - recreated the directories and moved the files into place.

**Why layout matters** - `docker-compose.yml` declares `build: ./ingest`, so
Docker expects `ingest/Dockerfile` and treats that folder as the entire build
context. The Dockerfile's `COPY requirements.txt .` is relative to it. Layout is
referenced by the config, not cosmetic.

**Takeaway** - verify artifacts are present before starting a deployment, not
during one. A missing file is one of the most common rollout failures.

---

## 3. Cannot set container memory or CPU limits

**Symptom** - no memory or CPU sliders in Docker Desktop settings.

**Diagnosis** - with the WSL2 backend Docker Desktop runs no VM of its own, so
it has nothing to limit. The resources belong to the WSL2 VM.

**Cause** - two similarly named files: `/etc/wsl.conf` (inside a distro,
per-distro settings) versus `%UserProfile%\.wslconfig` (on Windows, controls the
whole WSL2 VM - memory, processors, swap).

**Fix** - created `.wslconfig` with `[wsl2] memory=8GB processors=4 swap=2GB`,
then `wsl --shutdown` and restarted Docker Desktop. Verified with
`docker info --format "{{.NCPU}} {{.MemTotal}}"`.

**Note** - the value is a ceiling, not a reservation. WSL2 allocates on demand.

---

## 4. docker command not found inside the Ubuntu WSL distro

**Symptom** - `docker version` works in PowerShell, fails inside Ubuntu with
"The command 'docker' could not be found in this WSL 2 distro."

**Diagnosis** - the shell had changed, not the system. PowerShell and the Ubuntu
distro are two operating systems sharing a filesystem; the CLI is installed on
the Windows side only by default.

**Fix** - Docker Desktop, Settings, Resources, WSL Integration, enable Ubuntu.
Both shells then talk to the same engine.

---

## 5. SSMS: the connection is broken and recovery is not possible

**Symptom** - SSMS reported a broken connection after a config change.

**Diagnosis** - `docker compose ps` showed the container healthy with zero
restarts, and `sqlcmd` inside the container worked. The server never went away;
only the client's session had.

**Cause** - changing the port binding caused `docker compose up -d` to recreate
the container. The old container, and every TCP connection to it, was destroyed.
SSMS was holding a connection to a process that no longer existed.

**Fix** - disconnect and reconnect.

**Takeaway** - containers are replaced, not updated in place. Any config change
that recreates a container is an outage for connected clients. This is why
applications need retry logic and why recreation is scheduled rather than casual.

---

## 6. SSMS cannot connect on localhost, but 127.0.0.1 works

**Symptom** - after binding the container to `127.0.0.1:1433:1433`, SSMS failed
on `localhost,1433` and succeeded on `127.0.0.1,1433`.

**Evidence** - `Test-NetConnection -ComputerName localhost -Port 1433` returned
`TcpTestSucceeded : True` but also printed
`WARNING: TCP connect to (::1 : 1433) failed`.

**Cause** - Windows resolves `localhost` to IPv6 `::1` first. The published port
was bound to IPv4 only, so nothing was listening on `::1`. PowerShell fell back
to IPv4 and succeeded; SSMS did not fall back.

**Fix** - connect to `127.0.0.1` explicitly, which skips name resolution.
Binding both stacks would also work.

**Takeaway** - "works from one tool but not another on the same host" is very
often IPv4/IPv6 resolution, not permissions or firewall.

---

## 7. Database unreachable from the LAN after tightening the binding

**Symptom** - `Test-NetConnection` to the machine's LAN address returned
`PingSucceeded : True` but `TcpTestSucceeded : False`.

**Cause** - intentional. The mapping was changed from `1433:1433` (defaults to
`0.0.0.0`, every interface) to `127.0.0.1:1433:1433`. Full syntax is
`hostIP:hostPort:containerPort`.

**Takeaway** - ping succeeding while TCP fails is the signature of "host
reachable, service not listening on that interface". A database has no reason to
be published on every interface.

---

## 8. PowerShell refuses to run the health check script

**Symptom** - `File ... is not digitally signed. You cannot run this script on
the current system.`

**Fix** - `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` for the
session only. `Unblock-File` clears the mark-of-the-web flag on downloads.

**Takeaway** - execution policy is a guardrail, not a security boundary. At
scale the right answer is a code-signing certificate or an Intune configuration
profile, not telling users to run Bypass. Expect this on hardened customer
servers.

---

## 9. Health check reports "could not read" on every query

**Symptom** - the connectivity check passed, but every check that ran a query
returned "could not read".

**Diagnosis** - if SQL were unreachable, connectivity would have failed too.
Running the same query manually as a single line worked. Every failing check
used a PowerShell here-string containing newlines.

**Cause** - newlines embedded in an argument do not survive being passed through
`docker exec` on Windows. The output could not be parsed, the `[int]` cast threw,
and an over-broad `catch` reported a generic message.

**Fix** - collapse queries to a single line before sending
(`-replace "\s+", " "`), and report the actual exception message.

**Takeaway** - a check that says "could not read" without saying why is worse
than no check. Error handling that swallows the cause makes a system
unsupportable.

---

## 10. Msg 208: Invalid object name

**Diagnosis** - `SELECT DB_NAME()` showed the query window was connected to
`master`, not `OverlayLab`. SSMS opens new query windows against the default
database.

**Fix** - `USE OverlayLab;` or select the database in the toolbar.

**Takeaway** - Msg 208 has two causes: wrong database context, or the object
genuinely missing. Check the context first; it costs one query.

---

## 11. Msg 4060: Cannot open database requested by the login

**Symptom** - SSMS refused to connect: "Cannot open database 'OverlayLab'
requested by the login. The login failed."

**Diagnosis** - the wording is misleading. The credentials were correct; the
database was missing, and SSMS was requesting it by name as its default.

**Fix** - connect with the database set to `master`, then investigate.

**Takeaway** - 18456 means the password was rejected at authentication. 4060
means authentication passed and the database could not be opened. Same "login
failed" phrasing, different fault, different fix.

---

## 12. Backup directory owned by root, not by the SQL Server account

**Symptom** - `docker exec overlay-sql ls -la /var/opt/mssql/backup` showed the
directory owned by `root:root`, while SQL Server runs as `mssql`.

**Impact** - any `BACKUP DATABASE` to that path would have failed with
`Operating system error 5 (Access is denied)`.

**Cause** - Docker creates a fresh named volume owned by root.

**Fix** - `docker exec -u root overlay-sql chown mssql:root /var/opt/mssql/backup`.
The change persists on the volume.

**Takeaway** - the classic container volume permission trap. A mounted path is
not automatically writable by the service that needs it.

---

## 13. Database dropped with no backup in existence

**Symptom** - `RESTORE DATABASE` failed with
`Cannot open backup device ... Operating system error 2`. The backup directory
was empty.

**Cause** - the health check had been reporting
`FAIL last full backup: no backup has ever been taken`. The warning was not
acted on and a destructive operation was run anyway. The data was unrecoverable.

**Fix** - rebuilt from the schema script and regenerated the sample data.

**Takeaway** - the most useful failure in the whole exercise. Monitoring
correctly reported that the recovery path did not exist, and the warning was
walked past. A backup that has not been verified to exist is not a backup. Check
the recovery path before running anything destructive, not after.

---

## 14. Health check reports no data while the database contains data

**Symptom** - `WARN data freshness: no measurement runs loaded yet`, while
`dbo.IngestLog` held eight successful rows and the ingest logs showed runs
loading normally.

**Diagnosis** - compared timestamps. Container logs were in UTC (09:44); the
health check ran at 11:45 local. The machine is CEST, UTC+2. The generator wrote
`MeasuredAt` in local time and the check compared it against `SYSUTCDATETIME()`,
producing an age of about -119 minutes.

**Cause** - the script treated any negative value as its "no rows" sentinel, so a
timezone mismatch was reported as an absence of data.

**Fix** - write timestamps in UTC at the source, and use a distinct sentinel so
"table empty" and "timestamp in the future" report differently.

**Takeaway** - a monitoring false negative. The pipeline was healthy throughout
and the check said otherwise. Two distinct conditions had been folded into one
branch. Store timestamps in UTC, convert at display time.

---

## 15. Compose refuses to deploy: additional properties not allowed

**Symptom** - `validating docker-compose.yml: additional properties 'mem_limit' not allowed`.

**Cause** - YAML indentation. The key sat at the wrong nesting level, so Compose
read it as an unknown property of the service map.

**Fix** - corrected the indentation, and validated with `docker compose config`
before deploying.

**Takeaway** - caught at validation, so nothing deployed and nothing broke.
`docker compose config` before `up` is worth making habitual. Kubernetes
manifests fail the same way.

---

## 16. Malformed measurement file rejected

**Symptom** - one CSV failed to load; the service kept running and continued
processing other files.

**Diagnosis** - `dbo.IngestLog` recorded the file, status FAILED, and the reason:
`missing required columns: overlay_y_nm`. The file was moved to `data/failed/`.

**Takeaway** - this is the shape of the most likely real ticket: "our data isn't
appearing in the system." Because every attempt is logged with a reason, the
answer is one query rather than an investigation. A pipeline should reject bad
input without stopping, and record why.

---

## Release rollout procedure

Followed when deploying a new version of the ingest service.

**Before**

1. Confirm a current backup exists and has been verified, not assumed.
2. `docker compose config` to validate the configuration.
3. Note the currently deployed image tag so rollback is possible.

**Deploy**

1. `docker compose build ingest`
2. `docker compose up -d ingest` - only the changed service is recreated; the
   database keeps running.

**Verify**

1. `docker compose ps` - container healthy.
2. `docker compose logs --tail 20 ingest` - new version behaving as expected.
3. Feed a test file and confirm it reaches the database.
4. `.\scripts\healthcheck.ps1` - all checks pass.

**Rollback**

1. Revert the change, rebuild, redeploy the previous version.
2. Verify with the same steps.
3. Expect connected clients to have been disconnected by the recreation.
