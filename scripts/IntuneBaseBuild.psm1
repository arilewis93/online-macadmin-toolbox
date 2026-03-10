function Invoke-macOSLobAppUpload() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$SourceFile,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$displayName,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$Publisher,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [String]$Description,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$primaryBundleId,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [String]$primaryBundleVersion,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [hashtable[]]$includedApps,
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [Hashtable]$minimumSupportedOperatingSystem,
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [bool]$ignoreVersionDetection,
        [Parameter(Mandatory = $false)]
        [String]$preInstallScriptPath,
        [Parameter(Mandatory = $false)]
        [String]$postInstallScriptPath
    )
    try {
        # Check if the file exists and has a .Pkg extension
        if (!(Test-Path $SourceFile) -or (Get-Item $SourceFile).Extension -ne '.Pkg') {
            Write-Host "The provided path does not exist or is not an .Pkg file." -ForegroundColor Red
            throw
        }

        #Check if minmumSupportedOperatingSystem is provided. If not, default to v10_13
        if ($minimumSupportedOperatingSystem -eq $null) {
            $minimumSupportedOperatingSystem = @{ v10_13 = $true }
        }

        # Determine the correct path separator based on the OS
        $pathSeparator = if ($PSVersionTable.OS -match "Windows") { "\" } else { "/" }

        # Creating temp file name from Source File path
        $tempFile = [System.IO.Path]::GetDirectoryName($SourceFile) + $pathSeparator + [System.IO.Path]::GetFileNameWithoutExtension($SourceFile) + "_temp.bin"
        $fileName = (Get-Item $SourceFile).Name

        #Creating Intune app body JSON data to pass to the service
        Write-Host "Creating JSON data to pass to the service..." -ForegroundColor Yellow
        $body = New-macOSAppBody -displayName $displayName -Publisher $Publisher -Description $Description -fileName $fileName -primaryBundleId $primaryBundleId -primaryBundleVersion $primaryBundleVersion -includedApps $includedApps -minimumSupportedOperatingSystem $minimumSupportedOperatingSystem -ignoreVersionDetection $ignoreVersionDetection -preInstallScriptPath $preInstallScriptPath -postInstallScriptPath $postInstallScriptPath 

        # Create the Intune application object in the service
        Write-Host "Creating application in Intune..." -ForegroundColor Yellow
        $mobileApp = New-MgBetaDeviceAppManagementMobileApp -BodyParameter $body
        $mobileAppId = $mobileApp.id

        # Get the content version for the new app (this will always be 1 until the new app is committed).
        Write-Host "Creating Content Version in the service for the application..." -ForegroundColor Yellow
        $ContentVersion = New-MgBetaDeviceAppManagementMobileAppAsMacOSPkgAppContentVersion -MobileAppId $mobileAppId -BodyParameter @{}
        $ContentVersionId = $ContentVersion.id

        # Encrypt file and get file information
        Write-Host "Encrypting the copy of file '$SourceFile'..." -ForegroundColor Yellow
        $encryptionInfo = EncryptFile $SourceFile $tempFile
        $Size = (Get-Item "$SourceFile").Length
        $EncrySize = (Get-Item "$tempFile").Length

        $ContentVersionFileBody = @{
            name          = $fileName
            size          = $Size
            sizeEncrypted = $EncrySize
            manifest      = $null
            isDependency  = $false
            "@odata.type" = "#microsoft.graph.mobileAppContentFile"
        }

        # Create a new file entry in Azure for the upload
        Write-Host "Creating a new file entry in Azure for the upload..." -ForegroundColor Yellow
        $ContentVersionFile = New-MgBetaDeviceAppManagementMobileAppAsMacOSPkgAppContentVersionFile -MobileAppId $mobileAppId -MobileAppContentId $ContentVersionId -BodyParameter $ContentVersionFileBody
        $ContentVersionFileId = $ContentVersionFile.id

        # Get the file URI for the upload
        $fileUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$mobileAppId/microsoft.graph.macOSPkgApp/contentVersions/$contentVersionId/files/$contentVersionFileId"

        # Wait for the service to process the file upload request.
        Write-Host "Waiting for the service to process the file upload request..." -ForegroundColor Yellow
        $file = WaitForFileProcessing $fileUri "AzureStorageUriRequest"

        # Upload the content to Azure Storage.
        Write-Host "Uploading file to Azure Storage..." -ForegroundColor Yellow
        [UInt32]$BlockSizeMB = 1
        UploadFileToAzureStorage $file.azureStorageUri $tempFile $BlockSizeMB

        Write-Host "Committing the file to the service..." -ForegroundColor Yellow
        Invoke-MgBetaCommitDeviceAppManagementMobileAppMicrosoftGraphMacOSPkgAppContentVersionFile -MobileAppId $mobileAppId -MobileAppContentId $ContentVersionId -MobileAppContentFileId $ContentVersionFileId -BodyParameter ($encryptionInfo | ConvertTo-Json)

        # Wait for the service to process the commit file request.
        Write-Host "Waiting for the service to process the commit file request..." -ForegroundColor Yellow
        $file = WaitForFileProcessing $fileUri "CommitFile"

        # Commit the app.
        Write-Host "Committing the content version..." -ForegroundColor Yellow
        $params = @{
            "@odata.type"           = "#microsoft.graph.macOSPkgApp"
            committedContentVersion = "1"
        }
        
        Update-MgBetaDeviceAppManagementMobileApp -MobileAppId $mobileAppId -BodyParameter $params

        # Wait for the service to process the commit app request.
        Write-Host "Waiting for the service to process the commit app request..." -ForegroundColor Yellow
        Start-Sleep -Seconds 5

        # Display the app information from the Intune service
        $FinalAppStatus = (Get-MgDeviceAppManagementMobileApp -MobileAppId $mobileAppId)
        if ($FinalAppStatus.PublishingState -eq "published") {
            Write-Host "Application created successfully." -ForegroundColor Green
            return $mobileAppId
        }
        else {
            #raise exception if the app is not published
            Write-Host "Application '$displayName' has failed to upload to Intune." -ForegroundColor Red
            throw "Application '$displayName' has failed to upload to Intune."
        }
    }
    catch {
        Write-Host "Application '$displayName' has failed to upload to Intune." -ForegroundColor Red
        # In the event that the creation of the app record in Intune succeeded, but processing/file upload failed, you can remove the comment block around the code below to delete the app record.
        # This will allow you to re-run the script without having to manually delete the incomplete app record.
        # Note: This will only work if the app record was successfully created in Intune.

        <#
        if ($mobileAppId) {
            Write-Host "Removing the incomplete application record from Intune..." -ForegroundColor Yellow
            Remove-MgDeviceAppManagementMobileApp -MobileAppId $mobileAppId
        }
        #>
        Write-Host "Aborting with exception: $($_.Exception.ToString())" -ForegroundColor Red
        throw $_
    }
    finally {
        # Cleaning up temporary files and directories
        Remove-Item -Path "$tempFile" -Force -ErrorAction SilentlyContinue
    }
}

####################################################
# Function that uploads a source file chunk to the Intune Service SAS URI location.
function UploadAzureStorageChunk($sasUri, $id, $body) {
    $uri = "$sasUri&comp=block&blockid=$id"
    $request = "PUT $uri"

    $headers = @{
        "x-ms-blob-type" = "BlockBlob"
        "Content-Type"   = "application/octet-stream"
    }

    try {
        Invoke-WebRequest -Headers $headers $uri -Method Put -Body $body | Out-Null
    }
    catch {
        Write-Host -ForegroundColor Red $request
        Write-Host -ForegroundColor Red $_.Exception.Message
        throw
    }
}

####################################################
# Function that takes all the chunk ids and joins them back together to recreate the file
function FinalizeAzureStorageUpload($sasUri, $ids) {
    $uri = "$sasUri&comp=blocklist"
    $request = "PUT $uri"

    $xml = '<?xml version="1.0" encoding="utf-8"?><BlockList>'
    foreach ($id in $ids) {
        $xml += "<Latest>$id</Latest>"
    }
    $xml += '</BlockList>'

    if ($logRequestUris) { Write-Host $request; }
    if ($logContent) { Write-Host -ForegroundColor Gray $xml; }

    $headers = @{
        "Content-Type" = "text/plain"
    }

    try {
        Invoke-WebRequest $uri -Method Put -Body $xml -Headers $headers
    }
    catch {
        Write-Host -ForegroundColor Red $request
        Write-Host -ForegroundColor Red $_.Exception.Message
        throw
    }
}

####################################################
# Function that splits the source file into chunks and calls the upload to the Intune Service SAS URI location, and finalizes the upload
function UploadFileToAzureStorage($sasUri, $filepath, $blockSizeMB) {
    # Chunk size in MiB
    $chunkSizeInBytes = 1024 * 1024 * $blockSizeMB

    # Read the whole file and find the total chunks.
    #[byte[]]$bytes = Get-Content $filepath -Encoding byte;
    # Using ReadAllBytes method as the Get-Content used alot of memory on the machine
    $fileStream = [System.IO.File]::OpenRead($filepath)
    $chunks = [Math]::Ceiling($fileStream.Length / $chunkSizeInBytes)

    # Upload each chunk.
    $ids = @()
    $cc = 1
    $chunk = 0
    while ($fileStream.Position -lt $fileStream.Length) {
        $id = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($chunk.ToString("0000")))
        $ids += $id

        $size = [Math]::Min($chunkSizeInBytes, $fileStream.Length - $fileStream.Position)
        $body = New-Object byte[] $size
        $fileStream.Read($body, 0, $size) > $null
        $totalBytes += $size

        Write-Progress -Activity "Uploading File to Azure Storage" -Status "Uploading chunk $cc of $chunks"
        $cc++

        UploadAzureStorageChunk $sasUri $id $body | Out-Null
        $chunk++
    }

    $fileStream.Close()
    Write-Progress -Completed -Activity "Uploading File to Azure Storage"

    # Finalize the upload.
    FinalizeAzureStorageUpload $sasUri $ids | Out-Null
}

####################################################
# Function to generate encryption key
function GenerateKey {
    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aesProvider = New-Object System.Security.Cryptography.AesCryptoServiceProvider
        $aesProvider.GenerateKey()
        $aesProvider.Key
    }
    finally {
        if ($null -ne $aesProvider) { $aesProvider.Dispose(); }
        if ($null -ne $aes) { $aes.Dispose(); }
    }
}

####################################################
# Function to generate HMAC key
function GenerateIV {
    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.IV
    }
    finally {
        if ($null -ne $aes) { $aes.Dispose(); }
    }
}

####################################################
# Function to create the encrypted target file compute HMAC value, and return the HMAC value
function EncryptFileWithIV($sourceFile, $targetFile, $encryptionKey, $hmacKey, $initializationVector) {
    $bufferBlockSize = 1024 * 4
    $computedMac = $null

    try {
        $aes = [System.Security.Cryptography.Aes]::Create()
        $hmacSha256 = New-Object System.Security.Cryptography.HMACSHA256
        $hmacSha256.Key = $hmacKey
        $hmacLength = $hmacSha256.HashSize / 8

        $buffer = New-Object byte[] $bufferBlockSize
        $bytesRead = 0

        $targetStream = [System.IO.File]::Open($targetFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
        $targetStream.Write($buffer, 0, $hmacLength + $initializationVector.Length)

        try {
            $encryptor = $aes.CreateEncryptor($encryptionKey, $initializationVector)
            $sourceStream = [System.IO.File]::Open($sourceFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
            $cryptoStream = New-Object System.Security.Cryptography.CryptoStream -ArgumentList @($targetStream, $encryptor, [System.Security.Cryptography.CryptoStreamMode]::Write)

            $targetStream = $null
            while (($bytesRead = $sourceStream.Read($buffer, 0, $bufferBlockSize)) -gt 0) {
                $cryptoStream.Write($buffer, 0, $bytesRead)
                $cryptoStream.Flush()
            }
            $cryptoStream.FlushFinalBlock()
        }
        finally {
            if ($null -ne $cryptoStream) { $cryptoStream.Dispose(); }
            if ($null -ne $sourceStream) { $sourceStream.Dispose(); }
            if ($null -ne $encryptor) { $encryptor.Dispose(); }
        }

        try {
            $finalStream = [System.IO.File]::Open($targetFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::Read)
            $finalStream.Seek($hmacLength, [System.IO.SeekOrigin]::Begin) > $null
            $finalStream.Write($initializationVector, 0, $initializationVector.Length)
            $finalStream.Seek($hmacLength, [System.IO.SeekOrigin]::Begin) > $null
            $hmac = $hmacSha256.ComputeHash($finalStream)
            $computedMac = $hmac
            $finalStream.Seek(0, [System.IO.SeekOrigin]::Begin) > $null
            $finalStream.Write($hmac, 0, $hmac.Length)
        }
        finally {
            if ($null -ne $finalStream) { $finalStream.Dispose(); }
        }
    }
    finally {
        if ($null -ne $targetStream) { $targetStream.Dispose(); }
        if ($null -ne $aes) { $aes.Dispose(); }
    }

    $computedMac
}

####################################################
# Function to encrypt file and return encryption info
function EncryptFile($sourceFile, $targetFile) {
    $encryptionKey = GenerateKey
    $hmacKey = GenerateKey
    $initializationVector = GenerateIV

    # Create the encrypted target file and compute the HMAC value.
    $mac = EncryptFileWithIV $sourceFile $targetFile $encryptionKey $hmacKey $initializationVector

    # Compute the SHA256 hash of the source file and convert the result to bytes.
    $fileDigest = (Get-FileHash $sourceFile -Algorithm SHA256).Hash
    $fileDigestBytes = New-Object byte[] ($fileDigest.Length / 2)
    for ($i = 0; $i -lt $fileDigest.Length; $i += 2) {
        $fileDigestBytes[$i / 2] = [System.Convert]::ToByte($fileDigest.Substring($i, 2), 16)
    }

    # Return an object that will serialize correctly to the file commit Graph API.
    $encryptionInfo = @{}
    $encryptionInfo.encryptionKey = [System.Convert]::ToBase64String($encryptionKey)
    $encryptionInfo.macKey = [System.Convert]::ToBase64String($hmacKey)
    $encryptionInfo.initializationVector = [System.Convert]::ToBase64String($initializationVector)
    $encryptionInfo.mac = [System.Convert]::ToBase64String($mac)
    $encryptionInfo.profileIdentifier = "ProfileVersion1"
    $encryptionInfo.fileDigest = [System.Convert]::ToBase64String($fileDigestBytes)
    $encryptionInfo.fileDigestAlgorithm = "SHA256"

    $fileEncryptionInfo = @{}
    $fileEncryptionInfo.fileEncryptionInfo = $encryptionInfo
    $fileEncryptionInfo
}

####################################################
# Function to wait for file processing to complete by polling the file upload state
function WaitForFileProcessing($fileUri, $stage) {
    $attempts = 60
    $waitTimeInSeconds = 1
    $successState = "$($stage)Success"
    $pendingState = "$($stage)Pending"

    $file = $null
    while ($attempts -gt 0) {
        $file = Invoke-MgGraphRequest -Method GET -Uri $fileUri
        if ($file.uploadState -eq $successState) {
            break
        }
        elseif ($file.uploadState -ne $pendingState) {
            throw "File upload state is not success: $($file.uploadState)"
        }

        Start-Sleep $waitTimeInSeconds
        $attempts--
    }

    if ($null -eq $file) {
        throw "File request did not complete in the allotted time."
    }
    $file
}

####################################################
# Function to generate body for mobileAppContentFile
function GetAppFileBody($name, $size, $sizeEncrypted, $manifest) {
    $body = @{ "@odata.type" = "#microsoft.graph.macOSPkgApp" }
    $body.name = $name
    $body.size = $size
    $body.sizeEncrypted = $sizeEncrypted
    $body.manifest = $manifest
    $body
}

####################################################
# Function to generate body for commit action
function GetAppCommitBody($contentVersionId, $LobType) {
    $body = @{ "@odata.type" = "#$LobType" }
    $body.committedContentVersion = $contentVersionId
    $body
}

#Function to encode the pre and post install scripts in base64
function Convert-ScriptToBase64($scriptPath) {
    if ([string]::IsNullOrEmpty($scriptPath) -or !(Test-Path $scriptPath)) {
        return $null
    }
    $script = Get-Content $scriptPath -Raw
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($script)
    $encoded = [System.Convert]::ToBase64String($bytes)
    return $encoded
}

####################################################
# Function to generate body for Intune mobileapp
function New-macOSAppBody() {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$displayName,
        [Parameter(Mandatory = $true)]
        [string]$Publisher,
        [Parameter(Mandatory = $false)]
        [string]$Description,
        [Parameter(Mandatory = $true)]
        [string]$fileName,
        [Parameter(Mandatory = $true)]
        [string]$primaryBundleId,
        [Parameter(Mandatory = $true)]
        [string]$primaryBundleVersion,
        [Parameter(Mandatory = $true)]
        [hashtable[]]$includedApps,
        [Parameter(Mandatory = $false)]
        [hashtable]$minimumSupportedOperatingSystem,
        [Parameter(Mandatory = $true)]
        [bool]$ignoreVersionDetection,
        [Parameter(Mandatory = $false)]
        [string]$preInstallScriptPath,
        [Parameter(Mandatory = $false)]
        [string]$postInstallScriptPath
    )

    $body = @{ "@odata.type" = "#microsoft.graph.macOSPkgApp" }
    $body.isFeatured = $false
    $body.categories = @()
    $body.displayName = $displayName
    $body.publisher = $Publisher
    $body.description = $description
    $body.fileName = $fileName
    $body.informationUrl = ""
    $body.privacyInformationUrl = ""
    $body.developer = ""
    $body.notes = ""
    $body.owner = ""
    $body.primaryBundleId = $primaryBundleId
    $body.primaryBundleVersion = $primaryBundleVersion
    $body.includedApps = $includedApps
    $body.ignoreVersionDetection = $ignoreVersionDetection

    if ($null -eq $minimumSupportedOperatingSystem) {
        $body.minimumSupportedOperatingSystem = @{ v10_13 = $true }
    }
    else {
        $body.minimumSupportedOperatingSystem = $minimumSupportedOperatingSystem
    }

    if ($preInstallScriptPath) {
        $preInstallContent = Convert-ScriptToBase64($preInstallScriptPath)
        if ($preInstallContent) {
            $body.preInstallScript = @{
                scriptContent = $preInstallContent
            }
        } else {
            $body.preInstallScript = $null
        }
    }
    else {
        $body.preInstallScript = $null
    }

    if ($postInstallScriptPath) {
        $postInstallContent = Convert-ScriptToBase64($postInstallScriptPath)
        if ($postInstallContent) {
            $body.postInstallScript = @{
                scriptContent = $postInstallContent
            }
        } else {
            $body.postInstallScript = $null
        }
    }
    else {
        $body.postInstallScript = $null
    }
    
    return $body
}

####################################################
# Function to connect to Microsoft Graph and return the tenant ID
function Connect-IntuneGraph {
    try {

        # Connect to Microsoft Graph
        Connect-MgGraph -Scopes 'DeviceManagementApps.ReadWrite.All, DeviceManagementConfiguration.ReadWrite.All, DeviceManagementServiceConfig.ReadWrite.All, Group.ReadWrite.All, User.Read.All, Organization.Read.All' -NoWelcome
        
        # Get and return the tenant ID
        $context = Get-MgContext
        
        # Write-Host "Successfully connected to tenant: $($context.TenantId)" -ForegroundColor Green
        return $context.TenantId
    }
    catch {
        Write-Host "Failed to connect to Microsoft Graph: $_" -ForegroundColor Red
        return $null
    }
}

####################################################
# Function to create the FileVault profile
function New-FileVault() {
    param (
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    # Check if FileVault needs to be done
    $configProfiles = Get-MgBetaDeviceManagementConfigurationPolicy

    # Check if the "FileVault" profile exists
    $fileVaultProfile = $configProfiles | Where-Object { $_.Name -eq "FileVault" }

    # If profile exists, validate it
    if ($fileVaultProfile) {
        Write-Host "Found existing FileVault profile. Validating configuration..." -ForegroundColor Yellow
        $isValid = Test-FileVaultConfiguration
        
        if ($isValid) {
            Write-Host "Existing FileVault profile is correctly configured." -ForegroundColor Green
            
            # If GroupId is provided, assign the profile
            if ($GroupId) {
                try {
                    Assign-SettingsCatalogToGroup -ConfigId $fileVaultProfile.Id -GroupId $GroupId
                    return "SUCCESS:$($fileVaultProfile.Id)"
                }
                catch {
                    return "ASSIGN_FAILED:$($fileVaultProfile.Id)"
                }
            }
            return "SUCCESS:$($fileVaultProfile.Id)"
        } else {
            return "CONFIG_MISMATCH:$($fileVaultProfile.Id)"
        }
    }

    # If no profile exists, create a new one
    Write-Host "No FileVault profile found. Creating new profile..." -ForegroundColor Yellow

    $jsonString = @"
{
  "@odata.context": "https://graph.microsoft.com/beta/$metadata#deviceManagement/configurationPolicies(settings())/$entity",
  "createdDateTime": "2024-11-19T08:00:17.5399929Z",
  "description": "",
  "id": "0c31a102-e6d5-4bf0-b30a-0cc34905e009",
  "lastModifiedDateTime": "2024-11-19T08:00:17.5399929Z",
  "name": "FileVault",
  "platforms": "macOS",
  "roleScopeTagIds": [
      "0"
  ],
  "settingCount": 3,
  "settings": [
      {
          "id": "0",
          "settingInstance": {
              "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
              "groupSettingCollectionValue": [
                  {
                      "children": [
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_defer_true"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_defer"
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_deferdontaskatuserlogout_true"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_deferdontaskatuserlogout"
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance",
                              "settingDefinitionId": "com.apple.mcx.filevault2_deferforceatuserloginmaxbypassattempts",
                              "simpleSettingValue": {
                                  "@odata.type": "#microsoft.graph.deviceManagementConfigurationIntegerSettingValue",
                                  "value": 0
                              }
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_enable_0"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_enable"
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_forceenableinsetupassistant_true"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_forceenableinsetupassistant"
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_recoverykeyrotationinmonths_0"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_recoverykeyrotationinmonths"
                          },
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx.filevault2_showrecoverykey_false"
                              },
                              "settingDefinitionId": "com.apple.mcx.filevault2_showrecoverykey"
                          }
                      ]
                  }
              ],
              "settingDefinitionId": "com.apple.mcx.filevault2_com.apple.mcx.filevault2"
          }
      },
      {
          "id": "1",
          "settingInstance": {
              "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
              "groupSettingCollectionValue": [
                  {
                      "children": [
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationChoiceSettingInstance",
                              "choiceSettingValue": {
                                  "children": [],
                                  "value": "com.apple.mcx_dontallowfdedisable_true"
                              },
                              "settingDefinitionId": "com.apple.mcx_dontallowfdedisable"
                          }
                      ]
                  }
              ],
              "settingDefinitionId": "com.apple.mcx_com.apple.mcx-fdefilevaultoptions"
          }
      },
      {
          "id": "2",
          "settingInstance": {
              "@odata.type": "#microsoft.graph.deviceManagementConfigurationGroupSettingCollectionInstance",
              "groupSettingCollectionValue": [
                  {
                      "children": [
                          {
                              "@odata.type": "#microsoft.graph.deviceManagementConfigurationSimpleSettingInstance",
                              "settingDefinitionId": "com.apple.security.fderecoverykeyescrow_location",
                              "simpleSettingValue": {
                                  "@odata.type": "#microsoft.graph.deviceManagementConfigurationStringSettingValue",
                                  "value": "Contact IT"
                              }
                          }
                      ]
                  }
              ],
              "settingDefinitionId": "com.apple.security.fderecoverykeyescrow_com.apple.security.fderecoverykeyescrow"
          }
      }
  ],
  "settings@odata.context": "https://graph.microsoft.com/beta/$metadata#deviceManagement/configurationPolicies('0c31a102-e6d5-4bf0-b30a-0cc34905e009')/settings",
  "technologies": "mdm,appleRemoteManagement",
  "templateReference": {
      "templateId": ""
  }
}
"@

    # Convert JSON string to a PowerShell object
    $jsonBody = $jsonString | ConvertFrom-Json

    # Define the URL for the API endpoint
    $url = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"

    # Send the POST request
    try {
        $response = Invoke-MgGraphRequest -Method POST -Uri $url -Body ($jsonBody | ConvertTo-Json -Depth 10) -ContentType "application/json"

        if ($response -and $response.id) {
            if ($GroupId) {
                try {
                    Assign-SettingsCatalogToGroup -ConfigId $response.id -GroupId $GroupId
                    return "SUCCESS:$($response.id)"
                }
                catch {
                    return "ASSIGN_FAILED:$($response.id)"
                }
            }
            return "SUCCESS:$($response.id)"
        } else {
            return "CREATE_FAILED"
        }
    } catch {
        return "CREATE_FAILED"
    }
}

####################################################
# Function to create the enrollment profile
function New-EnrollmentProfile() {
    # Get all DEP onboarding settings
    $depOnboardingSettings = Get-MgBetaDeviceManagementDepOnboardingSetting

    # Initialize success counter
    $successCount = 0

    foreach ($depOnboardingSetting in $depOnboardingSettings) {
        $depOnboardingSettingId = $depOnboardingSetting.Id

        # Get all enrollment profiles for this DEP onboarding setting
        $profiles = Get-MgBetaDeviceManagementDepOnboardingSettingEnrollmentProfile `
            -DepOnboardingSettingId $depOnboardingSettingId

        # Define the description to look for
        $targetDescription = "iStore Business Enrollment Profile"

        # Initialize a flag to track if the target description is found
        $descriptionFound = $false

        # Loop through each profile
        foreach ($profile in $profiles) {
            if ($profile.Description -eq $targetDescription) {
                $descriptionFound = $true
                Write-Host "Enrollment Profile already exists for DEP token: $($depOnboardingSetting.AppleIdentifier)" -ForegroundColor Yellow
                break
            }
        }

        # Check the flag and create new profile if needed
        if (-not $descriptionFound) {
            try {
                # Define the new macOS DEP enrollment profile data as a hashtable
                $newProfileData = @{
                    "@odata.type" = "#microsoft.graph.depMacOSEnrollmentProfile"
                    displayName = "macOS Enrollment Profile"
                    description = "iStore Business Enrollment Profile"
                    requiresUserAuthentication = $true
                    enableAuthenticationViaCompanyPortal = $false
                    requireCompanyPortalOnSetupAssistantEnrolledDevices = $false
                    waitForDeviceConfiguredConfirmation = $true
                    supervisedModeEnabled = $true
                    supportDepartment = 'IT'
                    isMandatory = $true
                    locationDisabled = $false
                    supportPhoneNumber = '011 535 9000'
                    profileRemovalDisabled = $true
                    restoreBlocked = $true
                    appleIdDisabled = $true
                    termsAndConditionsDisabled = $true
                    touchIdDisabled = $false
                    applePayDisabled = $true
                    siriDisabled = $true
                    diagnosticsDisabled = $true
                    displayToneSetupDisabled = $true
                    privacyPaneDisabled = $true
                    screenTimeScreenDisabled = $true
                    deviceNameTemplate = ''
                    configurationWebUrl = $true
                    enabledSkipKeys = @(
                        'Restore'
                        'AppleID'
                        'TOS'
                        'Payment'
                        'Siri'
                        'Diagnostics'
                        'Privacy'
                        'ScreenTime'
                        'iCloudDiagnostics'
                        'iCloudStorage'
                        'DisplayTone'
                        'Registration'
                        'Accessibility'
                        'UnlockWithWatch'
                        'TermsOfAddress'
                        'Intelligence'
                        'EnableLockdownMode'
                        'Wallpaper'
                        'SoftwareUpdate'
                        'UpdateCompleted'
                        'OSShowcase'
                        'AppStore'
                        'AdditionalPrivacySettings'
                    )
                    registrationDisabled = $true
                    fileVaultDisabled = $false
                    iCloudDiagnosticsDisabled = $true
                    passCodeDisabled = $false
                    zoomDisabled = $false
                    iCloudStorageDisabled = $true
                    chooseYourLockScreenDisabled = $true
                    accessibilityScreenDisabled = $true
                    autoUnlockWithWatchDisabled = $false
                    skipPrimarySetupAccountCreation = $false
                    setPrimarySetupAccountAsRegularUser = $false
                    dontAutoPopulatePrimaryAccountInfo = $false
                    primaryAccountFullName = '{{username}}'
                    primaryAccountUserName = '{{partialupn}}'
                    enableRestrictEditing = $true
                    hideAdminAccount = $false
                    requestRequiresNetworkTether = $false
                    autoAdvanceSetupEnabled = $false
                    depProfileAdminAccountPasswordRotationSetting = @{
                        "@odata.type" = "microsoft.graph.depProfileAdminAccountPasswordRotationSetting"
                        autoRotationPeriodInDays = 180
                        depProfileDelayAutoRotationSetting = @{
                            "@odata.type" = "microsoft.graph.depProfileDelayAutoRotationSetting"
                            onRetrievalAutoRotatePasswordEnabled = $true
                            onRetrievalDelayAutoRotatePasswordInHours = 9
                        }
                    }
                }

                # Make the POST request using Invoke-MgGraphRequest
                $response = Invoke-MgGraphRequest -Method POST `
                    -Uri "https://graph.microsoft.com/beta/deviceManagement/depOnboardingSettings/{$depOnboardingSettingId}/enrollmentProfiles" `
                    -Body ($newProfileData | ConvertTo-Json -Depth 10) `
                    -ContentType "application/json"

                # Check if the request was successful
                if ($null -ne $response.id) {
                    Write-Host "Enrollment Profile created successfully for DEP token: $($depOnboardingSetting.AppleIdentifier)" -ForegroundColor Green
                    $successCount++
                } else {
                    Write-Host "Failed to create Enrollment Profile for DEP token: $($depOnboardingSetting.AppleIdentifier)" -ForegroundColor Red
                    Write-Host $response -ForegroundColor Red
                }
            }
            catch {
                Write-Host "Error creating Enrollment Profile for DEP token: $($depOnboardingSetting.AppleIdentifier)" -ForegroundColor Red
                Write-Host $_.Exception.Message -ForegroundColor Red
            }
        }
    }

    if ($successCount -gt 0) {
        Write-Host "Enrollment Profile created successfully for $successCount tokens." -ForegroundColor Green
    } else {
        Write-Host "No new Enrollment Profiles were created." -ForegroundColor Yellow
    }
}

####################################################
# Function to upload a single PKG file
function New-SinglePKG {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$PackageId,
        [Parameter(Mandatory = $true)]
        [string]$PackageVersion,
        [Parameter(Mandatory = $false)]
        [string]$DisplayName,
        [Parameter(Mandatory = $false)]
        [string]$PreInstallScriptPath,
        [Parameter(Mandatory = $false)]
        [string]$PostInstallScriptPath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    # Use the provided package ID and version
    $primaryBundleId = $PackageId
    $primaryBundleVersion = $PackageVersion

    # Create includedApps array with the single package
    $includedApps = @()
    $appEntry = @{
        "@odata.type" = "microsoft.graph.macOSIncludedApp"
        bundleId = $primaryBundleId
        bundleVersion = $primaryBundleVersion
    }
    $includedApps += $appEntry

    if (-not $DisplayName) {
        $DisplayName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    }

    try {
        Write-Host "Starting app upload..." -ForegroundColor Yellow
        # Store the response from Invoke-macOSLobAppUpload
        $appId = Invoke-macOSLobAppUpload -SourceFile $FilePath `
                                -displayName $DisplayName `
                                -Publisher "iStore Business" `
                                -Description (Split-Path $FilePath -Leaf) `
                                -primaryBundleId $primaryBundleId `
                                -primaryBundleVersion $primaryBundleVersion `
                                -includedApps $includedApps `
                                -ignoreVersionDetection $true `
                                -preInstallScriptPath $PreInstallScriptPath `
                                -postInstallScriptPath $PostInstallScriptPath

        if ([string]::IsNullOrEmpty($appId)) {
            throw "Upload completed but no app ID was returned"
        }

        if ($GroupId) {
            try {
                Assign-AppToGroup -AppId $appId -GroupId $GroupId
            }
            catch {
                Write-Host "Failed to assign application to group: $_" -ForegroundColor Red
            }
        }
    }
    catch {
        Write-Host "Failed to create application: $_" -ForegroundColor Red
    }
}

####################################################
# Function to upload a single MOBILECONFIG file
function New-SingleMobileConfig {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    # Read the .mobileconfig file and encode it to byte array
    $mobileconfigContent = [System.IO.File]::ReadAllBytes($FilePath)
    $fileName = Split-Path $FilePath -Leaf
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)

    $profileData = @{
        "@odata.type" = "#microsoft.graph.macOSCustomConfiguration"
        deploymentChannel = "deviceChannel"
        payload = [System.Convert]::ToBase64String($mobileconfigContent)
        payloadFileName = $fileName
        payloadName = $displayName
        displayName = $displayName
        description = "Custom macOS Configuration $displayName"
    }

    try {
        $response = New-MgBetaDeviceManagementDeviceConfiguration -BodyParameter $profileData
        Write-Host "Successfully uploaded $fileName" -ForegroundColor Green

        if ($GroupId) {
            try {
                Assign-ConfigToGroup -ConfigId $response.id -GroupId $GroupId
            }
            catch {
                Write-Host "Failed to assign configuration profile to group: $_" -ForegroundColor Red
            }
        }
    } catch {
        Write-Host ("Error uploading " + $fileName + ": " + $_.Exception.Message) -ForegroundColor Red
    }
}

####################################################
# Function to upload a single iOS MOBILECONFIG file
function New-SingleiOSMobileConfig {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    # Read the .mobileconfig file and encode it to byte array
    $mobileconfigContent = [System.IO.File]::ReadAllBytes($FilePath)
    $fileName = Split-Path $FilePath -Leaf
    $displayName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
    
    # Strip the "ios_" prefix from the display name for Intune
    if ($displayName.StartsWith("ios_")) {
        $displayName = $displayName.Substring(4)
    }

    $profileData = @{
        "@odata.type" = "#microsoft.graph.iosCustomConfiguration"
        deploymentChannel = "deviceChannel"
        payload = [System.Convert]::ToBase64String($mobileconfigContent)
        payloadFileName = $fileName
        payloadName = $displayName
        displayName = $displayName
        description = "Custom iOS Configuration $displayName"
    }

    try {
        $response = New-MgBetaDeviceManagementDeviceConfiguration -BodyParameter $profileData
        Write-Host "Successfully uploaded iOS configuration $fileName" -ForegroundColor Green

        if ($GroupId) {
            try {
                Assign-ConfigToGroup -ConfigId $response.id -GroupId $GroupId
            }
            catch {
                Write-Host "Failed to assign iOS configuration profile to group: $_" -ForegroundColor Red
            }
        }
    } catch {
        Write-Host ("Error uploading iOS configuration " + $fileName + ": " + $_.Exception.Message) -ForegroundColor Red
    }
}

####################################################
# Function to upload a single Shell script
function New-SingleShellScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    try {
        # Get just the filename for the display name
        $fileName = Split-Path $FilePath -Leaf
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $fileContent = Get-Content -Path $FilePath -Raw
        $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
        $base64Content = [Convert]::ToBase64String($fileBytes)

        # Create the body as a hashtable first
        $body = @{
            '@odata.type' = '#microsoft.graph.deviceShellScript'
            'retryCount' = 10
            'blockExecutionNotifications' = $true
            'displayName' = $baseName
            'scriptContent' = $base64Content
            'runAsAccount' = 'system'
            'fileName' = $fileName
        }

        # Convert to JSON string explicitly
        $jsonBody = ConvertTo-Json -InputObject $body -Depth 10 -Compress

        $url = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts"

        # Make the request and capture response
        $response = Invoke-MgGraphRequest -Method POST -Uri $url -Body $jsonBody -ContentType "application/json"

        if ($null -ne $response -and $response.id) {

            if ($GroupId) {
                try {
                    Assign-ScriptToGroup -ScriptId $response.id -GroupId $GroupId
                }
                catch {
                    Write-Host "Failed to assign script to group: $_" -ForegroundColor Red
                }
            }
            Write-Host "Successfully uploaded shell script: $baseName" -ForegroundColor Green
        } else {
            throw "Failed to get valid response ID from script upload"
        }
    } catch {
        Write-Host ("Error processing " + $fileName + ": " + $_) -ForegroundColor Red
        throw $_
    }
}

####################################################
# Function to upload a single JSON configuration
function New-SingleJSON {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId  # Optional group ID parameter
    )

    try {
        $jsonContent = Get-Content -Path $FilePath -Raw | ConvertFrom-Json
        $requiredDepth = Get-ObjectDepth $jsonContent
        $jsonBody = $jsonContent | ConvertTo-Json -Depth $requiredDepth -Compress
        $url = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies"

        $response = Invoke-MgGraphRequest -Method POST -Uri $url -Body $jsonBody -ContentType "application/json"

        if ($response -and $response.id) {
            Write-Host "Configuration profile created successfully. ID: $($response.id)" -ForegroundColor Green

            if ($GroupId) {
                try {
                    Assign-SettingsCatalogToGroup -ConfigId $response.id -GroupId $GroupId
                }
                catch {
                    Write-Host "Failed to assign configuration profile to group: $_" -ForegroundColor Red
                }
            }
        }
    } catch {
        Write-Host "Failed to create configuration profile: $_" -ForegroundColor Red
    }
}


####################################################
# Function to upload a single Custom Attribute script
function New-SingleCustomAttributeScript {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$GroupId
    )

    try {
        $fileName = Split-Path $FilePath -Leaf
        $baseName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
        $dataType = 'string'
        $customAttributeName = $baseName

        $fileContent = Get-Content -Path $FilePath -Raw
        $fileBytes = [System.Text.Encoding]::UTF8.GetBytes($fileContent)
        $base64Content = [Convert]::ToBase64String($fileBytes)

        $jsonBody = @{
            '@odata.type' = '#microsoft.graph.deviceCustomAttributeShellScript'
            'customAttributeName' = $customAttributeName
            'customAttributeType' = $dataType
            'displayName' = $customAttributeName
            'description' = 'Description value'
            'scriptContent' = $base64Content
            'runAsAccount' = 'system'
            'fileName' = "$customAttributeName.sh"
        }

        $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCustomAttributeShellScripts"
        $response = Invoke-MgGraphRequest -Method POST -Uri $url -Body $jsonBody -ContentType "application/json"

        if ($response -and $response.id) {
            Write-Host "$fileName upload successful." -ForegroundColor Green
            
            # If GroupId is provided, assign the script to the group
            if ($GroupId) {
                try {
                    Assign-CustomAttributeToGroup -ScriptId $response.id -GroupId $GroupId
                }
                catch {
                    Write-Host "Failed to assign custom attribute script to group: $_" -ForegroundColor Red
                }
            }
        } else {
            Write-Host "Failed to upload $fileName." -ForegroundColor Red
        }
    } catch {
        Write-Host ("Error processing " + $fileName + ": "+ $_) -ForegroundColor Red
    }
}

####################################################
# Function to assign a custom attribute script to a group
function Assign-CustomAttributeToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptId,
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $body = @{
        deviceManagementScriptAssignments = @(
            @{
                "@odata.type" = "#microsoft.graph.deviceManagementScriptAssignment"
                target = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    deviceAndAppManagementAssignmentFilterId = $null
                    deviceAndAppManagementAssignmentFilterType = "none"
                    groupId = $GroupId
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceCustomAttributeShellScripts/$ScriptId/assign"

    try {
        Invoke-MgGraphRequest -Method POST -Uri $url -Body $body -ContentType "application/json"
        Write-Host "Successfully assigned custom attribute script to group" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to assign custom attribute script to group: $_" -ForegroundColor Red
        throw
    }
}

####################################################
# Function to create a static group
function New-IntuneStaticGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DisplayName,
        [string]$Description = "iStore Business PoC Group"
    )

    try {
        # First, search for existing group with the same display name
        $existingGroup = Get-MgGroup -Filter "displayName eq '$DisplayName'"

        if ($existingGroup) {
            return $existingGroup.Id
        }

        # If no existing group found, create a new one
        $mailNickname = ($DisplayName -replace '\s', '') + (Get-Random -Maximum 9999)

        $group = New-MgGroup -DisplayName $DisplayName `
                            -Description $Description `
                            -MailEnabled:$false `
                            -MailNickname $mailNickname `
                            -SecurityEnabled:$true `
                            -GroupTypes @()

        return $group.Id
    }
    catch {
        return $null
    }
}

####################################################
# Function to assign the current user to a group
function Assign-CurrentUserToGroup {
    param (
        [Parameter(Mandatory=$true)]
        $GroupId
    )
    
    # Get current user's information
    $currentUser = Get-MgContext
    
    # Get the user using the account information
    try {
        $user = Get-MgUser -Filter "userPrincipalName eq '$($currentUser.Account)'"
        if (-not $user) {
            Write-Host "Could not find user with account: $($currentUser.Account)" -ForegroundColor Red
            return
        }
        
        # Check if user is already a member of the group
        $existingMembers = Get-MgGroupMember -GroupId $GroupId
        $isMember = $existingMembers | Where-Object { $_.Id -eq $user.Id }
        
        if (-not $isMember) {
            Write-Host "Adding user to security group..." -ForegroundColor Green
            New-MgGroupMember -GroupId $GroupId -DirectoryObjectId $user.Id
            Write-Host "Successfully added user to security group" -ForegroundColor Green
        } else {
            Write-Host "User is already a member of the security group" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    }
}

####################################################
# Function to assign a macOS configuration profile to a group
function Assign-ConfigToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigId,
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $body = @{
        assignments = @(
            @{
                target = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    groupId       = $GroupId
                }
            }
        )
    } | ConvertTo-Json -Depth 5

    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations/$ConfigId/assign"


    try {
        Invoke-MgGraphRequest -Method POST -Uri $url -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "Failed to assign config $ConfigId to group $GroupId. Error: $_" -ForegroundColor Red
    }

}


####################################################
# Function to assign a macOS app to a group
function Assign-AppToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$AppId,
        [Parameter(Mandatory = $true)]
        [string]$GroupId,
        [ValidateSet("required", "available", "uninstall")]
        [string]$Intent = "required"
    )

    $body = @{
        mobileAppAssignments = @(
            @{
                "@odata.type" = "#microsoft.graph.mobileAppAssignment"
                intent        = $Intent
                settings     = $null
                target       = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    groupId       = $GroupId
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    $url = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$AppId/assign"

    try {
        Invoke-MgGraphRequest -Method POST -Uri $url -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "Failed to assign app $AppId to group $GroupId. Error: $_" -ForegroundColor Red
    }
}

####################################################
# Function to assign a macOS script to a group
function Assign-ScriptToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ScriptId,
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $body = @{
        deviceManagementScriptAssignments = @(
            @{
                "@odata.type" = "#microsoft.graph.deviceManagementScriptAssignment"
                target = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    deviceAndAppManagementAssignmentFilterId = $null
                    deviceAndAppManagementAssignmentFilterType = "none"
                    groupId = $GroupId
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    # Using the correct endpoint for shell scripts
    $url = "https://graph.microsoft.com/beta/deviceManagement/deviceShellScripts/$ScriptId/assign"

    try {
        Invoke-MgGraphRequest -Method POST -Uri $url -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "Failed to assign script $ScriptId to group $GroupId. Error: $_" -ForegroundColor Red
    }
}


####################################################
# Function to delete all macOS apps
function Delete-MacOSApps() {
    # Retrieve all mobile apps
    $apps = Get-MgDeviceAppManagementMobileApp

    # Filter apps locally based on AdditionalProperties
    $macOSApps = $apps | Where-Object {
        $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.mobileLobApp' -and
        $_.AdditionalProperties.'fileName' -match '\.pkg$'
    }

    # Delete the filtered macOS apps
    foreach ($app in $macOSApps) {
        Write-Output "Deleting macOS app: $($app.DisplayName) ($($app.Id))"
        Remove-MgDeviceAppManagementMobileApp -MobileAppId $app.Id -Confirm:$false
    }
}

####################################################
# Function to delete all macOS device configurations
function Delete-MacOSConfigurations() {
    $configs = Get-MgDeviceManagementDeviceConfiguration

    # Filter device configurations locally based on AdditionalProperties
    $configs = $configs | Where-Object {
        $_.AdditionalProperties.'@odata.type' -eq '#microsoft.graph.macOSCustomConfiguration'
    }

    foreach ($config in $configs) {
        Write-Output "Deleting configuration: $($config.DisplayName) ($($config.Id))"
        Remove-MgDeviceManagementDeviceConfiguration -DeviceConfigurationId $config.Id -Confirm:$false
    }
}

####################################################
# Function to delete all macOS device configurations
function Delete-MacOSConfigurationsSettingsCatalog {
    # Get all configuration policies
    $configs = Get-MgBetaDeviceManagementConfigurationPolicy

    # Filter the configurations where Platforms is 'macOS'
    $macOSConfigs = $configs | Where-Object { $_.Platforms -contains "macOS" }

    # Check if any macOS configurations exist
    if ($macOSConfigs.Count -gt 0) {
        foreach ($config in $macOSConfigs) {
            # Delete the macOS configuration policy
            Write-Output "Deleting configuration policy: $($config.DisplayName) (ID: $($config.Id))"
            Remove-MgBetaDeviceManagementConfigurationPolicy -DeviceManagementConfigurationPolicyId $config.Id
        }
    }
    else {
        Write-Output "No macOS configuration policies found to delete."
    }
}

####################################################
# Function to delete all macOS scripts
function Delete-MacOSScripts() {
    # Define the API endpoint
    $scripts = Get-MgBetaDeviceManagementDeviceShellScript

    # Loop through and delete each script
    foreach ($script in $scripts) {
        Write-Output "Deleting script: $($script.displayName) ($($script.id))"
        Remove-MgBetaDeviceManagementDeviceShellScript -DeviceShellScript $script.id -Confirm:$false
    }

}

####################################################
# Function to delete all macOS custom attributes
function Delete-MacOSCustomAttributes {
    # Define the API endpoint
    $endpoint = "https://graph.microsoft.com/beta/deviceManagement/deviceCustomAttributeShellScripts"

    # Fetch all custom attribute shell scripts from the API
    $scripts = Invoke-MgGraphRequest -Method GET -Uri $endpoint

    # Check if there are any results
    # Filter for macOS-specific scripts (if applicable, update the filter based on identified properties)
    $macOSCustomAttributes = $scripts.value

    foreach ($script in $macOSCustomAttributes) {
        Write-Output "Deleting macOS custom attribute script: $($script.displayName) ($($script.id))"
        # Perform the delete operation
        Invoke-MgGraphRequest -Method DELETE -Uri "$endpoint/$($script.id)"
    }
}


####################################################
# Function to delete all macOS enrollment profiles
function Delete-EnrollmentProfiles {
    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Retrieving enrollment profiles..."

    $depOnboardingSettings = Get-MgBetaDeviceManagementDepOnboardingSetting

    if ($depOnboardingSettings) {
        foreach ($depOnboardingSetting in $depOnboardingSettings) {
            $depOnboardingSettingId = $depOnboardingSetting.Id
            $profiles = Get-MgBetaDeviceManagementDepOnboardingSettingEnrollmentProfile `
                -DepOnboardingSettingId $depOnboardingSettingId

            if ($profiles) {
                foreach ($profile in $profiles) {
                    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Deleting profile: $($profile.DisplayName) ($($profile.Id))"
                    Remove-MgBetaDeviceManagementDepOnboardingSettingEnrollmentProfile `
                        -DepOnboardingSettingId $depOnboardingSettingId `
                        -EnrollmentProfileId $profile.Id
                }
            } else {
                Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - No enrollment profiles found."
            }
        }
    } else {
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - No DEP onboarding settings found."
    }
}

####################################################
# Main function to invoke all deletion operations with user confirmation
function Invoke-IntuneERazer {

    Write-Host "WARNING: This script will permanently delete all macOS apps, configurations, scripts, custom attributes, and enrollment profiles from Intune."
    Write-Host "This action cannot be undone."
    $confirmation = Read-Host "Are you sure you want to proceed? (yes/no)"

    if ($confirmation -ne "yes") {
        Write-Host "Operation canceled."
        return
    }

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Disconnecting any existing Graph session..."
    
    try {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Clear-MgGraphEnvironment
    }
    catch {
        Write-Output "No active session to disconnect."
    }

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "DeviceManagementApps.ReadWrite.All", "DeviceManagementConfiguration.ReadWrite.All" -NoWelcome

    try {
        Delete-MacOSApps
        Delete-MacOSConfigurations
        Delete-MacOSScripts
        Delete-MacOSCustomAttributes
        Delete-MacOSConfigurationsSettingsCatalog
        Delete-EnrollmentProfiles
        Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - All macOS management objects deleted successfully."
    }
    catch {
        Write-Error "An error occurred: $_"
    }

    Write-Output "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - Disconnecting from Microsoft Graph..."
    Disconnect-MgGraph
}

####################################################
# Function to audit the FileVault configuration
function Test-FileVaultConfiguration {
    # Get all configuration policies
    $configProfiles = Get-MgBetaDeviceManagementConfigurationPolicy
    
    # Find the FileVault profile
    $fileVaultProfile = $configProfiles | Where-Object { $_.Name -eq "FileVault" }
    
    if (-not $fileVaultProfile) {
        Write-Host "No FileVault profile found." -ForegroundColor Red
        return $false
    }

    # Get the complete profile with settings using direct Graph API call
    $profileId = $fileVaultProfile.Id
    $url = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$profileId`?expand=settings"
    $fullProfile = Invoke-MgGraphRequest -Method GET -Uri $url

    $criticalSettings = @{
        "com.apple.mcx.filevault2_enable" = "com.apple.mcx.filevault2_enable_0"
        "com.apple.mcx.filevault2_defer" = "com.apple.mcx.filevault2_defer_true"
        "com.apple.mcx.filevault2_deferdontaskatuserlogout" = "com.apple.mcx.filevault2_deferdontaskatuserlogout_true"
        "com.apple.mcx.filevault2_deferforceatuserloginmaxbypassattempts" = 0
        "com.apple.mcx.filevault2_showrecoverykey" = "com.apple.mcx.filevault2_showrecoverykey_false"
        "com.apple.mcx.filevault2_forceenableinsetupassistant" = "com.apple.mcx.filevault2_forceenableinsetupassistant_true"
        "com.apple.mcx_dontallowfdedisable" = "com.apple.mcx_dontallowfdedisable_true"
    }
    
    $mismatches = @()
    $foundEscrow = $false
    $foundSettings = @{}
    
    foreach ($setting in $fullProfile.settings) {
        $groupSettings = $setting.settingInstance.groupSettingCollectionValue
        
        if ($groupSettings) {
            foreach ($group in $groupSettings) {
                if ($group.children) {
                    foreach ($child in $group.children) {
                        $settingId = $child.settingDefinitionId
                        
                        if ($settingId -eq "com.apple.mcx.filevault2_deferforceatuserloginmaxbypassattempts") {
                            $actualValue = $child.simpleSettingValue.value
                            $foundSettings[$settingId] = $actualValue
                            if ($actualValue -ne $criticalSettings[$settingId]) {
                                $mismatches += "Setting $settingId has value '$actualValue' but expected '$($criticalSettings[$settingId])'"
                            }
                            continue
                        }
                        
                        if ($criticalSettings.ContainsKey($settingId)) {
                            $expectedValue = $criticalSettings[$settingId]
                            $actualValue = $child.choiceSettingValue.value
                            $foundSettings[$settingId] = $actualValue
                            
                            if ($actualValue -ne $expectedValue) {
                                $mismatches += "Setting $settingId has value '$actualValue' but expected '$expectedValue'"
                            }
                        }
                        
                        if ($settingId -eq "com.apple.security.fderecoverykeyescrow_location") {
                            $foundEscrow = $true
                            $escrowValue = $child.simpleSettingValue.value
                            if ([string]::IsNullOrWhiteSpace($escrowValue)) {
                                $mismatches += "FileVault escrow location is empty"
                            }
                        }
                    }
                }
            }
        }
    }
    
    foreach ($setting in $criticalSettings.Keys) {
        if (-not $foundSettings.ContainsKey($setting)) {
            $mismatches += "Setting $setting is missing"
        }
    }
    
    if (-not $foundEscrow) {
        $mismatches += "FileVault escrow location section is missing"
    }
    
    if ($mismatches.Count -gt 0) {
        Write-Host "FileVault configuration mismatches found:" -ForegroundColor Yellow
        foreach ($mismatch in $mismatches) {
            Write-Host " - $mismatch" -ForegroundColor Yellow
        }
        return $false
    }
    
    return $true
}

####################################################
# Function to assign a settings catalog configuration to a group
function Assign-SettingsCatalogToGroup {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigId,
        [Parameter(Mandatory = $true)]
        [string]$GroupId
    )

    $body = @{
        assignments = @(
            @{
                target = @{
                    "@odata.type" = "#microsoft.graph.groupAssignmentTarget"
                    groupId = $GroupId
                }
            }
        )
    } | ConvertTo-Json -Depth 10

    $url = "https://graph.microsoft.com/beta/deviceManagement/configurationPolicies/$ConfigId/assign"

    try {
        Invoke-MgGraphRequest -Method POST -Uri $url -Body $body -ContentType "application/json"
    }
    catch {
        Write-Host "Failed to assign settings catalog config $ConfigId to group $GroupId. Error: $_" -ForegroundColor Red
    }
}


####################################################
# Function to determine the required depth for JSON serialization
function Get-ObjectDepth {
    param (
        [object]$Object,
        [int]$CurrentDepth = 0
    )

    if ($null -eq $Object) { return $CurrentDepth }

    # Check for dictionary / custom object
    if ($Object -is [PSCustomObject] -or $Object -is [System.Collections.IDictionary]) {
        $childDepths = foreach ($prop in $Object.PSObject.Properties) {
            Get-ObjectDepth $prop.Value ($CurrentDepth + 1)
        }
        return ($childDepths | Measure-Object -Maximum).Maximum
    }

    # Check for array / enumerable (excluding string)
    if ($Object -is [System.Collections.IEnumerable] -and -not ($Object -is [string])) {
        $childDepths = foreach ($item in $Object) {
            Get-ObjectDepth $item ($CurrentDepth + 1)
        }
        return ($childDepths | Measure-Object -Maximum).Maximum
    }

    # Base case: primitive value
    return $CurrentDepth
}