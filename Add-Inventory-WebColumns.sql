-- =============================================================================
-- Add-Inventory-WebColumns.sql
-- Adds the four web-facing columns to the Inventory table.
-- Run ONCE on the Peach production database.
-- All columns are nullable so existing rows are unaffected.
-- =============================================================================

USE [Peach]
GO

-- Web_Price: the price shown on the website. NULL = "Call for Price"
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.Inventory') AND name = 'Web_Price'
)
BEGIN
    ALTER TABLE [dbo].[Inventory]
    ADD [Web_Price] DECIMAL(19,4) NULL
    PRINT 'Added: Web_Price'
END
ELSE
    PRINT 'Already exists: Web_Price'
GO

-- FeaturedItem: flag to highlight item on the home page / featured section
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.Inventory') AND name = 'FeaturedItem'
)
BEGIN
    ALTER TABLE [dbo].[Inventory]
    ADD [FeaturedItem] BIT NOT NULL DEFAULT(0)
    PRINT 'Added: FeaturedItem'
END
ELSE
    PRINT 'Already exists: FeaturedItem'
GO

-- PrimaryPhotoURL: Cloudinary URL of the main display photo
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.Inventory') AND name = 'PrimaryPhotoURL'
)
BEGIN
    ALTER TABLE [dbo].[Inventory]
    ADD [PrimaryPhotoURL] VARCHAR(500) NULL
    PRINT 'Added: PrimaryPhotoURL'
END
ELSE
    PRINT 'Already exists: PrimaryPhotoURL'
GO

-- AllPhotos: comma-separated list of all Cloudinary photo URLs for the item
IF NOT EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.Inventory') AND name = 'AllPhotos'
)
BEGIN
    ALTER TABLE [dbo].[Inventory]
    ADD [AllPhotos] VARCHAR(MAX) NULL
    PRINT 'Added: AllPhotos'
END
ELSE
    PRINT 'Already exists: AllPhotos'
GO

-- Verify all four columns are present
SELECT
    COLUMN_NAME,
    DATA_TYPE,
    CHARACTER_MAXIMUM_LENGTH,
    IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_NAME = 'Inventory'
  AND COLUMN_NAME IN ('Web_Price','FeaturedItem','PrimaryPhotoURL','AllPhotos')
ORDER BY COLUMN_NAME
GO
