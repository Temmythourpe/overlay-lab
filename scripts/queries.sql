-- Overlay Lab :: the queries a support engineer actually runs.
-- Paste these into VS Code (MSSQL extension) or SSMS, or run with:
--   docker exec -i overlay-sql /opt/mssql-tools18/bin/sqlcmd \
--     -S localhost -U sa -P "$MSSQL_SA_PASSWORD" -C -d OverlayLab -i scripts/queries.sql

-- 1. Is data arriving at all?
SELECT TOP 10 * FROM dbo.IngestLog ORDER BY LogID DESC;

-- 2. Which files were rejected, and why?
SELECT FileName, Message, StartedAt
FROM dbo.IngestLog WHERE Status = 'FAILED' ORDER BY LogID DESC;

-- 3. Summary of every measurement run.
SELECT * FROM dbo.vw_RunSummary ORDER BY MeasuredAt DESC;

-- 4. Which wafers are drifting? Mean overlay well off zero means the
--    scanner correction is not holding.
SELECT LotName, SlotNo, Layer, MeanX_nm, MeanY_nm, ThreeSigmaX_nm
FROM dbo.vw_RunSummary
WHERE ABS(MeanX_nm) > 3 OR ABS(MeanY_nm) > 3
ORDER BY ABS(MeanX_nm) DESC;

-- 5. How big is each table? First question when a disk fills up.
SELECT t.name AS TableName,
       SUM(p.rows) AS [Rows],
       CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2)) AS SizeMB
FROM sys.tables t
JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
JOIN sys.allocation_units a ON a.container_id = p.partition_id
GROUP BY t.name ORDER BY SizeMB DESC;

-- 6. Database and log file sizes and free space.
SELECT name, type_desc,
       CAST(size * 8.0 / 1024 AS DECIMAL(10,1)) AS SizeMB,
       CAST(FILEPROPERTY(name, 'SpaceUsed') * 8.0 / 1024 AS DECIMAL(10,1)) AS UsedMB
FROM sys.database_files;

-- 7. Backup history.
SELECT TOP 10 database_name, type, backup_finish_date,
       CAST(backup_size / 1048576.0 AS DECIMAL(10,1)) AS SizeMB
FROM msdb.dbo.backupset WHERE database_name = 'OverlayLab'
ORDER BY backup_finish_date DESC;

-- 8. Who is connected right now?
SELECT session_id, login_name, host_name, program_name, status, last_request_end_time
FROM sys.dm_exec_sessions WHERE is_user_process = 1;

-- 9. Recent errors from the SQL Server error log.
EXEC sp_readerrorlog 0, 1, N'Error';
