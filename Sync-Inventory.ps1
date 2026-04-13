# =============================================================================
# Sync-Inventory.ps1
# Peach Outdoor - Export inventory + specs from [Peach] database to GitHub
#
# Outputs two files:
#   inventory.json  - all available inventory items (existing)
#   specs.json      - model specs from ModelSpec table (updated to pull from DB)
#
# Schedule with Windows Task Scheduler to run automatically.
# =============================================================================

param(
    [string]$SqlServer    = "localhost\MCSSQLEXPRESS",
    [string]$Database     = "Peach",
    [string]$RepoPath     = "C:\GitHub\PeachOutdoor",
    [string]$GitExe       = "C:\Program Files\Git\bin\git.exe",
    [switch]$Force        = $false   # push even if nothing changed
)

$ErrorActionPreference = "Stop"
$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
Write-Host "[$timestamp] Starting Peach Outdoor sync..." -ForegroundColor Cyan

# ── Helper: run a SQL query and return DataTable ──────────────────────────────
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
# =============================================================================
Write-Host "  Querying inventory..." -ForegroundColor Gray

$inventorySQL = @"
SELECT
    i.InventoryID,
    i.MFG           AS Manufacturer,
    i.Dept          AS Department,
    i.Series,
    i.Model,
    i.Description,
    i.Serial_Number AS SerialNumber,
    i.Location,
    i.MSRP,
    i.Web_Price,
    CAST(CASE WHEN i.Used = 1 THEN 1 ELSE 0 END AS BIT) AS Used,
    CAST(CASE WHEN i.FeaturedItem = 1 THEN 1 ELSE 0 END AS BIT) AS FeaturedItem,
    ISNULL(i.Notes, '') AS Notes,
    i.PrimaryPhotoURL,
    i.AllPhotos
FROM dbo.Inventory i
WHERE (i.Quantity - ISNULL(i.QuantitySold, 0)) > 0
  AND i.Deleted   = 0
  AND i.NonInventoryItem = 0
ORDER BY i.MFG, i.Model
"@

$inventoryRows = Invoke-SQL -Query $inventorySQL

# Build inventory array
$inventoryList = @()
foreach ($row in $inventoryRows) {
    $item = [ordered]@{
        InventoryID     = $row.InventoryID
        Manufacturer    = $row.Manufacturer
        Department      = $row.Department
        Series          = $row.Series
        Model           = $row.Model
        Description     = $row.Description
        SerialNumber    = $row.SerialNumber
        Location        = $row.Location
        MSRP            = if ($row.MSRP   -is [DBNull]) { $null } else { [double]$row.MSRP }
        Web_Price       = if ($row.Web_Price -is [DBNull]) { $null } else { [double]$row.Web_Price }
        Used            = [bool]$row.Used
        FeaturedItem    = [bool]$row.FeaturedItem
        Notes           = $row.Notes
        PrimaryPhotoURL = if ($row.PrimaryPhotoURL -is [DBNull]) { $null } else { $row.PrimaryPhotoURL }
        AllPhotos       = if ($row.AllPhotos -is [DBNull]) { @() } else {
                              $row.AllPhotos -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
                          }
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
    ms.Model,
    ms.Category,
    ms.SpecLabel,
    ms.SpecValue,
    ms.SortOrder
FROM dbo.vw_ModelSpecs ms
ORDER BY ms.Manufacture, ms.Series, ms.Model, ms.Category, ms.SortOrder, ms.SpecLabel
"@

$specRows = Invoke-SQL -Query $specsSQL

# Group into nested structure: [ { Manufacturer, Model, Specs: { Category: { Label: Value } } } ]
$specsByModel = @{}
foreach ($row in $specRows) {
    $key = "$($row.Manufacture)||$($row.Series)||$($row.Model)"
    if (-not $specsByModel.ContainsKey($key)) {
        $specsByModel[$key] = @{
            Manufacturer = $row.Manufacture
            Series       = $row.Series
            Model        = $row.Model
            Specs        = [ordered]@{}
        }
    }
    $cat = $row.Category
    if (-not $specsByModel[$key].Specs.ContainsKey($cat)) {
        $specsByModel[$key].Specs[$cat] = [ordered]@{}
    }
    $specsByModel[$key].Specs[$cat][$row.SpecLabel] = $row.SpecValue
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
