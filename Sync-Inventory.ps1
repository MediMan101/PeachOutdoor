# =============================================================================
# Sync-Inventory.ps1
# Peach Outdoor - Export inventory + specs to GitHub via API
#
# Runs on Windows Server - no Git install required.
# Pushes inventory.json and specs.json directly to GitHub via HTTPS API.
# Netlify detects the push and deploys automatically.
#
# Location: C:\WebSiteScripts\Sync-Inventory.ps1
# =============================================================================

# -- CONFIGURATION -------------------------------------------------------------
# Credentials and secrets are stored in a separate config file that is NOT
# pushed to GitHub. Create C:\WebSiteScripts\sync-config.ps1 on the server
# with the values shown below, then this script reads them from there.

$ConfigFile = Join-Path $PSScriptRoot "sync-config.ps1"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERROR] Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Create that file with the following content:" -ForegroundColor Yellow
    Write-Host '  $GitHubToken  = "your-github-token"' -ForegroundColor Yellow
    Write-Host '  $CloudApiKey  = "your-cloudinary-api-key"' -ForegroundColor Yellow
    Write-Host '  $CloudSecret  = "your-cloudinary-secret"' -ForegroundColor Yellow
    exit 1
}
. $ConfigFile

# Non-secret configuration (safe to store in GitHub)
$GitHubOwner  = "MediMan101"
$GitHubRepo   = "PeachOutdoor"
$GitHubBranch = "main"

$SqlServer    = "localhost\MCSSQLEXPRESS"
$Database     = "Peach"

$LogFile      = Join-Path $PSScriptRoot "Logs\sync-inventory.log"

$CloudName    = "dtidlilrj"
$PhotosFolder = "C:\inetpub\wwwroot\inventoryapp\photos"

# -- LOGGING -------------------------------------------------------------------

$LogDir = Split-Path $LogFile
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $LogFile -Value $entry
    $color = if ($Level -eq "ERROR") { "Red" } elseif ($Level -eq "WARN") { "Yellow" } else { "Cyan" }
    Write-Host $entry -ForegroundColor $color
}

# -- HELPER: Run SQL query, return DataTable -----------------------------------

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

function Invoke-SQLNonQuery {
    param([string]$Query, [hashtable]$Params = @{})
    $conn = New-Object System.Data.SqlClient.SqlConnection
    $conn.ConnectionString = "Server=$SqlServer;Database=$Database;Integrated Security=True;"
    $conn.Open()
    $cmd = $conn.CreateCommand()
    $cmd.CommandText = $Query
    $cmd.CommandTimeout = 60
    foreach ($p in $Params.GetEnumerator()) {
        $cmd.Parameters.AddWithValue($p.Key, $p.Value) | Out-Null
    }
    $result = $cmd.ExecuteNonQuery()
    $conn.Close()
    return $result
}

# -- HELPER: Push multiple files in one commit via Git Tree API ---------------
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
# STEP 0 - Promote real photos: if an item has both a real photo AND a default
#          photo, delete the default from InventoryPhotos (and Cloudinary).
#          This runs automatically every sync so defaults are cleaned up the
#          moment a real photo is uploaded via SalesMan.
# =============================================================================
Write-Log "===== Sync-Inventory started ====="
Write-Log "Checking for default photos that can be replaced by real photos..."

$defaultsToRemoveSQL = @"
SELECT ip.PhotoID, ip.PublicID
FROM dbo.InventoryPhotos ip
WHERE ip.IsDefault = 1
  AND EXISTS (
      SELECT 1 FROM dbo.InventoryPhotos ip2
      WHERE ip2.InventoryID = ip.InventoryID
        AND ip2.IsDefault   = 0
  )
"@

try {
    $defaultsToRemove = Invoke-SQL -Query $defaultsToRemoveSQL
    if ($defaultsToRemove.Rows.Count -gt 0) {
        Write-Log "Found $($defaultsToRemove.Rows.Count) default photo(s) to remove (real photos now exist)."
        foreach ($row in $defaultsToRemove) {
            $photoId  = [int]$row["PhotoID"]
            $publicId = [string]$row["PublicID"]

            try {
                Invoke-SQLNonQuery -Query "DELETE FROM dbo.InventoryPhotos WHERE PhotoID = @pid" `
                    -Params @{ "@pid" = $photoId } | Out-Null
                Write-Log "  Removed default photo record ID ${photoId} (PublicID: ${publicId})"
            } catch {
                Write-Log "  WARN: Could not remove default photo ID ${photoId}: $($_.Exception.Message)" "WARN"
            }
        }
    } else {
        Write-Log "No default photos need replacing."
    }
} catch {
    Write-Log "WARN: Could not check for default photos to replace: $($_.Exception.Message)" "WARN"
}


# =============================================================================
# STEP 0.5 - Scan IIS photos folder and upload new photos to Cloudinary
#            Skips any photo already recorded in InventoryPhotos
# =============================================================================

if ($CloudName -and $CloudApiKey -and $CloudSecret -and (Test-Path $PhotosFolder)) {

    Write-Log "Scanning IIS photos folder for new photos..."

    # Load all already-uploaded photo public IDs to avoid re-uploading
    $existingPublicIds = @{}
    try {
        $existingRows = Invoke-SQL -Query "SELECT PublicID FROM dbo.InventoryPhotos WHERE IsDefault = 0"
        foreach ($r in $existingRows) {
            $existingPublicIds[[string]$r["PublicID"]] = $true
        }
        Write-Log "Found $($existingPublicIds.Count) existing real photo records."
    } catch {
        Write-Log "WARN: Could not load existing photo records: $($_.Exception.Message)" "WARN"
    }

    # Walk each InventoryID_Serial folder
    $itemFolders = Get-ChildItem -Path $PhotosFolder -Directory
    $uploadedCount = 0
    $skippedCount  = 0
    $errorCount    = 0

    foreach ($folder in $itemFolders) {
        # Parse InventoryID from folder name (format: InventoryID_SerialNumber)
        $parts = $folder.Name -split '_', 2
        if ($parts.Count -lt 1 -or -not ($parts[0] -match '^\d+$')) {
            Write-Log "  Skipping unrecognised folder: $($folder.Name)" "WARN"
            continue
        }
        $inventoryId = [int]$parts[0]

        # Get existing photos for this inventory item to determine sort order
        $existingCountRows = Invoke-SQL -Query "SELECT COUNT(*) AS C FROM dbo.InventoryPhotos WHERE InventoryID = $inventoryId AND IsDefault = 0"
        $existingCount = [int]$existingCountRows[0]["C"]

        # Get all image files in this folder
        $photoFiles = Get-ChildItem -Path $folder.FullName -File |
            Where-Object { $_.Extension -match '\.(jpg|jpeg|png|webp|gif)$' } |
            Sort-Object Name

        $sortOrder = $existingCount + 1

        foreach ($photo in $photoFiles) {
            $publicId = "peachoutdoor/$($folder.Name)/$($photo.BaseName)"

            # Skip if already uploaded
            if ($existingPublicIds.ContainsKey($publicId)) {
                $skippedCount++
                continue
            }

            # Build timestamp and signature
            $epoch     = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
            $timestamp = [int][Math]::Floor(([DateTime]::UtcNow - $epoch).TotalSeconds)
            $stringToSign = "public_id=$publicId&timestamp=$timestamp$CloudSecret"
            $sha1      = [System.Security.Cryptography.SHA1]::Create()
            $bytes     = [System.Text.Encoding]::UTF8.GetBytes($stringToSign)
            $signature = [System.BitConverter]::ToString($sha1.ComputeHash($bytes)).Replace("-","").ToLower()

            # Read and base64 encode file
            $fileBytes  = [System.IO.File]::ReadAllBytes($photo.FullName)
            $base64Data = [System.Convert]::ToBase64String($fileBytes)
            $mimeType   = if ($photo.Extension -eq ".png") { "image/png" } `
                          elseif ($photo.Extension -eq ".webp") { "image/webp" } `
                          else { "image/jpeg" }
            $dataUri    = "data:$mimeType;base64,$base64Data"

            $body = @{
                file      = $dataUri
                public_id = $publicId
                timestamp = $timestamp
                api_key   = $CloudApiKey
                signature = $signature
            }

            try {
                $result   = Invoke-RestMethod -Uri "https://api.cloudinary.com/v1_1/$CloudName/image/upload" -Method Post -Body $body
                $cloudUrl = $result.secure_url
                $isPrimary = if ($sortOrder -eq 1) { 1 } else { 0 }

                Invoke-SQLNonQuery -Query @"
INSERT INTO dbo.InventoryPhotos (InventoryID, PhotoURL, PublicID, SortOrder, IsPrimary, IsDefault, UploadedDate)
VALUES (@inv, @url, @pub, @sort, @primary, 0, GETDATE())
"@ -Params @{
                    "@inv"     = $inventoryId
                    "@url"     = $cloudUrl
                    "@pub"     = $publicId
                    "@sort"    = $sortOrder
                    "@primary" = $isPrimary
                } | Out-Null

                $existingPublicIds[$publicId] = $true
                Write-Log "  Uploaded: $($folder.Name)/$($photo.Name) → $cloudUrl"
                $uploadedCount++
                $sortOrder++
            }
            catch {
                Write-Log "  ERROR uploading $($photo.Name): $($_.Exception.Message)" "ERROR"
                $errorCount++
            }
        }
    }

    Write-Log "Photo upload complete. Uploaded: $uploadedCount | Skipped: $skippedCount | Errors: $errorCount"

} else {
    if (-not (Test-Path $PhotosFolder)) {
        Write-Log "Photos folder not found ($PhotosFolder) — skipping photo upload." "WARN"
    } else {
        Write-Log "Cloudinary credentials not set in script — skipping photo upload." "WARN"
    }
}

# =============================================================================
# STEP 1 - Build inventory.json
# =============================================================================
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
    ISNULL(wd.Notes, '')           AS Notes,
    ISNULL(wd.AboutThisItem, '')   AS AboutThisItem,
    ISNULL(wd.FeaturedItem, 0)     AS FeaturedItem,
    (
        SELECT TOP 1 PhotoURL
        FROM dbo.InventoryPhotos
        WHERE InventoryID = i.InventoryID
          AND IsPrimary = 1
    ) AS PrimaryPhotoURL,
    (
        -- Flag: does the primary photo come from a default scrape?
        SELECT TOP 1 CAST(IsDefault AS INT)
        FROM dbo.InventoryPhotos
        WHERE InventoryID = i.InventoryID
          AND IsPrimary = 1
    ) AS PrimaryPhotoIsDefault,
    (
        SELECT TOP 1 sm.SpecModel
        FROM dbo.ModelSpecsMap sm
        WHERE sm.MFG    = i.MFG
          AND sm.Series = i.Series
          AND (sm.ModelPattern IS NULL OR i.Model LIKE sm.ModelPattern)
        ORDER BY
            CASE WHEN sm.ModelPattern IS NOT NULL THEN 0 ELSE 1 END,
            sm.MapID
    ) AS SpecModel
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
SELECT InventoryID, PhotoURL, ISNULL(IsDefault, 0) AS IsDefault
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
# Only include real (non-default) photos in AllPhotos array for the gallery.
# The PrimaryPhotoURL (which may be a default) is tracked separately.
$photoLookup        = @{}   # all photos including defaults
$realPhotoLookup    = @{}   # real photos only

foreach ($row in $photoRows) {
    $id        = if ($row["InventoryID"] -is [DBNull]) { 0 } else { [int]$row["InventoryID"] }
    $isDefault = -not ($row["IsDefault"] -is [DBNull]) -and ([int]$row["IsDefault"] -eq 1)

    if ($id -eq 0) { continue }

    if (-not $photoLookup.ContainsKey($id)) { $photoLookup[$id] = @() }
    $photoLookup[$id] += [string]$row["PhotoURL"]

    if (-not $isDefault) {
        if (-not $realPhotoLookup.ContainsKey($id)) { $realPhotoLookup[$id] = @() }
        $realPhotoLookup[$id] += [string]$row["PhotoURL"]
    }
}

# Build inventory list
$inventoryList = @()
foreach ($row in $inventoryRows) {
    $id             = [int]$row.InventoryID
    $primaryIsDefault = -not ($row.PrimaryPhotoIsDefault -is [DBNull]) -and ([int]$row.PrimaryPhotoIsDefault -eq 1)

    $inventoryList += [PSCustomObject]@{
        InventoryID           = $id
        Manufacturer          = [string]$row.Manufacturer
        Department            = [string]$row.Department
        Series                = [string]$row.Series
        Model                 = [string]$row.Model
        Description           = [string]$row.Description
        SerialNumber          = [string]$row.SerialNumber
        Location              = [string]$row.Location
        MSRP                  = if ($row.MSRP      -is [DBNull]) { $null } else { [double]$row.MSRP }
        Web_Price             = if ($row.Web_Price -is [DBNull]) { $null } else { [double]$row.Web_Price }
        Used                  = ([int]$row.Used -eq 1)
        FeaturedItem          = ([int]$row.FeaturedItem -eq 1)
        Notes                 = [string]$row.Notes
        AboutThisItem         = [string]$row.AboutThisItem
        PrimaryPhotoURL       = if ($row.PrimaryPhotoURL -is [DBNull]) { $null } else { [string]$row.PrimaryPhotoURL }
        PrimaryPhotoIsDefault = $primaryIsDefault
        SpecModel             = if ($row.SpecModel -is [DBNull]) { $null } else { [string]$row.SpecModel }
        AllPhotos             = if ($realPhotoLookup.ContainsKey($id)) { $realPhotoLookup[$id] } else { @() }
    }
}

$inventoryJson = $inventoryList | ConvertTo-Json -Depth 5
Write-Log "Inventory built: $($inventoryList.Count) items."

# =============================================================================
# STEP 2 - Build specs.json
# =============================================================================
Write-Log "Querying model specs..."

$specsSQL = @"
SELECT
    ms.Manufacture,
    ms.Series,
    ms.Model,
    ms.SpecGroup    AS Category,
    ms.SpecLabel,
    ms.SpecValue,
    ms.SortOrder,
    1               AS SpecPriority
FROM dbo.ModelSpecs ms
ORDER BY ms.Manufacture, ms.Series, ms.Model, ms.SpecGroup, ms.SortOrder, ms.SpecLabel
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
Write-Log "Specs built: $($specsList.Count) model spec sets."

if ($specsList.Count -gt 0) {
    $specsJson = $specsList | ConvertTo-Json -Depth 6
} else {
    Write-Log "No spec rows returned — specs.json will not be updated this run." "WARN"
    $specsJson = $null
}

# =============================================================================
# STEP 3 - Push files to GitHub
# =============================================================================
$commitMsg = "Auto-sync inventory + specs $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

try {
    $filesToPush = @{ "inventory.json" = $inventoryJson }
    if ($specsJson) { $filesToPush["specs.json"] = $specsJson }

    Push-GitHubFiles -Files $filesToPush -CommitMsg $commitMsg
    Write-Log "Netlify will deploy automatically."
} catch {
    Write-Log "ERROR pushing to GitHub: $($_.Exception.Message)" "ERROR"
    exit 1
}

Write-Log "===== Sync-Inventory completed successfully ====="
