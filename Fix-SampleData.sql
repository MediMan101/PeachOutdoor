-- =============================================================================
-- Fix-SampleData.sql
-- Run this ONCE to insert the corrected sample spec data.
-- Uses the exact Manufacture/Series/Model values from your Model table.
-- =============================================================================

USE [Peach]
GO

-- LS MT125  (Manufacture='LS', Series='MT1', Model='MT125')
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Engine',       'Type',          'Diesel 3-Cylinder',    1
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Engine',       'Displacement',  '1.5L',                 2
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Engine',       'Horsepower',    '24.5 HP',              3
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Transmission', 'Type',          'Hydrostatic',          1
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Transmission', 'Speeds',        'Variable',             2
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Dimensions',   'Length',        '108 inches',           1
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Dimensions',   'Width',         '54 inches',            2
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Dimensions',   'Weight',        '2,450 lbs',            3
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Hydraulics',   '3-Point Hitch', 'Category 1',           1
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Hydraulics',   'Lift Capacity', '1,250 lbs',            2
EXEC sp_UpsertModelSpec 'LS', 'MT1', 'MT125', 'Hydraulics',   'PTO HP',        '20.5 HP',              3
GO

-- Verify
SELECT Manufacture, Series, Model, Category, SpecLabel, SpecValue
FROM dbo.ModelSpec
ORDER BY Manufacture, Series, Model, Category, SortOrder
GO

-- =============================================================================
-- TODO - Add Bad Boy and Mahindra once Series confirmed.
-- Run this to see their exact values:
--
-- SELECT Manufacture, Series, Model, Description
-- FROM dbo.Model
-- WHERE Manufacture IN ('BAD', 'MAH')
-- ORDER BY Manufacture, Series, Model
-- =============================================================================
