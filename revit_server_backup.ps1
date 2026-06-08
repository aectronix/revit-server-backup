# =============================================================================
# CONFIGURATION                                                               #
# =============================================================================

# get sensitive vars from env
$envPath = Join-Path -Path $PSScriptRoot -ChildPath ".env"
if (-not (Test-Path -Path $envPath)) {
	Write-Host "CRITICAL: .env file not found at $envPath. Exiting." -ForegroundColor Red
	exit
}
foreach ($line in Get-Content -Path $envPath) {
	if (-not [string]::IsNullOrWhiteSpace($line) -and -not $line.StartsWith("#")) {
		$key, $value = $line.Split('=', 2)
		$key = $key.Trim()
		$value = $value.Trim()
		switch ($key) {
			"SERVER_IP"			{ $cfg_rsn_name = $value }
			"SERVER_VERSION"	{ $cfg_rsn_version = $value }
			"APS_CLIENT_ID"		{ $cfg_aps_client_id = $value }
			"APS_CLIENT_SECRET"	{ $cfg_aps_client_secret = $value }
			"ACCOUNT_ID" 		{ $cfg_acc_account_id = $value }
			"FILTER_DIRS"		{ $cfg_filter_dir = @($value -split ',' | ForEach-Object { $_.Trim() }) }
		}
	}
}

$cfg_rsn_path = "C:\ProgramData\Autodesk\Revit Server $cfg_rsn_version"
$cfg_rsn_tool = "C:\Program Files\Autodesk\Revit Server $cfg_rsn_version\Tools\RevitServerToolCommand\RevitServerTool.exe"
$cfg_aps_scopes = "data:read data:write data:create account:read"

$cfg_max_dir_depth = 7
$cfg_acc_base_folder = "00_WIP"

# logging
$cfg_rsn_logs = "$cfg_rsn_path\Logs\AutoBackup.log"
$cfg_max_log_size_mb = 64

$pathLogs = Split-Path -Path $cfg_rsn_logs
if (-not (Test-Path -Path $pathLogs)) { New-Item -ItemType Directory -Path $pathLogs -Force | Out-Null }


# =============================================================================
# FUNCTIONS & METHODS                                                         #
# =============================================================================

# Basic logging
function Write-Log {
	<#
	.SYNOPSIS
		Writes customized logs to the separate file.
	#>
	param([string]$Message)

	# check logfile size
	if (Test-Path -Path $cfg_rsn_logs) {
		$logFile = Get-Item -Path $cfg_rsn_logs
		if (($logFile.Length / 1MB) -ge $cfg_max_log_size_mb) {
			Clear-Content -Path $cfg_rsn_logs -Force
			$resetTimestamp = Get-Date -Format "dd-MM-yy HH:mm:ss"
			Add-Content -Path $cfg_rsn_logs -Value "$resetTimestamp [Log reset because it exceeded $cfg_max_log_size_mb MB]"
		}
	}
	# prepare log message
	$timestamp = Get-Date -Format "dd-MM-yy HH:mm:ss"
	$logLine = "$timestamp $Message"
	Add-Content -Path $cfg_rsn_logs -Value $logLine    
	Write-Host "$timestamp " -ForegroundColor Cyan -NoNewline
	if ($Message -match "^(DONE:|INFO:|WARNING:|ERROR:)\s*(.*)$") {
		# $matches[1] is the tag itself, $matches[2] is the rest of the text
		$prefix = $matches[1]
		$restOfText = $matches[2]
		$prefixColor = switch ($prefix) {
			"DONE:"    { "Green" }
			"INFO:"    { "Blue" } 
			"WARNING:" { "Yellow" }
			"ERROR:"   { "Red" }
		}
		Write-Host "$prefix " -ForegroundColor $prefixColor -NoNewline
		Write-Host $restOfText -ForegroundColor White
	} else {
		# If no matching prefix is found, just print the whole message in White
		Write-Host $Message -ForegroundColor White
	}
}

# APS/Forma Token Retrieval
function Get-APSToken {
    <#
    .SYNOPSIS
        Retrieves token from APS auth endpoint
    .DESCRIPTION
        The APS v2 API requires the Client ID and Secret to be Base64 encoded in the header
    #>
	$authUrl = "https://developer.api.autodesk.com/authentication/v2/token"
	$plainTextCreds = "${cfg_aps_client_id}:${cfg_aps_client_secret}"
	$base64Creds    = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($plainTextCreds))
    
	$headers = @{
		"Authorization" = "Basic $base64Creds"
		"Content-Type"  = "application/x-www-form-urlencoded"
	}
    
	$body = "grant_type=client_credentials&scope=$cfg_aps_scopes"

	try {
		$response = Invoke-RestMethod -Uri $authUrl -Method Post -Headers $headers -Body $body -ErrorAction Stop
		Write-Log "DONE: APS Token successfully acquired. Expires in $($response.expires_in) seconds."
		return $response.access_token
	}
	catch {
		Write-Log "ERROR: Failed to authenticate with APS. Details: $($_.Exception.Message)"
		if ($_.ErrorDetails) {
			Write-Log "APS API Response: $($_.ErrorDetails.Message)"
		}
		exit
	}
}

# APS/Forma Project Retrieval
function Get-APSProject {
	<#
	.SYNOPSIS
		Retrieves project instance by searching for a partial name via ACC Hub Admin API.
	.DESCRIPTION
		Uses the Hub Admin API to query projects server-side using the filter[name].
	#>
	param(
		[Parameter(Mandatory=$true)]
		[string]$AccountId,
		
		[Parameter(Mandatory=$true)]
		[string]$ProjectSearchString,
		
		[Parameter(Mandatory=$true)]
		[string]$AccessToken
	)

	# filter[name]
	$url = "https://developer.api.autodesk.com/construction/admin/v1/accounts/$AccountId/projects?filter[name]=$ProjectSearchString"
	
	$headers = @{
		"Authorization" = "Bearer $AccessToken"
	}

	try {
		#Write-Log "INFO: Searching for project matching '$ProjectSearchString' in Account '$AccountId'..."		
		$response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop

		if ($response.pagination.totalResults -gt 0) {
			$targetProject = $response.results[0]
			#Write-Log "DONE: Forma project '$($targetProject.name)' found."
			return $targetProject
		} else {
			Write-Log "ERROR: No project found matching '$ProjectSearchString'."
			return $null
		}
	}
	catch {
		Write-Log "ERROR: Failed to search for project. Details: $($_.Exception.Message)"
		if ($_.ErrorDetails) {
			Write-Log "ERROR: API Response: $($_.ErrorDetails.Message)"
		}
		return $null
	}
}

# APS/Forma Project Top Folder
function Get-APSTopFolder {
	<#
	.SYNOPSIS
		Retrieves the URN of a root folder (like "Project Files") in an ACC project.
	#>
	param(
		[Parameter(Mandatory=$true)][string]$HubId,
		[Parameter(Mandatory=$true)][string]$ProjectId,
		[Parameter(Mandatory=$true)][string]$FolderName,
		[Parameter(Mandatory=$true)][string]$AccessToken
	)

	$url = "https://developer.api.autodesk.com/project/v1/hubs/$HubId/projects/$ProjectId/topFolders"
	$headers = @{ "Authorization" = "Bearer $AccessToken" }

	try {
		$response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
		$targetFolder = $response.data | Where-Object { $_.attributes.name -eq $FolderName }
		
		if ($targetFolder) {
			return $targetFolder.id
		} else {
			Write-Log "ERROR: Top folder '$FolderName' not found in project."
			return $null
		}
	}
	catch {
		Write-Log "ERROR: Failed to retrieve top folders. Details: $($_.Exception.Message)"
		return $null
	}
}

# APS/Forma Project Child Folder by Name
function Get-APSChildFolder {
	<#
	.SYNOPSIS
		Searches for a specific subfolder inside a given parent folder.
	#>
	param(
		[Parameter(Mandatory=$true)][string]$ProjectId,
		[Parameter(Mandatory=$true)][string]$ParentFolderId,
		[Parameter(Mandatory=$true)][string]$FolderName,
		[Parameter(Mandatory=$true)][string]$AccessToken
	)

	$url = "https://developer.api.autodesk.com/data/v1/projects/$ProjectId/folders/$ParentFolderId/contents?filter[type]=folders"
	$headers = @{ "Authorization" = "Bearer $AccessToken" }

	try {
		$response = Invoke-RestMethod -Uri $url -Method Get -Headers $headers -ErrorAction Stop
		$targetFolder = $response.data | Where-Object { $_.attributes.name -eq $FolderName }
		
		if ($targetFolder) {
			#Write-Log "INFO: Found folder '$FolderName' (URN: $($targetFolder.id))"
			return $targetFolder.id
		} else {
			Write-Log "WARNING: Folder '$FolderName' not found."
			return $null
		}
	}
	catch {
		Write-Log "ERROR: Failed to search inside folder '$ParentFolderId'. Details: $($_.Exception.Message)"
		return $null
	}
}

# APS/Forma Prepare Storage
function New-APSStorage {
	<#
	.SYNOPSIS
		Creates a storage container in the target ACC folder.
	#>
	param(
		[Parameter(Mandatory=$true)][string]$ProjectId,
		[Parameter(Mandatory=$true)][string]$FolderUrn,
		[Parameter(Mandatory=$true)][string]$FileName,
		[Parameter(Mandatory=$true)][string]$AccessToken
	)

	$url = "https://developer.api.autodesk.com/data/v1/projects/$ProjectId/storage"
	$headers = @{
		"Authorization" = "Bearer $AccessToken"
		"Content-Type"  = "application/vnd.api+json"
	}

	$body = @"
		{
			"jsonapi": { "version": "1.0" },
			"data": {
				"type": "objects",
				"attributes": { "name": "$FileName" },
				"relationships": {
					"target": { "data": { "type": "folders", "id": "$FolderUrn" } }
				}
			}
		}
"@

	try {
		$response = Invoke-RestMethod -Uri $url -Method Post -Headers $headers -Body $body -ErrorAction Stop
		return $response.data.id
	} catch {
		Write-Log "ERROR: Failed to create storage location for $FileName. Details: $($_.Exception.Message)"
		return $null
	}
}

# APS/Forma Prepare S3 Bucket
function Send-APSFileToS3 {
	<#
	.SYNOPSIS
		Pushes the local file bytes to the cloud using S3 Signed URL via strict .NET streams.
	#>
	param(
		[Parameter(Mandatory=$true)][string]$StorageUrn,
		[Parameter(Mandatory=$true)][string]$LocalFilePath,
		[Parameter(Mandatory=$true)][string]$AccessToken
	)

	if ($StorageUrn -match "urn:adsk.objects:os.object:(.+?)/(.+)$") {
		$bucketKey = $matches[1]
		$objectKey = $matches[2]
	} else {
		Write-Log "ERROR: Invalid Storage URN format received."
		return $false
	}

	$authHeaders = @{ "Authorization" = "Bearer $AccessToken" }

	# request Signed URL from Autodesk
	try {
		$urlGet = "https://developer.api.autodesk.com/oss/v2/buckets/$bucketKey/objects/$objectKey/signeds3upload"
		$s3Response = Invoke-RestMethod -Uri $urlGet -Method Get -Headers $authHeaders -ErrorAction Stop
		
		$signedUrl = $s3Response.urls[0]
		$uploadKey = $s3Response.uploadKey
	} catch {
		Write-Log "ERROR: [Step 1] Failed to get S3 signed URL. Details: $($_.Exception.Message)"
		return $false
	}

	# stream directly to S3
	try {
		Add-Type -AssemblyName System.Net.Http | Out-Null		
		$httpClient = [System.Net.Http.HttpClient]::new()
		$httpClient.Timeout = [System.TimeSpan]::FromHours(2) # Prevent timeouts on massive RVT models
		
		$fileStream = [System.IO.File]::OpenRead($LocalFilePath)
		$streamContent = [System.Net.Http.StreamContent]::new($fileStream)
		
		# strip the default Content-Type header to match S3 signature perfectly
		$streamContent.Headers.Remove("Content-Type")
		$response = $httpClient.PutAsync($signedUrl, $streamContent).GetAwaiter().GetResult()
		
		$fileStream.Close()
		$streamContent.Dispose()
		$httpClient.Dispose()

		if (-not $response.IsSuccessStatusCode) {
			Write-Log "ERROR: [Step 2] AWS S3 rejected upload. Status: $($response.StatusCode) - $($response.ReasonPhrase)"
			return $false
		}
	} catch {
		Write-Log "ERROR: [Step 2] Failed to stream file to S3. Details: $($_.Exception.Message)"
		if ($fileStream) { $fileStream.Close() }
		return $false
	}

	# notify acc that the upload is complete
	try {
		$urlComplete = "https://developer.api.autodesk.com/oss/v2/buckets/$bucketKey/objects/$objectKey/signeds3upload"
		$bodyComplete = @{ "uploadKey" = $uploadKey } | ConvertTo-Json
		
		$headersComplete = @{
			"Authorization" = "Bearer $AccessToken"
			"Content-Type"  = "application/json"
		}
		
		Invoke-RestMethod -Uri $urlComplete -Method Post -Headers $headersComplete -Body $bodyComplete -ErrorAction Stop | Out-Null
		return $true
	} catch {
		Write-Log "ERROR: [Step 3] Failed to complete upload with Autodesk OSS. Details: $($_.Exception.Message)"
		return $false
	}
}

# APS/Forma Verify & Publish to Target Folder
function Publish-APSDocument {
	<#
	.SYNOPSIS
		Checks if a file exists in the cloud folder, then publishes 
		either a New Item (V1) or a New Version (V2+) automatically.
	#>
	param(
		[Parameter(Mandatory=$true)][string]$ProjectId,
		[Parameter(Mandatory=$true)][string]$FolderUrn,
		[Parameter(Mandatory=$true)][string]$StorageUrn,
		[Parameter(Mandatory=$true)][string]$FileName,
		[Parameter(Mandatory=$true)][string]$AccessToken
	)

	# check for an existing file
	$urlCheck = "https://developer.api.autodesk.com/data/v1/projects/$ProjectId/folders/$FolderUrn/contents"
	$headers = @{ "Authorization" = "Bearer $AccessToken" }
	$existingItemId = $null

	try {
		$response = Invoke-RestMethod -Uri $urlCheck -Method Get -Headers $headers -ErrorAction Stop
		$existingItem = $response.data | Where-Object { $_.type -eq 'items' -and $_.attributes.displayName -eq $FileName }
		
		if ($existingItem) { 
			$existingItemId = $existingItem.id 
		}
	} catch {
		Write-Log "ERROR: Failed to check folder contents for '$FileName'. Details: $($_.Exception.Message)"
		return $null
	}

	$headersPost = @{
		"Authorization" = "Bearer $AccessToken"
		"Content-Type"  = "application/vnd.api+json"
	}

	# file already exists
	if ($existingItemId) {
		$urlVersion = "https://developer.api.autodesk.com/data/v1/projects/$ProjectId/versions"
		$bodyVersion = @"
		{
			"jsonapi": { "version": "1.0" },
			"data": {
				"type": "versions",
				"attributes": {
					"name": "$FileName",
					"extension": { "type": "versions:autodesk.bim360:File", "version": "1.0" }
				},
				"relationships": {
					"item": { "data": { "type": "items", "id": "$existingItemId" } },
					"storage": { "data": { "type": "objects", "id": "$StorageUrn" } }
				}
			}
		}
"@
		try {
			$response = Invoke-RestMethod -Uri $urlVersion -Method Post -Headers $headersPost -Body $bodyVersion -ErrorAction Stop
			Write-Log "DONE: Successfully uploaded to the cloud."
			return $response.data.id
		} catch {
			Write-Log "ERROR: Failed to upload the file. Details: $($_.Exception.Message)"
			return $null
		}
	} else {
		$urlItem = "https://developer.api.autodesk.com/data/v1/projects/$ProjectId/items"
		$bodyItem = @"
		{
			"jsonapi": { "version": "1.0" },
			"data": {
				"type": "items",
				"attributes": {
					"displayName": "$FileName",
					"extension": { "type": "items:autodesk.bim360:File", "version": "1.0" }
				},
				"relationships": {
					"tip": { "data": { "type": "versions", "id": "1" } },
					"parent": { "data": { "type": "folders", "id": "$FolderUrn" } }
				}
			},
			"included": [
				{
					"type": "versions",
					"id": "1",
					"attributes": {
						"name": "$FileName",
						"extension": { "type": "versions:autodesk.bim360:File", "version": "1.0" }
					},
					"relationships": {
						"storage": { "data": { "type": "objects", "id": "$StorageUrn" } }
					}
				}
			]
		}
"@
		try {
			$response = Invoke-RestMethod -Uri $urlItem -Method Post -Headers $headersPost -Body $bodyItem -ErrorAction Stop
			Write-Log "DONE: Successfully uploaded to the cloud."
			return $response.data.id
		} catch {
			Write-Log "ERROR: Failed to upload the file. Details: $($_.Exception.Message)"
			return $null
		}
	}
}


# =============================================================================
# BACKUP PROCEDURE                                                            #
# =============================================================================

Write-Log "INFO: Backup script started."

# get main paths
# get project top folders, apply filters
$pathProjects = Join-Path -Path $cfg_rsn_path -ChildPath "Projects"
$pathBackup = Join-Path -Path $cfg_rsn_path -ChildPath "Backup"

try {
	$projectFolders = Get-ChildItem -Path $pathProjects -Directory -ErrorAction Stop | Where-Object { $_.Name -notin $cfg_filter_dir }
	$countProjects = $projectFolders.Count
} catch {
	Write-Log "ERROR: Failed to retrieve project folders. Details: $($_.Exception.Message)"
	exit
}

$numRvtFound = 0
$numRvtBackedUp = 0
$numRvtUploaded = 0
foreach ($projectFolder in $projectFolders) {

	# get token & search for project
	$globalToken = Get-APStoken
	$projectKey = ($projectFolder.Name -split '[-_]')[0]
	$accProject = Get-APSProject -AccountId $cfg_acc_account_id -ProjectSearchString $projectKey -AccessToken $globalToken

	# create/verify project backup folder
	$pathBackupProject = Join-Path -Path $pathBackup -ChildPath $projectFolder.Name
	try {
		New-Item -ItemType Directory -Path $pathBackupProject -Force -ErrorAction Stop | Out-Null
	} catch {
		Write-Log "ERROR: Failed to create backup folder for $($projectFolder.Name). Details: $($_.Exception.Message)"
		continue # Skip to the next project
	}

	# dynamically search for any ".RVT" folders up to the max depth limit
	try {
		$rvtDirs = Get-ChildItem -Path $projectFolder.FullName -Filter "RVT" -Directory -Recurse -Depth $cfg_max_dir_depth -ErrorAction Stop
	} catch {
		Write-Log "ERROR: Failed to scan directory tree for $($projectFolder.Name). Details: $($_.Exception.Message)"
		continue
	}

	if ($rvtDirs.Count -eq 0) {
		Write-Log "WARNING: No RVT folders found in $($projectFolder.Name) up to depth $cfg_max_dir_depth. Skipping."
		continue
	}

	# process found folders
	foreach ($rvtDir in $rvtDirs) {
		$relativePath = $rvtDir.FullName.Substring($projectFolder.FullName.Length).Trim('\')
		$pathNodes = $relativePath -split '\\'

		# retrieve Revit models inside this specific RVT folder
		try {
			$rvtFolders = @(Get-ChildItem -Path $rvtDir.FullName -Filter "*.rvt" -Directory -ErrorAction Stop)
			$numRvtFound += $rvtFolders.Count
		} catch {
			Write-Log "ERROR: Failed to retrieve revit models in $relativePath. Details: $($_.Exception.Message)"
			continue
		}

		$accChecked = $false
		$targetFolderUrn = $null

		# process revit model folders
		foreach ($rvt in $rvtFolders) {			
			$pathModel = $rvt.FullName.Substring($pathProjects.Length).Trim('\')			
			$destModelFile = Join-Path -Path $pathBackupProject -ChildPath $rvt.Name
			
			Write-Log "INFO: Backup started for '$pathModel'..."

			$toolOutput = & $cfg_rsn_tool createLocalRvt $pathModel -s $cfg_rsn_name -d $destModelFile -o 2>&1
			$isSuccess = $toolOutput | Select-String -Pattern "successfully created" -Quiet -CaseSensitive:$false

			if ($isSuccess) {
				$numRvtBackedUp++
				Write-Log "DONE: Backup successfully created locally. Preparing to upload..."

				if (-not $accChecked) {
					$accChecked = $true
					if ($accProject) {
						#Write-Log "INFO: Checking ACC folder correspondence for '$relativePath'..."
						$dmHubId = "b.$cfg_acc_account_id"
						$dmProjectId = "b.$($accProject.id)"
						
						$targetFolderUrn = Get-APSTopFolder -HubId $dmHubId -ProjectId $dmProjectId -FolderName "Project Files" -AccessToken $globalToken
						if ($targetFolderUrn -and $cfg_acc_base_folder) { 
							$targetFolderUrn = Get-APSChildFolder -ProjectId $dmProjectId -ParentFolderId $targetFolderUrn -FolderName $cfg_acc_base_folder -AccessToken $globalToken 
						}
						
						# drill down matching the local relative path
						foreach ($node in $pathNodes) {
							if ($targetFolderUrn) {
								$targetFolderUrn = Get-APSChildFolder -ProjectId $dmProjectId -ParentFolderId $targetFolderUrn -FolderName $node -AccessToken $globalToken
							} else {
								break # missing / not matching
							}
						}
					}
				}

				# upload if the acc cloud path is valid
				if ($targetFolderUrn) {
					$storageUrn = New-APSStorage -ProjectId $dmProjectId -FolderUrn $targetFolderUrn -FileName $rvt.Name -AccessToken $globalToken
					if ($storageUrn) {
						$isUploaded = Send-APSFileToS3 -StorageUrn $storageUrn -LocalFilePath $destModelFile -AccessToken $globalToken
						if ($isUploaded) {
							$publishedId = Publish-APSDocument -ProjectId $dmProjectId -FolderUrn $targetFolderUrn -StorageUrn $storageUrn -FileName $rvt.Name -AccessToken $globalToken
							if ($publishedId) {
								$numRvtUploaded++
							}
						} else {
							Write-Log "ERROR: Something went wrong while uploading to the cloud"
						}
					}
				} else {
					Write-Log "WARNING: The path '$relativePath' is not found in the cloud. Skipping uploading."
				}

			} else {
				$errorMsg = $toolOutput -join " | "
				Write-Log "ERROR: Backup failed. Details: $errorMsg"
			}

		}

	}

}

# end
Write-Log "INFO: Backup script finished."
Write-Log "INFO: Got $($projectFolders.Count) projects / $numRvtFound files, $numRvtBackedUp backed up / $numRvtUploaded uploaded."