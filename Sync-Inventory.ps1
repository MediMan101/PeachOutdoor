# =============================================================================
# Sync-Inventory.ps1
# Peach Outdoor - Export inventory + specs to GitHub via API
#
# Runs on Windows Server — no Git install required.
# Pushes inventory.json and specs.json directly to GitHub via HTTPS API.
# Netlify detects the push and deploys automatically.
#
# Location: C:\WebSiteScripts\Sync-Inventory.ps1
# =============================================================================

# ── CONFIGURATION ─────────────────────────────────────────────────────────────

$GitHubToken  = "YOUR_GITHUB_TOKEN_HERE"
$GitHubOwner  = "MediMan101"
$GitHubRepo   = "PeachOutdoor"
$GitHubBranch = "main"

$SqlServer    = "localhost\MCSSQLEXPRESS"
$Database     = "Peach"

$LogFile      = "C:\WebSiteScripts\Logs\sync-inventory.log"

# ── LOGGING ───────────────────────────────────────────────────────────────────

$LogDir = Split-Path $LogFile
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    $color = if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } else { "Cyan" }
    Write-Host $entry -ForegroundColor $color
}

# ── HELPER: Run SQL query, return DataTable ───────────────────────────────────

function Invoke-SQL {
    param([string]$Query)
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"
    $conn.Open()
    $cmd             = $conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 120
    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt      = New-Object System.Data.DataTable
    $adapter.Fill($dt) | Out-Null
    $conn.Close()
    return $dt
}

# ── HELPER: Push multiple files in one commit via Git Tree API ───────────────
# One commit = one Netlify build trigger

function Push-GitHubFiles {
    param(
        [hashtable]$Files,     # @{ "filename.json" = "content string" }
        [string]$CommitMsg
    )

    $headers = @{
        "Authorization"        = "Bearer $GitHubToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $baseUrl = "https://api.github.com/repos/$GitHubOwner/$GitHubRepo"

    # 1. Get current branch SHA
    $branchData = Invoke-RestMethod -Uri "$baseUrl/git/ref/heads/$GitHubBranch" -Headers $headers
    $latestSha  = $branchData.object.sha

    # 2. Get current tree SHA
    $commitData = Invoke-RestMethod -Uri "$baseUrl/git/commits/$latestSha" -Headers $headers
    $treeSha    = $commitData.tree.sha

    # 3. Create blobs for each file
    $treeItems = @()
    foreach ($filePath in $Files.Keys) {
        $encoded = [System.Convert]::ToBase64String(
            [System.Text.Encoding]::UTF8.GetBytes($Files[$filePath])
        )
        $blobBody = @{ content = $encoded; encoding = "base64" } | ConvertTo-Json
        $blob = Invoke-RestMethod -Uri "$baseUrl/git/blobs" -Headers $headers `
                    -Method Post -Body $blobBody -ContentType "application/json"
        $treeItems += @{ path = $filePath; mode = "100644"; type = "blob"; sha = $blob.sha }
    }

    # 4. Create new tree
    $newTreeBody = @{ base_tree = $treeSha; tree = $treeItems } | ConvertTo-Json -Depth 5
    $newTree = Invoke-RestMethod -Uri "$baseUrl/git/trees" -Headers $headers `
                    -Method Post -Body $newTreeBody -ContentType "application/json"

    # 5. Create commit
    $newCommitBody = @{
        message = $CommitMsg
        tree    = $newTree.sha
        parents = @($latestSha)
    } | ConvertTo-Json
    $newCommit = Invoke-RestMethod -Uri "$baseUrl/git/commits" -Headers $headers `
                    -Method Post -Body $newCommitBody -ContentType "application/json"

    # 6. Update branch ref
    $updateRefBody = @{ sha = $newCommit.sha; force = $false } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/git/refs/heads/$GitHubBranch" -Headers $headers `
        -Method Patch -Body $updateRefBody -ContentType "application/json" | Out-Null

    Write-Log "Pushed $($Files.Count) files in single commit. One Netlify build triggered."
}

# =============================================================================
# STEP 1 — Build inventory.json
# =============================================================================
Write-Log "===== Sync-Inventory started ====="
Write-Log "Querying inventory..."

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
       SELECT MAX(EffectiveDate) FROM dbo.WebPricing
       WHERE InventoryID = i.InventoryID AND IsActive = 1
   )
LEFT JOIN dbo.Vendor v ON v.VendorID = i.MFG
WHERE (i.Quantity - ISNULL(i.QuantitySold, 0)) > 0
  AND ISNULL(i.Deleted, 0)          = 0
  AND ISNULL(i.Attachment, 0)       = 0
  AND ISNULL(i.NonInventoryItem, 0) = 0
  AND ISNULL(i.IsLinkedItem, 0)     = 0
ORDER BY wd.FeaturedItem DESC, v.Name, i.Dept, i.Model
"@

$photosSQL = @"
SELECT InventoryID, PhotoURL
FROM dbo.InventoryPhotos
ORDER BY InventoryID, IsPrimary DESC, SortOrder ASC
"@

try {
    $inventoryRows = Invoke-SQL -Query $inventorySQL
    $photoRows     = Invoke-SQL -Query $photosSQL
} catch {
    Write-Log "ERROR querying database: $($_.Exception.Message)" "ERROR"
    exit 1
}

# Build photo lookup: InventoryID -> [url, url, ...]
$photoLookup = @{}
foreach ($row in $photoRows) {
    $id = [int]$row.InventoryID
    if (-not $photoLookup.ContainsKey($id)) { $photoLookup[$id] = @() }
    $photoLookup[$id] += [string]$row.PhotoURL
}

# Build inventory list
$inventoryList = @()
foreach ($row in $inventoryRows) {
    $id = [int]$row.InventoryID
    $inventoryList += [PSCustomObject]@{
        InventoryID     = $id
        Manufacturer    = [string]$row.Manufacturer
        Department      = [string]$row.Department
        Series          = [string]$row.Series
        Model           = [string]$row.Model
        Description     = [string]$row.Description
        SerialNumber    = [string]$row.SerialNumber
        Location        = [string]$row.Location
        MSRP            = if ($row.MSRP      -is [DBNull]) { $null } else { [double]$row.MSRP }
        Web_Price       = if ($row.Web_Price -is [DBNull]) { $null } else { [double]$row.Web_Price }
        Used            = ([int]$row.Used -eq 1)
        FeaturedItem    = ([int]$row.FeaturedItem -eq 1)
        Notes           = [string]$row.Notes
        PrimaryPhotoURL = if ($row.PrimaryPhotoURL -is [DBNull]) { $null } else { [string]$row.PrimaryPhotoURL }
        AllPhotos       = if ($photoLookup.ContainsKey($id)) { $photoLookup[$id] } else { @() }
    }
}

$inventoryJson = $inventoryList | ConvertTo-Json -Depth 5
Write-Log "Inventory built: $($inventoryList.Count) items."

# =============================================================================
# STEP 2 — Build specs.json
# =============================================================================
Write-Log "Querying model specs..."

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

try {
    $specRows = Invoke-SQL -Query $specsSQL
} catch {
    Write-Log "ERROR querying specs: $($_.Exception.Message)" "WARN"
    $specRows = @()
}

$specsByModel    = @{}
$specsByModelPri = @{}

foreach ($row in $specRows) {
    $mfg      = [string]$row["Manufacture"]
    $ser      = [string]$row["Series"]
    $mod      = [string]$row["Model"]
    $cat      = [string]$row["Category"]
    $label    = [string]$row["SpecLabel"]
    $val      = [string]$row["SpecValue"]
    $priority = [int]$row["SpecPriority"]

    $key = "$mfg||$ser||$mod"

    if (-not $specsByModel.ContainsKey($key)) {
        $specsByModel[$key] = @{
            Manufacturer = $mfg
            Series       = $ser
            Model        = $mod
            Specs        = @{}
        }
        $specsByModelPri[$key] = @{}
    }

    if (-not $specsByModel[$key].Specs.ContainsKey($cat)) {
        $specsByModel[$key].Specs[$cat]  = @{}
        $specsByModelPri[$key][$cat]     = @{}
    }

    $existingPri = $specsByModelPri[$key][$cat][$label]
    if (-not $existingPri -or $priority -lt [int]$existingPri) {
        $specsByModel[$key].Specs[$cat][$label]  = $val
        $specsByModelPri[$key][$cat][$label]     = $priority
    }
}

$specsList = $specsByModel.Values | Sort-Object { $_.Manufacturer }, { $_.Model }
$specsJson = $specsList | ConvertTo-Json -Depth 6
Write-Log "Specs built: $($specsList.Count) model spec sets."

# =============================================================================
# STEP 3 — Push both files to GitHub
# =============================================================================
$commitMsg = "Auto-sync inventory + specs $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

try {
    Push-GitHubFiles -Files @{
        "inventory.json" = $inventoryJson
        "specs.json"     = $specsJson
    } -CommitMsg $commitMsg
    Write-Log "Netlify will deploy automatically."
} catch {
    Write-Log "ERROR pushing to GitHub: $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Log "===== Sync-Inventory completed successfully ====="
