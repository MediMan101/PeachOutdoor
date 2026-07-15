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
#
#   $GitHubToken        = "your-github-token"
#   $BunnyStorageApiKey = "your-bunny-storage-api-key"
#   $BunnyStorageZone   = "peachoutdoor"
#   $BunnyStorageHost   = "ny.storage.bunnycdn.com"

$ConfigFile = Join-Path $PSScriptRoot "sync-config.ps1"
if (-not (Test-Path $ConfigFile)) {
    Write-Host "[ERROR] Config file not found: $ConfigFile" -ForegroundColor Red
    Write-Host "Create that file with the following content:" -ForegroundColor Yellow
    Write-Host '  $GitHubToken        = "your-github-token"' -ForegroundColor Yellow
    Write-Host '  $BunnyStorageApiKey = "your-bunny-storage-api-key"' -ForegroundColor Yellow
    Write-Host '  $BunnyStorageZone   = "peachoutdoor"' -ForegroundColor Yellow
    Write-Host '  $BunnyStorageHost   = "ny.storage.bunnycdn.com"' -ForegroundColor Yellow
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

$PhotosFolder = "C:\inetpub\wwwroot\inventoryapp\photos"

# Bunny CDN delivery base URL — photos are served from here
$BunnyCDNBase = "https://peachoutdoor.b-cdn.net"

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

# -- HELPER: Build a Bunny CDN delivery URL from a storage path ---------------

function Get-BunnyUrl {
    param([string]$StoragePath)
    return "$BunnyCDNBase/$StoragePath"
}

# -- HELPER: Upload a file to Bunny Storage via HTTP PUT ----------------------

function Send-BunnyFile {
    param(
        [string]$StoragePath,
        [byte[]]$FileBytes
    )
    $uploadUrl = "https://$BunnyStorageHost/$BunnyStorageZone/$StoragePath"
    $headers   = @{ "AccessKey" = $BunnyStorageApiKey }
    Invoke-RestMethod -Uri $uploadUrl -Method Put -Headers $headers -Body $FileBytes -ContentType "image/jpeg" | Out-Null
}

# -- HELPER: Delete a file from Bunny Storage via HTTP DELETE -----------------

function Remove-BunnyFile {
    param([string]$StoragePath)
    $deleteUrl = "https://$BunnyStorageHost/$BunnyStorageZone/$StoragePath"
    $headers   = @{ "AccessKey" = $BunnyStorageApiKey }
    try {
        Invoke-RestMethod -Uri $deleteUrl -Method Delete -Headers $headers | Out-Null
        return $true
    } catch {
        if ($_.Exception.Response.StatusCode -eq 404) { return $true }
        throw
    }
}

# -- HELPER: Push multiple files in one commit via Git Tree API ---------------
# One commit = one Netlify build trigger

function Push-GitHubFiles {
    param(
        [hashtable]$Files,
        [string]$CommitMsg
    )

    $headers = @{
        "Authorization"        = "Bearer $GitHubToken"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }
    $baseUrl = "https://api.github.com/repos/$GitHubOwner/$GitHubRepo"

    $branchData = Invoke-RestMethod -Uri "$baseUrl/git/ref/heads/$GitHubBranch" -Headers $headers
    $latestSha  = $branchData.object.sha

    $commitData = Invoke-RestMethod -Uri "$baseUrl/git/commits/$latestSha" -Headers $headers
    $treeSha    = $commitData.tree.sha

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

    $newTreeBody = @{ base_tree = $treeSha; tree = $treeItems } | ConvertTo-Json -Depth 5
    $newTree = Invoke-RestMethod -Uri "$baseUrl/git/trees" -Headers $headers `
                    -Method Post -Body $newTreeBody -ContentType "application/json"

    $newCommitBody = @{
        message = $CommitMsg
        tree    = $newTree.sha
        parents = @($latestSha)
    } | ConvertTo-Json
    $newCommit = Invoke-RestMethod -Uri "$baseUrl/git/commits" -Headers $headers `
                    -Method Post -Body $newCommitBody -ContentType "application/json"

    $updateRefBody = @{ sha = $newCommit.sha; force = $false } | ConvertTo-Json
    Invoke-RestMethod -Uri "$baseUrl/git/refs/heads/$GitHubBranch" -Headers $headers `
        -Method Patch -Body $updateRefBody -ContentType "application/json" | Out-Null

    Write-Log "Pushed $($Files.Count) files in single commit. One Netlify build triggered."
}

# =============================================================================
# STEP 0 - Remove default photos for items that now have real photos.
#          Runs after each sync so defaults are cleaned up automatically
#          the moment a real photo is uploaded via SalesMan.
#          Only removes defaults for items that have at least one real photo.
#          Never removes defaults from items that have only defaults.
# =============================================================================
Write-Log "===== Sync-Inventory started ====="
Write-Log "Checking for default photos on items that now have real photos..."

$defaultsToRemoveSQL = @"
SELECT ip.PhotoID, ip.PublicID, ip.InventoryID
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
        Write-Log "Found $($defaultsToRemove.Rows.Count) default photo(s) to remove (item now has real photos)."
        foreach ($row in $defaultsToRemove) {
            $photoId     = [int]$row["PhotoID"]
            $inventoryId = [int]$row["InventoryID"]
            $publicId    = [string]$row["PublicID"]
            try {
                Invoke-SQLNonQuery -Query "DELETE FROM dbo.InventoryPhotos WHERE PhotoID = @pid" `
                    -Params @{ "@pid" = $photoId } | Out-Null
                Write-Log "  Removed default PhotoID=$photoId InventoryID=$inventoryId"
            } catch {
                Write-Log "  WARN: Could not remove default PhotoID=${photoId}: $($_.Exception.Message)" "WARN"
            }
        }
    } else {
        Write-Log "No defaults to remove."
    }
} catch {
    Write-Log "WARN: Could not check for defaults to remove: $($_.Exception.Message)" "WARN"
}


# =============================================================================
# STEP 0.6 - Remove Bunny photos for sold/inactive inventory items.
#            An item is considered inactive if any of the following are true:
#              - (Quantity - QuantitySold) < 1  (sold out)
#              - Deleted          = 1
#              - Attachment       = 1
#              - NonInventoryItem = 1
#              - IsLinkedItem     = 1
#            For each photo belonging to an inactive item:
#              1. Always delete the DB row for the inactive item
#              2. Only delete the Bunny asset if NO other active item shares
#                 the same PublicID — prevents wiping shared default photos
#                 when only one of many items using that default is sold
# =============================================================================
Write-Log "Checking for photos belonging to sold/inactive items..."

$inactivePhotosSQL = @"
SELECT ip.PhotoID, ip.PublicID, ip.InventoryID,
    -- Count how many OTHER active items share this same PublicID
    (
        SELECT COUNT(*)
        FROM dbo.InventoryPhotos ip2
        INNER JOIN dbo.Inventory i2 ON i2.InventoryID = ip2.InventoryID
        WHERE ip2.PublicID = ip.PublicID
          AND ip2.PhotoID  <> ip.PhotoID
          AND (i2.Quantity - ISNULL(i2.QuantitySold, 0)) > 0
          AND ISNULL(i2.Deleted,          0) = 0
          AND ISNULL(i2.Attachment,       0) = 0
          AND ISNULL(i2.NonInventoryItem, 0) = 0
          AND ISNULL(i2.IsLinkedItem,     0) = 0
    ) AS ActiveShareCount
FROM dbo.InventoryPhotos ip
INNER JOIN dbo.Inventory i ON i.InventoryID = ip.InventoryID
WHERE (i.Quantity - ISNULL(i.QuantitySold, 0)) < 1
   OR ISNULL(i.Deleted,          0) = 1
   OR ISNULL(i.Attachment,       0) = 1
   OR ISNULL(i.NonInventoryItem, 0) = 1
   OR ISNULL(i.IsLinkedItem,     0) = 1
"@

try {
    $inactivePhotos = Invoke-SQL -Query $inactivePhotosSQL

    if ($inactivePhotos.Rows.Count -gt 0) {
        Write-Log "Found $($inactivePhotos.Rows.Count) photo(s) for sold/inactive items — removing..."

        $bunnyDeletedCount  = 0
        $bunnySkippedCount  = 0
        $dbDeletedCount     = 0
        $bunnyErrorCount    = 0

        foreach ($row in $inactivePhotos) {
            $photoId         = [int]$row["PhotoID"]
            $publicId        = [string]$row["PublicID"]
            $inventoryId     = [int]$row["InventoryID"]
            $activeShareCount = [int]$row["ActiveShareCount"]

            # -- Delete from Bunny Storage only if no active items share this PublicID
            if ($publicId -and $BunnyStorageApiKey) {
                if ($activeShareCount -eq 0) {
                    try {
                        $storagePath = "$publicId.jpg"
                        $deleted = Remove-BunnyFile -StoragePath $storagePath
                        if ($deleted) {
                            $bunnyDeletedCount++
                            Write-Log "  Bunny deleted: $publicId (InventoryID: $inventoryId)"
                        }
                    } catch {
                        Write-Log "  WARN: Bunny delete failed for $publicId`: $($_.Exception.Message)" "WARN"
                        $bunnyErrorCount++
                    }
                } else {
                    # Other active items still use this photo — keep the Bunny asset
                    $bunnySkippedCount++
                    Write-Log "  Bunny kept (shared by $activeShareCount active item(s)): $publicId"
                }
            }

            # -- Always delete the DB record for the inactive item -------------
            try {
                Invoke-SQLNonQuery -Query "DELETE FROM dbo.InventoryPhotos WHERE PhotoID = @pid" `
                    -Params @{ "@pid" = $photoId } | Out-Null
                $dbDeletedCount++
            } catch {
                Write-Log "  ERROR: Could not delete DB record PhotoID ${photoId}: $($_.Exception.Message)" "ERROR"
            }
        }

        Write-Log "Inactive photo cleanup complete. Bunny: $bunnyDeletedCount deleted, $bunnySkippedCount shared/kept, $bunnyErrorCount errors | DB rows removed: $dbDeletedCount"
    } else {
        Write-Log "No photos found for sold/inactive items."
    }
} catch {
    Write-Log "WARN: Could not check for inactive item photos: $($_.Exception.Message)" "WARN"
}


# =============================================================================
# STEP 0.5 - Scan IIS photos folder and upload new photos to Bunny Storage.
#            Skips any photo already recorded in InventoryPhotos.
#            Moves inactive item folders to _Removed to prevent re-uploading.
#            Resizes photos to 2000px wide at quality 85 before uploading.
# =============================================================================

if ($BunnyStorageApiKey -and (Test-Path $PhotosFolder)) {

    Write-Log "Scanning IIS photos folder for new photos..."

    # _Removed folder — inactive item folders are moved here instead of deleted.
    # Folders starting with _ are skipped by the upload loop automatically.
    $RemovedFolder = Join-Path $PhotosFolder "_Removed"
    if (-not (Test-Path $RemovedFolder)) {
        New-Item -ItemType Directory -Path $RemovedFolder -Force | Out-Null
        Write-Log "Created _Removed folder: $RemovedFolder"
    }

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

    # Build a set of active InventoryIDs so inactive folders can be moved
    # to _Removed without touching Bunny (Step 0.6 already handled that).
    $activeInventoryIds = @{}
    try {
        $activeRows = Invoke-SQL -Query @"
SELECT i.InventoryID
FROM dbo.Inventory i
WHERE (i.Quantity - ISNULL(i.QuantitySold, 0)) > 0
  AND ISNULL(i.Deleted,          0) = 0
  AND ISNULL(i.Attachment,       0) = 0
  AND ISNULL(i.NonInventoryItem, 0) = 0
  AND ISNULL(i.IsLinkedItem,     0) = 0
"@
        foreach ($r in $activeRows) {
            $activeInventoryIds[[int]$r["InventoryID"]] = $true
        }
        Write-Log "Active inventory: $($activeInventoryIds.Count) items."
    } catch {
        Write-Log "WARN: Could not load active inventory IDs: $($_.Exception.Message)" "WARN"
    }

    # Walk each InventoryID_Serial folder — skip any starting with _
    $itemFolders   = Get-ChildItem -Path $PhotosFolder -Directory |
                         Where-Object { $_.Name -notlike '_*' }
    $uploadedCount = 0
    $skippedCount  = 0
    $errorCount    = 0
    $movedCount    = 0

    foreach ($folder in $itemFolders) {
        # Parse InventoryID from folder name (format: InventoryID_SerialNumber)
        $parts = $folder.Name -split '_', 2
        if ($parts.Count -lt 1 -or -not ($parts[0] -match '^\d+$')) {
            Write-Log "  Skipping unrecognised folder: $($folder.Name)" "WARN"
            continue
        }
        $inventoryId = [int]$parts[0]

        # If the item is inactive, move the folder to _Removed and skip upload.
        # Step 0.6 has already removed the Bunny assets and DB records.
        if ($activeInventoryIds.Count -gt 0 -and -not $activeInventoryIds.ContainsKey($inventoryId)) {
            $destPath = Join-Path $RemovedFolder $folder.Name
            try {
                Move-Item -Path $folder.FullName -Destination $destPath -Force
                Write-Log "  Moved inactive folder to _Removed: $($folder.Name)"
                $movedCount++
            } catch {
                Write-Log "  WARN: Could not move folder $($folder.Name): $($_.Exception.Message)" "WARN"
            }
            continue
        }

        # Get existing photos for this inventory item to determine sort order
        $existingCountRows = Invoke-SQL -Query "SELECT COUNT(*) AS C FROM dbo.InventoryPhotos WHERE InventoryID = $inventoryId AND IsDefault = 0"
        $existingCount = [int]$existingCountRows[0]["C"]

        # Get all image files in this folder
        $photoFiles = Get-ChildItem -Path $folder.FullName -File |
            Where-Object { $_.Extension -match '\.(jpg|jpeg|png|webp|gif)$' } |
            Sort-Object Name

        $sortOrder = $existingCount + 1

        foreach ($photo in $photoFiles) {
            $publicId    = "peachoutdoor/$($folder.Name)/$($photo.BaseName)"
            $storagePath = "$publicId.jpg"

            # Skip if already uploaded
            if ($existingPublicIds.ContainsKey($publicId)) {
                $skippedCount++
                continue
            }

            # Resize to 2000px wide at quality 85 before uploading.
            # Reduces storage and upload transfer time significantly.
            # System.Drawing is built into Windows — no extra installs needed.
            $tempPath  = $null
            $fileBytes = $null
            try {
                Add-Type -AssemblyName System.Drawing

                $maxUploadWidth = 2000
                $origImage      = [System.Drawing.Image]::FromFile($photo.FullName)

                if ($origImage.Width -gt $maxUploadWidth) {
                    $ratio     = $maxUploadWidth / $origImage.Width
                    $newWidth  = $maxUploadWidth
                    $newHeight = [int]($origImage.Height * $ratio)

                    $resized = New-Object System.Drawing.Bitmap($newWidth, $newHeight)
                    $graphic = [System.Drawing.Graphics]::FromImage($resized)
                    $graphic.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
                    $graphic.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
                    $graphic.PixelOffsetMode   = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
                    $graphic.DrawImage($origImage, 0, 0, $newWidth, $newHeight)

                    $jpegEncoder = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                                       Where-Object { $_.MimeType -eq 'image/jpeg' }
                    $encParams   = New-Object System.Drawing.Imaging.EncoderParameters(1)
                    $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                                             [System.Drawing.Imaging.Encoder]::Quality, 85L)

                    $tempPath = [System.IO.Path]::GetTempFileName() + ".jpg"
                    $resized.Save($tempPath, $jpegEncoder, $encParams)

                    $graphic.Dispose()
                    $resized.Dispose()
                    $origImage.Dispose()

                    $fileBytes = [System.IO.File]::ReadAllBytes($tempPath)
                    Write-Log "  Resized $($photo.Name): ${newWidth}px wide, quality 85"
                } else {
                    $origImage.Dispose()
                    $fileBytes = [System.IO.File]::ReadAllBytes($photo.FullName)
                }
            } catch {
                Write-Log "  WARN: Resize failed for $($photo.Name), uploading original: $($_.Exception.Message)" "WARN"
                $fileBytes = [System.IO.File]::ReadAllBytes($photo.FullName)
            }

            try {
                # Upload to Bunny Storage via HTTP PUT
                Send-BunnyFile -StoragePath $storagePath -FileBytes $fileBytes

                # Build the CDN delivery URL and store in DB
                $bunnyUrl  = Get-BunnyUrl -StoragePath $storagePath
                $isPrimary = if ($sortOrder -eq 1) { 1 } else { 0 }

                Invoke-SQLNonQuery -Query @"
INSERT INTO dbo.InventoryPhotos (InventoryID, PhotoURL, PublicID, SortOrder, IsPrimary, IsDefault, UploadedDate)
VALUES (@inv, @url, @pub, @sort, @primary, 0, GETDATE())
"@ -Params @{
                    "@inv"     = $inventoryId
                    "@url"     = $bunnyUrl
                    "@pub"     = $publicId
                    "@sort"    = $sortOrder
                    "@primary" = $isPrimary
                } | Out-Null

                $existingPublicIds[$publicId] = $true
                Write-Log "  Uploaded: $($folder.Name)/$($photo.Name) → $bunnyUrl"
                $uploadedCount++
                $sortOrder++
            }
            catch {
                Write-Log "  ERROR uploading $($photo.Name): $($_.Exception.Message)" "ERROR"
                $errorCount++
            }
            finally {
                # Clean up temp resized file if one was created
                if ($tempPath -and (Test-Path $tempPath)) {
                    Remove-Item $tempPath -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }

    Write-Log "Photo upload complete. Uploaded: $uploadedCount | Skipped: $skippedCount | Moved to _Removed: $movedCount | Errors: $errorCount"

} else {
    if (-not (Test-Path $PhotosFolder)) {
        Write-Log "Photos folder not found ($PhotosFolder) — skipping photo upload." "WARN"
    } else {
        Write-Log "Bunny credentials not set in config — skipping photo upload." "WARN"
    }
}

# =============================================================================
# STEP 1 - Build inventory.json
# =============================================================================
Write-Log "Querying inventory..."

# -- Pricing source ------------------------------------------------------------
# SalesMan DB migration 007 adds WebPricing.Monthly_Payment and the
# dbo.vw_InventoryWebPricing view (latest active pricing row per item with the
# display decision pre-computed):
#   PriceDisplayMode    : 'MonthlyPayment' | 'Price' | 'CallForPrice'
#   PriceDisplayText    : '$249 per month (WAC)' / '$18,999.00' / 'Call for Price'
#   PriceDisplaySubText : 'See dealer for details' (MonthlyPayment mode only)
# If the view is not there yet (SalesMan hasn't run since the update), fall
# back to the legacy WebPricing join so the sync keeps working; items then
# export with Price / Call-for-Price display only.
$hasPricingView = $false
try {
    $viewCheckRows  = Invoke-SQL -Query "SELECT OBJECT_ID('dbo.vw_InventoryWebPricing', 'V') AS ViewID"
    $hasPricingView = -not ($viewCheckRows[0]["ViewID"] -is [DBNull])
} catch {
    Write-Log "WARN: Could not check for vw_InventoryWebPricing: $($_.Exception.Message)" "WARN"
}

if ($hasPricingView) {
    $pricingSelect = @'
    wp.Web_Price,
    wp.Monthly_Payment,
    wp.PriceDisplayMode,
    wp.PriceDisplayText,
    wp.PriceDisplaySubText,
'@
    $pricingJoin = @'
LEFT JOIN dbo.vw_InventoryWebPricing wp
    ON wp.InventoryID = i.InventoryID
'@
} else {
    Write-Log "vw_InventoryWebPricing not found - run SalesMan once to apply DB migration 007. Exporting without Payment-per-Month fields." "WARN"
    $pricingSelect = @'
    wp.Web_Price,
    CAST(NULL AS DECIMAL(19,4)) AS Monthly_Payment,
    CASE WHEN wp.Web_Price IS NOT NULL THEN 'Price' ELSE 'CallForPrice' END AS PriceDisplayMode,
    CASE WHEN wp.Web_Price IS NOT NULL THEN FORMAT(wp.Web_Price, 'C2', 'en-US') ELSE 'Call for Price' END AS PriceDisplayText,
    CAST(NULL AS VARCHAR(30)) AS PriceDisplaySubText,
'@
    $pricingJoin = @'
LEFT JOIN dbo.WebPricing wp
    ON wp.InventoryID = i.InventoryID
   AND wp.IsActive = 1
   AND wp.EffectiveDate = (
       SELECT MAX(EffectiveDate) FROM dbo.WebPricing
       WHERE InventoryID = i.InventoryID AND IsActive = 1
   )
'@
}

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
$pricingSelect
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
$pricingJoin
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
# AllPhotos includes ALL photos — real and default — so the gallery on
# item-details.html shows every available photo for the item.
# The PrimaryPhotoURL (IsPrimary = 1) is tracked separately for the card view.
$photoLookup = @{}

foreach ($row in $photoRows) {
    $id = if ($row["InventoryID"] -is [DBNull]) { 0 } else { [int]$row["InventoryID"] }
    if ($id -eq 0) { continue }
    if (-not $photoLookup.ContainsKey($id)) { $photoLookup[$id] = @() }
    $photoLookup[$id] += [string]$row["PhotoURL"]
}

# Build inventory list
$inventoryList = @()
foreach ($row in $inventoryRows) {
    $id               = [int]$row.InventoryID
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
        Monthly_Payment       = if ($row.Monthly_Payment -is [DBNull]) { $null } else { [double]$row.Monthly_Payment }
        PriceDisplayMode      = if ($row.PriceDisplayMode -is [DBNull]) { "CallForPrice" } else { [string]$row.PriceDisplayMode }
        PriceDisplayText      = if ($row.PriceDisplayText -is [DBNull]) { "Call for Price" } else { [string]$row.PriceDisplayText }
        PriceDisplaySubText   = if ($row.PriceDisplaySubText -is [DBNull]) { $null } else { [string]$row.PriceDisplaySubText }
        Used                  = ([int]$row.Used -eq 1)
        FeaturedItem          = ([int]$row.FeaturedItem -eq 1)
        Notes                 = [string]$row.Notes
        AboutThisItem         = [string]$row.AboutThisItem
        PrimaryPhotoURL       = if ($row.PrimaryPhotoURL -is [DBNull]) { $null } else { [string]$row.PrimaryPhotoURL }
        PrimaryPhotoIsDefault = $primaryIsDefault
        SpecModel             = if ($row.SpecModel -is [DBNull]) { $null } else { [string]$row.SpecModel }
        AllPhotos             = if ($photoLookup.ContainsKey($id)) { $photoLookup[$id] } else { @() }
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