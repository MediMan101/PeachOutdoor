-- =============================================================================
-- Create-ModelSpecs-Tables.sql
-- Peach Database - Model Specifications & Search Keywords
--
-- Run in SQL Server Management Studio against the [Peach] database.
--
-- New tables:
--   ModelSpec         - spec categories/rows tied to a Model record
--   ModelSearchTag    - search keywords tied to a Model record
--   ModelSpecSource   - tracks where each spec came from (URL/brochure)
-- =============================================================================

USE [Peach]
GO

-- =============================================================================
-- 1. ModelSpec
--    One row per spec field (e.g. "Engine / Horsepower / 26 HP")
--    Linked to Model via (Manufacture, Series, Model) - same unique key
--    that already exists on the Model table.
-- =============================================================================
IF OBJECT_ID('dbo.ModelSpec', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[ModelSpec] (
        [SpecID]        INT           IDENTITY(1,1) NOT NULL,

        -- Foreign key mirror of Model's unique constraint
        [Manufacture]   VARCHAR(30)   NOT NULL,
        [Series]        VARCHAR(20)   NOT NULL,
        [Model]         VARCHAR(30)   NOT NULL,

        -- Spec data
        [Category]      VARCHAR(50)   NOT NULL,   -- e.g. "Engine", "Transmission", "Dimensions"
        [SpecLabel]     VARCHAR(100)  NOT NULL,   -- e.g. "Horsepower", "Weight", "PTO HP"
        [SpecValue]     VARCHAR(200)  NOT NULL,   -- e.g. "26 HP", "2,756 lbs"

        [SortOrder]     INT           NOT NULL DEFAULT(0),  -- controls display order within category
        [Active]        BIT           NOT NULL DEFAULT(1),

        CONSTRAINT [PK_ModelSpec] PRIMARY KEY CLUSTERED ([SpecID] ASC),

        CONSTRAINT [FK_ModelSpec_Model] FOREIGN KEY ([Manufacture], [Series], [Model])
            REFERENCES [dbo].[Model] ([Manufacture], [Series], [Model])
    )

    -- Index for fast lookup by model
    CREATE NONCLUSTERED INDEX [IX_ModelSpec_Model]
        ON [dbo].[ModelSpec] ([Manufacture], [Series], [Model], [Category], [SortOrder])

    PRINT 'Created table: ModelSpec'
END
ELSE
    PRINT 'Table already exists: ModelSpec'
GO


-- =============================================================================
-- 2. ModelSearchTag
--    Keywords that help users find this model via the website search.
--    e.g.  "zero turn", "ZT", "60 inch", "Kohler", "residential"
--    Multiple rows per model, one tag per row.
-- =============================================================================
IF OBJECT_ID('dbo.ModelSearchTag', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[ModelSearchTag] (
        [TagID]         INT           IDENTITY(1,1) NOT NULL,

        [Manufacture]   VARCHAR(30)   NOT NULL,
        [Series]        VARCHAR(20)   NOT NULL,
        [Model]         VARCHAR(30)   NOT NULL,

        [Tag]           VARCHAR(100)  NOT NULL,   -- e.g. "zero turn", "cab tractor", "60 hp"
        [TagType]       VARCHAR(30)   NULL,        -- optional: 'feature','size','engine','category', etc.

        [Active]        BIT           NOT NULL DEFAULT(1),

        CONSTRAINT [PK_ModelSearchTag] PRIMARY KEY CLUSTERED ([TagID] ASC),

        CONSTRAINT [FK_ModelSearchTag_Model] FOREIGN KEY ([Manufacture], [Series], [Model])
            REFERENCES [dbo].[Model] ([Manufacture], [Series], [Model])
    )

    CREATE NONCLUSTERED INDEX [IX_ModelSearchTag_Model]
        ON [dbo].[ModelSearchTag] ([Manufacture], [Series], [Model])

    -- Full-text style index on Tag for search
    CREATE NONCLUSTERED INDEX [IX_ModelSearchTag_Tag]
        ON [dbo].[ModelSearchTag] ([Tag])

    PRINT 'Created table: ModelSearchTag'
END
ELSE
    PRINT 'Table already exists: ModelSearchTag'
GO


-- =============================================================================
-- 3. ModelSpecSource
--    Tracks where spec data came from — manufacturer URL, brochure PDF name,
--    or manual entry. One row per model, or multiple if sourced from several places.
-- =============================================================================
IF OBJECT_ID('dbo.ModelSpecSource', 'U') IS NULL
BEGIN
    CREATE TABLE [dbo].[ModelSpecSource] (
        [SourceID]      INT           IDENTITY(1,1) NOT NULL,

        [Manufacture]   VARCHAR(30)   NOT NULL,
        [Series]        VARCHAR(20)   NOT NULL,
        [Model]         VARCHAR(30)   NOT NULL,

        [SourceType]    VARCHAR(20)   NOT NULL,   -- 'URL', 'Brochure', 'Manual', 'Dealer Portal'
        [SourceURL]     VARCHAR(500)  NULL,        -- manufacturer spec page URL if applicable
        [SourceNote]    VARCHAR(200)  NULL,        -- e.g. brochure filename, notes
        [DateRetrieved] DATE          NULL,
        [EnteredBy]     VARCHAR(50)   NULL,

        CONSTRAINT [PK_ModelSpecSource] PRIMARY KEY CLUSTERED ([SourceID] ASC),

        CONSTRAINT [FK_ModelSpecSource_Model] FOREIGN KEY ([Manufacture], [Series], [Model])
            REFERENCES [dbo].[Model] ([Manufacture], [Series], [Model])
    )

    PRINT 'Created table: ModelSpecSource'
END
ELSE
    PRINT 'Table already exists: ModelSpecSource'
GO


-- =============================================================================
-- 4. VIEWS
--    These views are what the PowerShell export script will query to build
--    specs.json for the website.
-- =============================================================================

-- View: vw_ModelSpecs_JSON
-- Returns specs grouped per model, ready for JSON export
CREATE OR ALTER VIEW [dbo].[vw_ModelSpecs]
AS
    SELECT
        ms.Manufacture,
        ms.Series,
        ms.Model,
        ms.Category,
        ms.SpecLabel,
        ms.SpecValue,
        ms.SortOrder
    FROM [dbo].[ModelSpec] ms
    INNER JOIN [dbo].[Model] m
        ON ms.Manufacture = m.Manufacture
        AND ms.Series     = m.Series
        AND ms.Model      = m.Model
    WHERE ms.Active = 1
      AND m.Active  = 1
GO

-- View: vw_ModelSearchTags
-- Returns all active search tags per model
CREATE OR ALTER VIEW [dbo].[vw_ModelSearchTags]
AS
    SELECT
        mst.Manufacture,
        mst.Series,
        mst.Model,
        mst.Tag,
        mst.TagType
    FROM [dbo].[ModelSearchTag] mst
    INNER JOIN [dbo].[Model] m
        ON mst.Manufacture = m.Manufacture
        AND mst.Series     = m.Series
        AND mst.Model      = m.Model
    WHERE mst.Active = 1
      AND m.Active   = 1
GO

PRINT 'Created views: vw_ModelSpecs, vw_ModelSearchTags'
GO


-- =============================================================================
-- 5. STORED PROCEDURE: sp_GetModelSpecs
--    Returns spec rows for a specific model — useful for internal tooling
--    and for verifying data before the website export.
-- =============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_GetModelSpecs]
    @Manufacture VARCHAR(30),
    @Series      VARCHAR(20),
    @Model       VARCHAR(30)
AS
BEGIN
    SET NOCOUNT ON

    SELECT
        Category,
        SpecLabel,
        SpecValue,
        SortOrder
    FROM [dbo].[ModelSpec]
    WHERE Manufacture = @Manufacture
      AND Series      = @Series
      AND Model       = @Model
      AND Active      = 1
    ORDER BY Category, SortOrder, SpecLabel
END
GO

PRINT 'Created procedure: sp_GetModelSpecs'
GO


-- =============================================================================
-- 6. STORED PROCEDURE: sp_UpsertModelSpec
--    Insert or update a single spec row.
--    Use this from your entry UI or bulk-import scripts.
-- =============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_UpsertModelSpec]
    @Manufacture  VARCHAR(30),
    @Series       VARCHAR(20),
    @Model        VARCHAR(30),
    @Category     VARCHAR(50),
    @SpecLabel    VARCHAR(100),
    @SpecValue    VARCHAR(200),
    @SortOrder    INT = 0
AS
BEGIN
    SET NOCOUNT ON

    IF EXISTS (
        SELECT 1 FROM [dbo].[ModelSpec]
        WHERE Manufacture = @Manufacture
          AND Series      = @Series
          AND Model       = @Model
          AND Category    = @Category
          AND SpecLabel   = @SpecLabel
    )
    BEGIN
        UPDATE [dbo].[ModelSpec]
        SET SpecValue  = @SpecValue,
            SortOrder  = @SortOrder,
            Active     = 1
        WHERE Manufacture = @Manufacture
          AND Series      = @Series
          AND Model       = @Model
          AND Category    = @Category
          AND SpecLabel   = @SpecLabel
    END
    ELSE
    BEGIN
        INSERT INTO [dbo].[ModelSpec]
            (Manufacture, Series, Model, Category, SpecLabel, SpecValue, SortOrder)
        VALUES
            (@Manufacture, @Series, @Model, @Category, @SpecLabel, @SpecValue, @SortOrder)
    END
END
GO

PRINT 'Created procedure: sp_UpsertModelSpec'
GO


-- =============================================================================
-- 7. SAMPLE DATA — mirrors what is already in specs.json
--    Remove or comment out if you don't want these seed rows.
-- =============================================================================

-- Bad Boy 7530
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Engine',      'Type',       'Brushless Electric Motor', 1
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Engine',      'Power',      '80V',                      2
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Engine',      'Battery',    '2.5 Ah Lithium-Ion',       3
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Performance', 'Runtime',    'Up to 45 minutes',         1
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Performance', 'Charge Time','60 minutes',               2
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Performance', 'Weight',     '5.2 lbs',                  3
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Features',    'Variable Speed','Yes',                   1
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Features',    'LED Indicator','Battery level display',  2
EXEC sp_UpsertModelSpec 'Bad Boy', 'BATTERY', '7530', 'Features',    'Warranty',   '3 years',                  3

-- LS MT125
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Engine',       'Type',          'Diesel 3-Cylinder',    1
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Engine',       'Displacement',  '1.5L',                 2
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Engine',       'Horsepower',    '24.5 HP',              3
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Transmission', 'Type',          'Hydrostatic',          1
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Transmission', 'Speeds',        'Variable',             2
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Dimensions',   'Length',        '108 inches',           1
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Dimensions',   'Width',         '54 inches',            2
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Dimensions',   'Weight',        '2,450 lbs',            3
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Hydraulics',   '3-Point Hitch', 'Category 1',           1
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Hydraulics',   'Lift Capacity', '1,250 lbs',            2
EXEC sp_UpsertModelSpec 'LS', 'MT', 'MT125', 'Hydraulics',   'PTO HP',        '20.5 HP',              3

-- Mahindra 1526
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Engine',       'Type',          'Diesel 3-Cylinder',    1
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Engine',       'Horsepower',    '26 HP',                2
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Engine',       'Fuel Tank',     '6.3 gallons',          3
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Transmission', 'Type',          'Synchro Shuttle',      1
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Transmission', 'Forward Gears', '8',                    2
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Transmission', 'Reverse Gears', '8',                    3
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Dimensions',   'Length',        '115 inches',           1
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Dimensions',   'Width',         '56 inches',            2
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Dimensions',   'Weight',        '2,756 lbs',            3
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Hydraulics',   '3-Point Hitch', 'Category 1',           1
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Hydraulics',   'Lift Capacity', '1,433 lbs',            2
EXEC sp_UpsertModelSpec 'Mahindra', '1500', '1526', 'Hydraulics',   'PTO HP',        '22 HP',                3

GO
PRINT 'Sample data inserted.'
GO


-- =============================================================================
-- 8. VERIFY — quick check to confirm everything looks right
-- =============================================================================
SELECT 'ModelSpec rows'      AS [Table], COUNT(*) AS [Rows] FROM [dbo].[ModelSpec]
UNION ALL
SELECT 'ModelSearchTag rows',            COUNT(*)           FROM [dbo].[ModelSearchTag]
UNION ALL
SELECT 'ModelSpecSource rows',           COUNT(*)           FROM [dbo].[ModelSpecSource]
GO
