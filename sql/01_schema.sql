-- Overlay Lab :: schema
-- Applied by scripts/deploy.sh (or deploy.ps1) during "installation".

IF DB_ID('OverlayLab') IS NULL
    CREATE DATABASE OverlayLab;
GO

USE OverlayLab;
GO

-- A lot is a batch of wafers moving through the fab together.
IF OBJECT_ID('dbo.Lot') IS NULL
CREATE TABLE dbo.Lot (
    LotID     INT IDENTITY(1,1) PRIMARY KEY,
    LotName   NVARCHAR(50)  NOT NULL UNIQUE,
    Product   NVARCHAR(50)  NULL,
    CreatedAt DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- Each wafer sits in a numbered slot in the lot carrier.
IF OBJECT_ID('dbo.Wafer') IS NULL
CREATE TABLE dbo.Wafer (
    WaferID INT IDENTITY(1,1) PRIMARY KEY,
    LotID   INT NOT NULL REFERENCES dbo.Lot(LotID),
    SlotNo  INT NOT NULL,
    CONSTRAINT UQ_Wafer_Lot_Slot UNIQUE (LotID, SlotNo)
);
GO

-- One pass of the metrology tool over one wafer at one layer.
IF OBJECT_ID('dbo.MeasurementRun') IS NULL
CREATE TABLE dbo.MeasurementRun (
    RunID      INT IDENTITY(1,1) PRIMARY KEY,
    WaferID    INT           NOT NULL REFERENCES dbo.Wafer(WaferID),
    Layer      NVARCHAR(30)  NOT NULL,
    ToolID     NVARCHAR(30)  NOT NULL,
    MeasuredAt DATETIME2(0)  NOT NULL,
    SourceFile NVARCHAR(260) NULL,
    CreatedAt  DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

-- The actual measurements: overlay error in nanometres at each site.
IF OBJECT_ID('dbo.OverlayPoint') IS NULL
CREATE TABLE dbo.OverlayPoint (
    PointID     BIGINT IDENTITY(1,1) PRIMARY KEY,
    RunID       INT NOT NULL REFERENCES dbo.MeasurementRun(RunID),
    FieldX      INT NOT NULL,
    FieldY      INT NOT NULL,
    DieX        INT NOT NULL,
    DieY        INT NOT NULL,
    OverlayX_nm DECIMAL(9,3) NOT NULL,
    OverlayY_nm DECIMAL(9,3) NOT NULL
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_OverlayPoint_RunID')
    CREATE INDEX IX_OverlayPoint_RunID ON dbo.OverlayPoint(RunID);
GO

-- Audit trail for every file the ingest service picks up.
-- This is the first table you look at when a customer says
-- "my measurement data never showed up".
IF OBJECT_ID('dbo.IngestLog') IS NULL
CREATE TABLE dbo.IngestLog (
    LogID        INT IDENTITY(1,1) PRIMARY KEY,
    FileName     NVARCHAR(260) NOT NULL,
    RowsRead     INT           NULL,
    RowsInserted INT           NULL,
    Status       NVARCHAR(20)  NOT NULL,   -- SUCCESS | FAILED
    Message      NVARCHAR(2000) NULL,
    StartedAt    DATETIME2(0)  NOT NULL DEFAULT SYSUTCDATETIME(),
    FinishedAt   DATETIME2(0)  NULL
);
GO

-- Per-run statistics. Mean and 3-sigma are how overlay results are
-- actually reported; a drifting mean is what triggers a scanner correction.
CREATE OR ALTER VIEW dbo.vw_RunSummary AS
SELECT
    r.RunID,
    l.LotName,
    w.SlotNo,
    r.Layer,
    r.ToolID,
    r.MeasuredAt,
    COUNT(p.PointID)                                  AS PointCount,
    CAST(AVG(p.OverlayX_nm) AS DECIMAL(9,3))          AS MeanX_nm,
    CAST(AVG(p.OverlayY_nm) AS DECIMAL(9,3))          AS MeanY_nm,
    CAST(3 * STDEV(p.OverlayX_nm) AS DECIMAL(9,3))    AS ThreeSigmaX_nm,
    CAST(3 * STDEV(p.OverlayY_nm) AS DECIMAL(9,3))    AS ThreeSigmaY_nm,
    CAST(MAX(ABS(p.OverlayX_nm)) AS DECIMAL(9,3))     AS MaxAbsX_nm,
    CAST(MAX(ABS(p.OverlayY_nm)) AS DECIMAL(9,3))     AS MaxAbsY_nm
FROM dbo.MeasurementRun r
JOIN dbo.Wafer w ON w.WaferID = r.WaferID
JOIN dbo.Lot   l ON l.LotID   = w.LotID
LEFT JOIN dbo.OverlayPoint p ON p.RunID = r.RunID
GROUP BY r.RunID, l.LotName, w.SlotNo, r.Layer, r.ToolID, r.MeasuredAt;
GO

-- Rolled-up ingest health for the last 24 hours.
CREATE OR ALTER VIEW dbo.vw_IngestHealth AS
SELECT
    Status,
    COUNT(*)          AS FileCount,
    MAX(FinishedAt)   AS LastAt
FROM dbo.IngestLog
WHERE StartedAt >= DATEADD(hour, -24, SYSUTCDATETIME())
GROUP BY Status;
GO

PRINT 'OverlayLab schema applied.';
GO
