-- =============================================================================
-- Update-ModelSpecs-BaseModel.sql
-- Adds BaseModel support to ModelSpec so specs can be shared across
-- all variants of a model family (e.g. all 1626 configs share engine specs).
--
-- Run ONCE in SSMS against [Peach] after Create-ModelSpecs-Tables.sql.
-- =============================================================================

USE [Peach]
GO

-- =============================================================================
-- 1. Add BaseModel column to ModelSpec
--    When populated, this row applies to ALL Model records where
--    Manufacture = Manufacture AND Series = Series AND Model LIKE BaseModel%
--    (or we join on it explicitly in the view).
--    When NULL, the row applies only to the specific Model value.
-- =============================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ModelSpec')
    AND name = 'BaseModel'
)
BEGIN
    ALTER TABLE [dbo].[ModelSpec]
    ADD [BaseModel] VARCHAR(30) NULL
    PRINT 'Added BaseModel column to ModelSpec'
END
ELSE
    PRINT 'BaseModel column already exists'
GO

-- =============================================================================
-- 2. Add BaseModel to ModelSearchTag as well
-- =============================================================================
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.ModelSearchTag')
    AND name = 'BaseModel'
)
BEGIN
    ALTER TABLE [dbo].[ModelSearchTag]
    ADD [BaseModel] VARCHAR(30) NULL
    PRINT 'Added BaseModel column to ModelSearchTag'
END
GO

-- =============================================================================
-- 3. Recreate vw_ModelSpecs to include base-model spec inheritance.
--
--    Logic:
--      A spec row applies to an inventory item when EITHER:
--        (a) ModelSpec.Model matches exactly  (variant-specific override), OR
--        (b) ModelSpec.BaseModel is set and the inventory Model starts with
--            that BaseModel value  (base/family spec)
--
--    Variant-specific rows take priority over base rows for the same
--    Category + SpecLabel combination (handled in PowerShell export or
--    via ROW_NUMBER in the view).
-- =============================================================================
CREATE OR ALTER VIEW [dbo].[vw_ModelSpecs]
AS
    -- Exact-match specs (variant-specific or single-model)
    SELECT
        ms.Manufacture,
        ms.Series,
        ms.Model        AS ForModel,    -- the specific model this applies to
        ms.BaseModel,
        ms.Category,
        ms.SpecLabel,
        ms.SpecValue,
        ms.SortOrder,
        1               AS SpecPriority -- exact match wins over base
    FROM [dbo].[ModelSpec] ms
    INNER JOIN [dbo].[Model] m
        ON  ms.Manufacture = m.Manufacture
        AND ms.Series      = m.Series
        AND ms.Model       = m.Model
    WHERE ms.Active = 1
      AND m.Active  = 1
      AND ms.BaseModel IS NULL          -- exact-match rows have no BaseModel

    UNION ALL

    -- Base-model specs: one spec row fans out to all matching variants
    SELECT
        ms.Manufacture,
        ms.Series,
        m.Model         AS ForModel,    -- the actual variant model
        ms.BaseModel,
        ms.Category,
        ms.SpecLabel,
        ms.SpecValue,
        ms.SortOrder,
        2               AS SpecPriority -- base spec, lower priority
    FROM [dbo].[ModelSpec] ms
    INNER JOIN [dbo].[Model] m
        ON  ms.Manufacture = m.Manufacture
        AND ms.Series      = m.Series
        AND m.Model LIKE ms.BaseModel + '%'  -- e.g. BaseModel='1626' matches 16264FHIL, 16264FSAL, etc.
    WHERE ms.Active   = 1
      AND m.Active    = 1
      AND ms.BaseModel IS NOT NULL
GO

PRINT 'Recreated view: vw_ModelSpecs'
GO

-- =============================================================================
-- 4. Update sp_UpsertModelSpec to accept optional BaseModel parameter.
--    When @BaseModel is supplied, the row is a base/family spec (Model column
--    stores the BaseModel value for the FK, BaseModel column stores it too).
--    When NULL, it's a variant-specific spec as before.
-- =============================================================================
CREATE OR ALTER PROCEDURE [dbo].[sp_UpsertModelSpec]
    @Manufacture  VARCHAR(30),
    @Series       VARCHAR(20),
    @Model        VARCHAR(30),      -- exact model OR base model stub
    @Category     VARCHAR(50),
    @SpecLabel    VARCHAR(100),
    @SpecValue    VARCHAR(200),
    @SortOrder    INT = 0,
    @BaseModel    VARCHAR(30) = NULL  -- pass same value as @Model for base specs
AS
BEGIN
    SET NOCOUNT ON

    -- For base specs: @Model holds one valid FK model in that family,
    -- @BaseModel holds the stub to fan out to all variants.
    -- For variant specs: @BaseModel is NULL.

    IF EXISTS (
        SELECT 1 FROM [dbo].[ModelSpec]
        WHERE Manufacture = @Manufacture
          AND Series      = @Series
          AND Model       = @Model
          AND Category    = @Category
          AND SpecLabel   = @SpecLabel
          AND (BaseModel  = @BaseModel OR (BaseModel IS NULL AND @BaseModel IS NULL))
    )
    BEGIN
        UPDATE [dbo].[ModelSpec]
        SET SpecValue  = @SpecValue,
            SortOrder  = @SortOrder,
            BaseModel  = @BaseModel,
            Active     = 1
        WHERE Manufacture = @Manufacture
          AND Series      = @Series
          AND Model       = @Model
          AND Category    = @Category
          AND SpecLabel   = @SpecLabel
          AND (BaseModel  = @BaseModel OR (BaseModel IS NULL AND @BaseModel IS NULL))
    END
    ELSE
    BEGIN
        INSERT INTO [dbo].[ModelSpec]
            (Manufacture, Series, Model, Category, SpecLabel, SpecValue, SortOrder, BaseModel)
        VALUES
            (@Manufacture, @Series, @Model, @Category, @SpecLabel, @SpecValue, @SortOrder, @BaseModel)
    END
END
GO

PRINT 'Updated procedure: sp_UpsertModelSpec'
GO

-- =============================================================================
-- 5. Remove the 1526 sample data (no longer current stock)
--    and replace with correct 1626 BASE model specs.
--
--    FK requirement: we need ONE valid 1626 model in dbo.Model as the anchor.
--    We use '16264FHIL' (4wd HST Ind Tire w/Loader) as the FK anchor row,
--    but set BaseModel='1626' so specs fan out to ALL 16xx variants.
-- =============================================================================

-- Clean out any 1526 specs inserted earlier
DELETE FROM [dbo].[ModelSpec]
WHERE Manufacture = 'MAH' AND Series = '1500'
PRINT 'Removed any 1526 specs'
GO

-- 1626 BASE specs — engine/hydraulics/dimensions shared by all variants
-- @BaseModel='1626' causes the view to match 16264FHIL, 16264FSAL, 16264FSIL, etc.

EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Engine',       'Type',           'Diesel 3-Cylinder',  1,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Engine',       'Horsepower',     '26 HP',              2,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Engine',       'Displacement',   '1.6L',               3,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Engine',       'Fuel Tank',      '7.4 gallons',        4,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Dimensions',   'Length',         '117 inches',         1,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Dimensions',   'Width',          '57 inches',          2,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Dimensions',   'Weight',         '2,866 lbs',          3,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Hydraulics',   '3-Point Hitch',  'Category 1',         1,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Hydraulics',   'Lift Capacity',  '1,543 lbs',          2,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Hydraulics',   'PTO HP',         '22 HP',              3,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Hydraulics',   'PTO Speed',      '540 RPM',            4,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Features',     '4WD',            'Standard',           1,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Features',     'Power Steering', 'Standard',           2,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Features',     'Diff Lock',      'Rear',               3,  '1626'
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL', 'Features',     'ROPS',           'Foldable',           4,  '1626'
GO

-- 1626 VARIANT-SPECIFIC overrides (no BaseModel — exact model only)
-- Hydrostatic variants
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHIL',  'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHALB', 'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHI',   'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHILB', 'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHILM', 'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHTL',  'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHTLM', 'Transmission', 'Type',    'Hydrostatic (HST)',   1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FHTM',  'Transmission', 'Type',    'Hydrostatic (HST)',   1

-- Shuttle variants
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSA',   'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSAL',  'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSALB', 'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSI',   'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSIL',  'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSILB', 'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSTL',  'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSTLB', 'Transmission', 'Type',    'Shuttle Shift',       1
EXEC sp_UpsertModelSpec 'MAH', '1600', '16264FSRFIL','Transmission', 'Type',    'Shuttle Shift (REF)', 1
GO

-- =============================================================================
-- 6. Verify — show spec counts and a sample of the base-model fan-out
-- =============================================================================
SELECT 'Total ModelSpec rows'    AS Metric, COUNT(*)                    AS Value FROM dbo.ModelSpec
UNION ALL
SELECT 'Base spec rows (1626)',            COUNT(*)
    FROM dbo.ModelSpec WHERE BaseModel = '1626'
UNION ALL
SELECT '1626 variants covered by view',   COUNT(DISTINCT ForModel)
    FROM dbo.vw_ModelSpecs WHERE Manufacture = 'MAH' AND Series = '1600'
GO

-- Show what the view returns for a couple of specific 1626 variants
SELECT ForModel, Category, SpecLabel, SpecValue, SpecPriority
FROM dbo.vw_ModelSpecs
WHERE Manufacture = 'MAH' AND Series = '1600'
  AND ForModel IN ('16264FHIL', '16264FSAL', '16264FHTLM')
ORDER BY ForModel, Category, SortOrder
GO
