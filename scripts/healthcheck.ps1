<#
    Overlay Lab :: health check

    A support engineer's first response. Answers, in one pass:
      is the container up, is SQL reachable, is data arriving,
      is anything failing, when was the last backup, is disk filling up.

    Usage:
        .\scripts\healthcheck.ps1
        .\scripts\healthcheck.ps1 -SaPassword 'Overlay!Lab2026'

    Exit code 0 = all pass, 1 = at least one WARN, 2 = at least one FAIL.
#>

[CmdletBinding()]
param(
    [string]$Container = "overlay-sql",
    [string]$IngestContainer = "overlay-ingest",
    [string]$Database = "OverlayLab",
    [string]$SaPassword,
    [int]$StaleDataMinutes = 60,
    [int]$BackupMaxAgeHours = 24
)

$ErrorActionPreference = "Stop"
$script:WorstLevel = 0
$Tools = "/opt/mssql-tools18/bin/sqlcmd"

function Write-Result {
    param([string]$Check, [string]$Level, [string]$Detail)
    $colour = switch ($Level) {
        "PASS" { "Green" }
        "WARN" { "Yellow" }
        default { "Red" }
    }
    $rank = switch ($Level) { "PASS" { 0 } "WARN" { 1 } default { 2 } }
    if ($rank -gt $script:WorstLevel) { $script:WorstLevel = $rank }
    Write-Host ("{0,-6}" -f $Level) -ForegroundColor $colour -NoNewline
    Write-Host ("{0,-26} {1}" -f $Check, $Detail)
}

if (-not $SaPassword) {
    $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) ".env"
    if (Test-Path $envFile) {
        $line = Get-Content $envFile | Where-Object { $_ -match "^MSSQL_SA_PASSWORD=" }
        if ($line) { $SaPassword = ($line -split "=", 2)[1].Trim() }
    }
}
if (-not $SaPassword) {
    Write-Result "credentials" "FAIL" "no password supplied and none found in .env"
    exit 2
}

function Invoke-SqlScalar {
    <#
        Runs a query and returns the first numeric line of output.

        Multi-line queries get collapsed to a single line first: newlines
        embedded in an argument do not survive being passed through
        docker exec on Windows, which silently produces unusable output.
    #>
    param([string]$Query)

    $flat = ($Query -replace "\s+", " ").Trim()
    $out = docker exec $Container $Tools -S localhost -U sa -P $SaPassword -C `
        -d $Database -h -1 -W -Q $flat 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw ("sqlcmd exited $LASTEXITCODE : " + (($out | Out-String).Trim() -replace "\s+", " "))
    }

    $value = $out |
        Where-Object { $_ -match '^\s*-?[0-9]+(\.[0-9]+)?\s*$' } |
        Select-Object -First 1

    if ($null -eq $value) {
        throw ("unexpected output: " + (($out | Out-String).Trim() -replace "\s+", " "))
    }
    return $value.Trim()
}

Write-Host ""
Write-Host "Overlay Lab health check  --  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host ("-" * 72)

# 1. Container state
try {
    $state = (docker inspect -f "{{.State.Status}}" $Container 2>&1).Trim()
    $health = (docker inspect -f "{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}" $Container 2>&1).Trim()
    $restarts = (docker inspect -f "{{.RestartCount}}" $Container 2>&1).Trim()
    if ($state -ne "running") {
        Write-Result "sql container" "FAIL" "state=$state"
    } elseif ([int]$restarts -gt 3) {
        Write-Result "sql container" "WARN" "running but has restarted $restarts times"
    } else {
        Write-Result "sql container" "PASS" "state=$state health=$health restarts=$restarts"
    }
} catch {
    Write-Result "sql container" "FAIL" "not found: $($_.Exception.Message)"
    exit 2
}

# 2. Ingest container
try {
    $istate = (docker inspect -f "{{.State.Status}}" $IngestContainer 2>&1).Trim()
    if ($istate -eq "running") {
        Write-Result "ingest container" "PASS" "state=$istate"
    } else {
        Write-Result "ingest container" "FAIL" "state=$istate"
    }
} catch {
    Write-Result "ingest container" "WARN" "not found"
}

# 3. SQL connectivity
try {
    $null = Invoke-SqlScalar "SELECT 1"
    Write-Result "sql connectivity" "PASS" "login succeeded"
} catch {
    Write-Result "sql connectivity" "FAIL" ($_.Exception.Message -replace "\s+", " ")
    exit 2
}

# 4. Database size
try {
    $value = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT CAST(SUM(size) * 8.0 / 1024 AS DECIMAL(10,1))
FROM sys.database_files WHERE type_desc = 'ROWS';
"@
    Write-Result "database size" "PASS" "$value MB"
} catch {
    Write-Result "database size" "WARN" $_.Exception.Message
}

# 5. Data freshness
try {
    $value = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT ISNULL(DATEDIFF(minute, MAX(MeasuredAt), SYSUTCDATETIME()), -1)
FROM dbo.MeasurementRun;
"@
    $age = [int]$value
    if ($age -lt 0) {
        Write-Result "data freshness" "WARN" "no measurement runs loaded yet"
    } elseif ($age -gt $StaleDataMinutes) {
        Write-Result "data freshness" "WARN" "newest run is $age min old"
    } else {
        Write-Result "data freshness" "PASS" "newest run is $age min old"
    }
} catch {
    Write-Result "data freshness" "WARN" $_.Exception.Message
}

# 6. Failed ingests in last 24h
try {
    $value = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT COUNT(*) FROM dbo.IngestLog
WHERE Status = 'FAILED' AND StartedAt >= DATEADD(hour, -24, SYSUTCDATETIME());
"@
    $failed = [int]$value
    if ($failed -gt 0) {
        Write-Result "ingest failures 24h" "WARN" "$failed file(s) rejected - see dbo.IngestLog"
    } else {
        Write-Result "ingest failures 24h" "PASS" "none"
    }
} catch {
    Write-Result "ingest failures 24h" "WARN" $_.Exception.Message
}

# 7. Backup age
try {
    $value = Invoke-SqlScalar @"
SET NOCOUNT ON;
SELECT ISNULL(DATEDIFF(hour, MAX(backup_finish_date), GETDATE()), -1)
FROM msdb.dbo.backupset WHERE database_name = '$Database' AND type = 'D';
"@
    $bage = [int]$value
    if ($bage -lt 0) {
        Write-Result "last full backup" "FAIL" "no backup has ever been taken"
    } elseif ($bage -gt $BackupMaxAgeHours) {
        Write-Result "last full backup" "WARN" "$bage hours old"
    } else {
        Write-Result "last full backup" "PASS" "$bage hours old"
    }
} catch {
    Write-Result "last full backup" "WARN" $_.Exception.Message
}

# 8. Disk space inside the container
try {
    $df = docker exec $Container df -h /var/opt/mssql 2>&1 | Select-Object -Last 1
    $usedPct = [int](($df -split "\s+")[4] -replace "%", "")
    if ($usedPct -ge 90) {
        Write-Result "disk /var/opt/mssql" "FAIL" "$usedPct% used"
    } elseif ($usedPct -ge 75) {
        Write-Result "disk /var/opt/mssql" "WARN" "$usedPct% used"
    } else {
        Write-Result "disk /var/opt/mssql" "PASS" "$usedPct% used"
    }
} catch {
    Write-Result "disk /var/opt/mssql" "WARN" "could not read"
}

# 9. Recent errors in the SQL Server error log
try {
    $value = Invoke-SqlScalar @"
SET NOCOUNT ON;
CREATE TABLE #el (LogDate DATETIME, ProcessInfo NVARCHAR(100), Text NVARCHAR(MAX));
INSERT INTO #el EXEC sys.xp_readerrorlog 0, 1, N'Error';
SELECT COUNT(*) FROM #el WHERE LogDate >= DATEADD(hour, -24, GETDATE());
DROP TABLE #el;
"@
    $errs = [int]$value
    if ($errs -gt 0) {
        Write-Result "sql error log 24h" "WARN" "$errs error line(s) - read with sp_readerrorlog"
    } else {
        Write-Result "sql error log 24h" "PASS" "clean"
    }
} catch {
    Write-Result "sql error log 24h" "WARN" $_.Exception.Message
}

Write-Host ("-" * 72)
switch ($script:WorstLevel) {
    0 { Write-Host "Overall: healthy" -ForegroundColor Green }
    1 { Write-Host "Overall: degraded - review warnings" -ForegroundColor Yellow }
    2 { Write-Host "Overall: unhealthy - action required" -ForegroundColor Red }
}
Write-Host ""
exit $script:WorstLevel