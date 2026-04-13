-- =============================================================================
-- Fix-SpecsView.sql
-- The base model fan-out in vw_ModelSpecs is only returning the anchor model
-- (16264FHIL) instead of all 1626 variants. This is because BaseModel='1626'
-- but model numbers are like '16264FHIL' - the LIKE '1626%' should match
-- but the join is only on the anchor model's own Series/Manufacture.
--
-- Fix: The base spec rows all have Model='16264FHIL' (the FK anchor).
-- The LIKE join needs to match ANY model in the same Manufacture+Series
-- where the model number starts with the BaseModel value.
-- =============================================================================

USE [Peach]
GO

-- Verify the fan-out is broken - should return rows for ALL 1626 variants
-- If this only returns 16264FHIL rows, the view is broken
SELECT COUNT(DISTINCT ForModel) AS VariantsCovered
FROM dbo.vw_ModelSpecs
WHERE Manufacture = 'MAH' AND Series = '1600'
GO

-- Recreate the view with corrected fan-out logic
CREATE OR ALTER VIEW [dbo].[vw_ModelSpecs]
AS
    -- Exact-match specs (variant-specific, no BaseModel set)
    SELECT
        ms.Manufacture,
        ms.Series,
        ms.Model        AS ForModel,
        ms.BaseModel,
        ms.Category,
        ms.SpecLabel,
        ms.SpecValue,
        ms.SortOrder,
        1               AS SpecPriority
    FROM [dbo].[ModelSpec] ms
    INNER JOIN [dbo].[Model] m
        ON  ms.Manufacture = m.Manufacture
        AND ms.Series      = m.Series
        AND ms.Model       = m.Model
    WHERE ms.Active   = 1
      AND m.Active    = 1
      AND ms.BaseModel IS NULL

    UNION ALL

    -- Base-model fan-out: join ALL models in same Manufacture+Series
    -- where the model number starts with BaseModel value
    SELECT
        ms.Manufacture,
        ms.Series,
        m.Model         AS ForModel,   -- the actual variant
        ms.BaseModel,
        ms.Category,
        ms.SpecLabel,
        ms.SpecValue,
        ms.SortOrder,
        2               AS SpecPriority
    FROM [dbo].[ModelSpec] ms
    INNER JOIN [dbo].[Model] m
        ON  ms.Manufacture = m.Manufacture
        AND ms.Series      = m.Series
        AND m.Model LIKE ms.BaseModel + '%'
    WHERE ms.Active      = 1
      AND m.Active       = 1
      AND ms.BaseModel   IS NOT NULL
GO

-- Verify fix - should now return all 1626 variants
SELECT COUNT(DISTINCT ForModel) AS VariantsCovered
FROM dbo.vw_ModelSpecs
WHERE Manufacture = 'MAH' AND Series = '1600'
GO

-- Spot check - should see full specs for 16264FSIL (the shuttle item)
SELECT ForModel, Category, SpecLabel, SpecValue, SpecPriority
FROM dbo.vw_ModelSpecs
WHERE Manufacture = 'MAH' AND Series = '1600'
  AND ForModel IN ('16264FSIL', '16264FHIL', '16264FSAL')
ORDER BY ForModel, SpecPriority, Category, SortOrder
GO
