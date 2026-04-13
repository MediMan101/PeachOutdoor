# =============================================================================
# Sync-Inventory.ps1
# Peach Outdoor - Export inventory + specs from [Peach] database to GitHub
#
# Outputs two files:
#   inventory.json  - all web-enabled inventory items
#   specs.json      - model specs from ModelSpec table
# =============================================================================

param(
    [string]$SqlServer    = "localhost\MCSSQLEXPRESS",
    [string]$Database     = "Peach",
    [string]$RepoPath     = "C:\Users\John Pierce\Documents\GitHub\PeachOutdoor",
    [string]$GitExe       = "C:\Program Files\Git\bin\git.exe",
    [switch]$Force        = $false
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$timestamp] Starting Peach Outdoor sync..." -ForegroundColor Cyan

# ── Helper: run SQL and return DataTable ──────────────────────────────────────
function Invoke-SQL {
    param([string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 120
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt = New-Object System.Data.DataTable
    $adapter.Fill($dt) | Out-Null
    $conn.Close()
    return $dt
}

# =============================================================================
# STEP 1 — Export inventory.json
# Uses WebDisplay (ShowOnWeb/FeaturedItem), WebPricing (Web_Price),
# InventoryPhotos (photos), and Vendor (full manufacturer name)
# =============================================================================
Write-Host "  Querying inventory..." -ForegroundColor Gray

$inventorySQL = @"
SELECT
    i.InventoryID,
    ISNULL(v.Name, i.MFG)          AS Manufacturer,
    ISNULL(i.Dept, '')             AS Department,
    ISNULL(i.Series, '')           AS Series,
    ISNULL(i.Model, '')            AS Model,
    ISNULL(i.Description, '')      AS Description,
    ISNULL(i.Serial_Number, '')    AS SerialNumber,
    ISNULL(i.Location, '')         AS Location,
    i.MSRP,
    wp.Web_Price,
    CAST(ISNULL(i.Used, 0) AS INT) AS Used,
    ISNULL(i.Notes, '')            AS Notes,
    ISNULL(wd.FeaturedItem, 0)     AS FeaturedItem,
    (
        SELECT TOP 1 PhotoURL
        FROM dbo.InventoryPhotos
        WHERE InventoryID = i.InventoryID
          AND IsPrimary = 1
    ) AS PrimaryPhotoURL
FROM dbo.Inventory i
INNER JOIN dbo.WebDisplay wd
    ON wd.InventoryID = i.InventoryID
    AND wd.ShowOnWeb = 1
LEFT JOIN dbo.WebPricing wp
    ON wp.InventoryID = i.InventoryID
    AND wp.IsActive = 1
    AND wp.EffectiveDate = (
        SELECT MAX(EffectiveDate)
        FROM dbo.WebPricing
        WHERE InventoryID = i.InventoryID
          AND IsActive = 1
    )
LEFT JOIN dbo.Vendor v
    ON v.VendorID = i.MFG
WHERE (i.Quantity - ISNULL(i.QuantitySold, 0)) > 0
  AND ISNULL(i.Deleted, 0)          = 0
  AND ISNULL(i.Attachment, 0)       = 0
  AND ISNULL(i.NonInventoryItem, 0) = 0
  AND ISNULL(i.IsLinkedItem, 0)     = 0
ORDER BY wd.FeaturedItem DESC, v.Name, i.Dept, i.Model
"@

# Photos query — all photos per item ordered by primary first then sort order
$photosSQL = @"
SELECT InventoryID, PhotoURL
FROM dbo.InventoryPhotos
ORDER BY InventoryID, IsPrimary DESC, SortOrder ASC
"@

$inventoryRows = Invoke-SQL -Query $inventorySQL
$photoRows     = Invoke-SQL -Query $photosSQL

# Build photo lookup: InventoryID -> [url, url, ...]
$photoLookup = @{}
foreach ($row in $photoRows) {
    $id = [int]$row.InventoryID
    if (-not $photoLookup.ContainsKey($id)) { $photoLookup[$id] = @() }
    $photoLookup[$id] += [string]$row.PhotoURL
}

# Build inventory array
$inventoryList = @()
foreach ($row in $inventoryRows) {
    $id = [int]$row.InventoryID
    $item = [ordered]@{
        InventoryID     = $id
        Manufacturer    = [string]$row.Manufacturer
        Department      = [string]$row.Department
        Series          = [string]$row.Series
        Model           = [string]$row.Model
        Description     = [string]$row.Description
        SerialNumber    = [string]$row.SerialNumber
        Location        = [string]$row.Location
        MSRP            = if ($row.MSRP    -is [DBNull]) { $null } else { [double]$row.MSRP }
        Web_Price       = if ($row.Web_Price -is [DBNull]) { $null } else { [double]$row.Web_Price }
        Used            = ([int]$row.Used -eq 1)
        FeaturedItem    = ([int]$row.FeaturedItem -eq 1)
        Notes           = [string]$row.Notes
        PrimaryPhotoURL = if ($row.PrimaryPhotoURL -is [DBNull]) { $null } else { [string]$row.PrimaryPhotoURL }
        AllPhotos       = if ($photoLookup.ContainsKey($id)) { $photoLookup[$id] } else { @() }
    }
    $inventoryList += $item
}

$inventoryJson = $inventoryList | ConvertTo-Json -Depth 5
$inventoryPath = Join-Path $RepoPath "inventory.json"
$inventoryJson | Set-Content -Path $inventoryPath -Encoding UTF8
Write-Host "  Exported $($inventoryList.Count) inventory items." -ForegroundColor Green

# =============================================================================
# STEP 2 — Export specs.json from ModelSpec table
# =============================================================================
Write-Host "  Querying model specs..." -ForegroundColor Gray

$specsSQL = @"
SELECT
    ms.Manufacture,
    ms.Series,
    ms.ForModel     AS Model,
    ms.Category,
    ms.SpecLabel,
    ms.SpecValue,
    ms.SortOrder,
    ms.SpecPriority
FROM dbo.vw_ModelSpecs ms
ORDER BY ms.Manufacture, ms.Series, ms.ForModel, ms.Category, ms.SortOrder, ms.SpecLabel
"@

$specRows = Invoke-SQL -Query $specsSQL

$specsByModel    = @{}
$specsByModelPri = @{}

foreach ($row in $specRows) {
    $key = "$($row.Manufacture)||$($row.Series)||$($row.Model)"
    if (-not $specsByModel.ContainsKey($key)) {
        $specsByModel[$key] = @{
            Manufacturer = $row.Manufacture
            Series       = $row.Series
            Model        = $row.Model
            Specs        = [ordered]@{}
        }
        $specsByModelPri[$key] = @{}
    }

    $cat      = $row.Category
    $label    = $row.SpecLabel
    $priority = [int]$row.SpecPriority

    if (-not $specsByModel[$key].Specs.ContainsKey($cat)) {
        $specsByModel[$key].Specs[$cat]  = [ordered]@{}
        $specsByModelPri[$key][$cat]     = @{}
    }

    $existingPri = $specsByModelPri[$key][$cat][$label]
    if (-not $existingPri -or $priority -lt $existingPri) {
        $specsByModel[$key].Specs[$cat][$label]  = $row.SpecValue
        $specsByModelPri[$key][$cat][$label]     = $priority
    }
}

$specsList = $specsByModel.Values | Sort-Object { $_.Manufacturer }, { $_.Model }
$specsJson = $specsList | ConvertTo-Json -Depth 6
$specsPath = Join-Path $RepoPath "specs.json"
$specsJson | Set-Content -Path $specsPath -Encoding UTF8
Write-Host "  Exported $($specsList.Count) model spec sets." -ForegroundColor Green

# =============================================================================
# STEP 3 — Git commit and push (only if files changed)
# =============================================================================
Write-Host "  Checking for changes..." -ForegroundColor Gray

Set-Location $RepoPath
$gitStatus = & $GitExe status --porcelain 2>&1

if ($gitStatus -or $Force) {
    Write-Host "  Changes detected — committing..." -ForegroundColor Yellow
    & $GitExe add inventory.json specs.json
    $commitMsg = "Auto-sync inventory + specs $((Get-Date -Format 'yyyy-MM-dd HH:mm'))"
    & $GitExe commit -m $commitMsg
    & $GitExe push
    Write-Host "  Pushed to GitHub. Netlify will deploy automatically." -ForegroundColor Green
} else {
    Write-Host "  No changes — skipping push." -ForegroundColor Gray
}

Write-Host "[$((Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))] Sync complete." -ForegroundColor Cyan
