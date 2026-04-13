-- =============================================================================
-- Fix-SampleData.sql
-- Corrected sample spec inserts using exact Manufacture/Series/Model values
-- from the Peach Model table.
--
--   BAD  = Bad Boy
--   LS   = LS Tractor
--   MAH  = Mahindra
-- =============================================================================

USE [Peach]
GO

-- -----------------------------------------------------------------------------
-- BAD / BATTERY / 7530  (Bad Boy 80V 2.5 Ah Battery)
-- -----------------------------------------------------------------------------
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Engine',      'Type',          'Brushless Electric Motor', 1
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Engine',      'Voltage',       '80V',                      2
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Engine',      'Battery',       '2.5 Ah Lithium-Ion',       3
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Performance', 'Runtime',       'Up to 45 minutes',         1
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Performance', 'Charge Time',   '60 minutes',               2
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Performance', 'Weight',        '5.2 lbs',                  3
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Features',    'Variable Speed','Yes',                      1
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Features',    'LED Indicator', 'Battery level display',    2
EXEC sp_UpsertModelSpec 'BAD', 'BATTERY', '7530', 'Features',    'Warranty',      '3 years',                  3
GO

-- -----------------------------------------------------------------------------
-- LS / MT1 / MT125  (LS Tractor MT125 4wd)
-- -----------------------------------------------------------------------------
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

-- -----------------------------------------------------------------------------
-- MAH / 1500 / 15264FHIL  (Mahindra 1526 4wd HST Ind Tire w/Loader)
-- Using the base 1526 hydrostatic config as the spec representative for
-- all 1526 variants — specs are engine/transmission level, not config level.
-- -----------------------------------------------------------------------------
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Engine',       'Type',          'Diesel 3-Cylinder',    1
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Engine',       'Horsepower',    '26 HP',                2
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Engine',       'Fuel Tank',     '6.3 gallons',          3
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Transmission', 'Type',          'Hydrostatic',          1
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Dimensions',   'Length',        '115 inches',           1
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Dimensions',   'Width',         '56 inches',            2
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Dimensions',   'Weight',        '2,756 lbs',            3
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Hydraulics',   '3-Point Hitch', 'Category 1',           1
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Hydraulics',   'Lift Capacity', '1,433 lbs',            2
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Hydraulics',   'PTO HP',        '22 HP',                3
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Hydraulics',   'PTO Speed',     '540 RPM',              4
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Features',     '4WD',           'Yes',                  1
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Features',     'Power Steering','Standard',             2
EXEC sp_UpsertModelSpec 'MAH', '1500', '15264FHIL', 'Features',     'ROPS',          'Foldable',             3
GO

-- -----------------------------------------------------------------------------
-- Verify
-- -----------------------------------------------------------------------------
SELECT
    Manufacture,
    Series,
    Model,
    Category,
    SpecLabel,
    SpecValue
FROM dbo.ModelSpec
ORDER BY Manufacture, Series, Model, Category, SortOrder
GO

SELECT 'ModelSpec rows' AS [Table], COUNT(*) AS [Count] FROM dbo.ModelSpec
UNION ALL
SELECT 'Models with specs', COUNT(DISTINCT Model) FROM dbo.ModelSpec
GO
