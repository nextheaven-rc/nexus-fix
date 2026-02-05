#Requires -Version 5.1
# Steam 32-bit Downgrader with Christmas Theme

# Ensure temp directory exists (fix for systems where $env:TEMP points to non-existent directory)
Write-Verbose "Verificando diretÃ³rio temporÃ¡rio..."
if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
    # Fallback to user's AppData\Local\Temp
    if ($env:LOCALAPPDATA -and (Test-Path $env:LOCALAPPDATA)) {
        $env:TEMP = Join-Path $env:LOCALAPPDATA "Temp"
    }
    # If still not valid, try last resort
    if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
        # Last resort: create a temp directory in the script's location or current directory
        if ($PSScriptRoot) {
            $env:TEMP = Join-Path $PSScriptRoot "temp"
        } else {
            $env:TEMP = Join-Path (Get-Location).Path "temp"
        }
    }
}
# Ensure the temp directory exists
if (-not (Test-Path $env:TEMP)) {
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
}
Write-Verbose "DiretÃ³rio temporÃ¡rio OK: $env:TEMP"

# Function to get Steam path from registry
function Get-SteamPath {
    $steamPath = $null
    
    Write-Verbose "Procurando instalaÃ§Ã£o do Steam no registro..."
    
    # Try HKCU first (User registry)
    $regPath = "HKCU:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em HKCU."
            return $steamPath
        }
    }
    
    # Try HKLM (System registry)
    $regPath = "HKLM:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em HKLM."
            return $steamPath
        }
    }
    
    # Try 32-bit registry on 64-bit systems
    $regPath = "HKLM:\Software\WOW6432Node\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em WOW6432Node."
            return $steamPath
        }
    }
    
    Write-Verbose "Steam nÃ£o encontrado no registro."
    return $null
}

# Function to download file with inline progress bar
function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile
    )
    
    try {
        Write-Verbose "Iniciando download de $Url para $OutFile"
        # Add cache-busting to prevent PowerShell cache
        $uri = New-Object System.Uri($Url)
        $uriBuilder = New-Object System.UriBuilder($uri)
        $timestamp = (Get-Date -Format 'yyyyMMddHHmmss')
        if ($uriBuilder.Query) {
            $uriBuilder.Query = $uriBuilder.Query.TrimStart('?') + "&t=" + $timestamp
        } else {
            $uriBuilder.Query = "t=" + $timestamp
        }
        $cacheBustUrl = $uriBuilder.ToString()
        
        # First request to get content length and verify response
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = 30000 # 30 seconds timeout
        $request.ReadWriteTimeout = 30000
        
        try {
            $response = $request.GetResponse()
        } catch {
            Write-Error "ConexÃ£o falhou ao obter informaÃ§Ãµes do arquivo: $($_.Exception.Message)"
            throw "Connection timeout or failed to connect to server"
        }
        
        # Check response code
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) {
            $response.Close()
            Write-Error "CÃ³digo de resposta invÃ¡lido: $statusCode (esperado 200)"
            throw "Server returned status code $statusCode instead of 200"
        }
        
        # Check content length
        $totalLength = $response.ContentLength
        if ($totalLength -le 0) {
            $response.Close()
            Write-Error "Tamanho do conteÃºdo invÃ¡lido: $totalLength (esperado > 0)"
            throw "Server did not return valid content length"
        }
        
        $response.Close()
        Write-Verbose "Tamanho total do arquivo: $([math]::Round($totalLength / 1MB, 2)) MB"
        
        # Second request to download the file (no timeout - allow long downloads)
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = -1 # No timeout
        $request.ReadWriteTimeout = -1 # No timeout
        
        $response = $null
        try {
            $response = $request.GetResponse()
        } catch {
            Write-Error "ConexÃ£o falhou durante o download: $($_.Exception.Message)"
            throw "Connection failed during download"
        }
        
        try {
            # Ensure the output directory exists
            $outDir = Split-Path $OutFile -Parent
            if ($outDir -and -not (Test-Path $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }
            
            $responseStream = $null
            $targetStream = $null
            $responseStream = $response.GetResponseStream()
            $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $OutFile, Create
            
            $buffer = New-Object byte[] 10KB
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            $downloadedBytes = $count
            $lastUpdate = Get-Date
            $lastBytesDownloaded = $downloadedBytes
            $lastBytesUpdateTime = Get-Date
            $stuckTimeoutSeconds = 60 # 1 minute timeout for stuck downloads
            
            while ($count -gt 0) {
                $targetStream.Write($buffer, 0, $count)
                $count = $responseStream.Read($buffer, 0, $buffer.Length)
                $downloadedBytes += $count
                
                # Check if download is stuck (no progress for 1 minute)
                $now = Get-Date
                if ($downloadedBytes -gt $lastBytesDownloaded) {
                    # Bytes increased, reset stuck timer
                    $lastBytesDownloaded = $downloadedBytes
                    $lastBytesUpdateTime = $now
                } else {
                    # No bytes downloaded, check if stuck
                    $timeSinceLastBytes = ($now - $lastBytesUpdateTime).TotalSeconds
                    if ($timeSinceLastBytes -ge $stuckTimeoutSeconds) {
                        # Clean up partial file - streams will be closed in finally block
                        if (Test-Path $OutFile) {
                            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                        }
                        Write-Error "Download travado (0 kbps por $stuckTimeoutSeconds segundos). Baixado: $downloadedBytes bytes, Esperado: $totalLength bytes"
                        throw "Download stalled - no data received for $stuckTimeoutSeconds seconds"
                    }
                }
                
                # Update progress (only if -Verbose is used)
                if (($now - $lastUpdate).TotalMilliseconds -ge 100) {
                    if ($totalLength -gt 0) {
                        $percentComplete = [math]::Round(($downloadedBytes / $totalLength) * 100, 2)
                        $downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
                        $totalMB = [math]::Round($totalLength / 1MB, 2)
                        Write-Progress -Activity "Baixando arquivo" -Status "Progresso: $percentComplete% ($downloadedMB MB / $totalMB MB)" -PercentComplete $percentComplete
                    } else {
                        $downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
                        Write-Progress -Activity "Baixando arquivo" -Status "Baixado $downloadedMB MB..." -PercentComplete -1
                    }
                    $lastUpdate = $now
                }
            }
            
            Write-Progress -Activity "Baixando arquivo" -Status "Download ConcluÃ­do" -PercentComplete 100 -Completed
            Write-Verbose "Download concluÃ­do com sucesso."
            
            return $true
        } finally {
            # Always close streams, even if an error occurs
            if ($targetStream) {
                $targetStream.Close()
            }
            if ($responseStream) {
                $responseStream.Close()
            }
            if ($response) {
                $response.Close()
            }
        }
    } catch {
        Write-Error "Erro no Download-FileWithProgress: $($_.Exception.Message)"
        throw $_
    }
}

# Function to download and extract with fallback URL support
function Download-AndExtractWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$FallbackUrl,
        [string]$TempZipPath,
        [string]$DestinationPath,
        [string]$Description
    )
    
    $urls = @($PrimaryUrl, $FallbackUrl)
    $lastError = $null
    
    foreach ($url in $urls) {
        $isFallback = ($url -eq $FallbackUrl)
        
        try {
            Write-Verbose "Iniciando processo para: $Description"
            # Clean up any existing temp file
            if (Test-Path $TempZipPath) {
                Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            }
            
            if ($isFallback) {
                Write-Verbose "Tentativa primÃ¡ria falhou, usando URL de fallback..."
            }
            
            Download-FileWithProgress -Url $url -OutFile $TempZipPath
            Write-Verbose "Download de $Description concluÃ­do."
            
            # Try to extract - this will validate the ZIP
            Write-Verbose "Extraindo $Description para: $DestinationPath"
            Expand-ArchiveWithProgress -ZipPath $TempZipPath -DestinationPath $DestinationPath
            Write-Verbose "ExtraÃ§Ã£o de $Description concluÃ­da."
            
            # Clean up temp file
            Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            
            return $true
        } catch {
            $lastError = $_
            $errorMessage = $_.ToString()
            if ($_.Exception -and $_.Exception.Message) {
                $errorMessage = $_.Exception.Message
            }
            
            if ($isFallback) {
                Write-Error "Download e extraÃ§Ã£o falharam para ambas as URLs. Ãšltimo erro: $($lastError.Exception.Message)"
                throw "Both primary and fallback downloads failed."
            } else {
                if ($errorMessage -match "Invalid ZIP|corrupted|End of Central Directory|PK signature|ZIP file|Connection.*failed|timeout|stalled|stuck|failed to connect") {
                    Write-Verbose "Download falhou (possÃ­vel bloqueio ou problema de conexÃ£o), tentando fallback..."
                    continue
                } else {
                    throw $_
                }
            }
        }
    }
    
    if ($lastError) {
        throw $lastError
    } else {
        throw "Download failed for unknown reason"
    }
}

# Function to extract archive with inline progress bar
function Expand-ArchiveWithProgress {
    param(
        [string]$ZipPath,
        [string]$DestinationPath
    )
    
    try {
        Write-Verbose "Verificando arquivo ZIP: $ZipPath"
        # Validate ZIP file exists and has content
        if (-not (Test-Path $ZipPath)) {
            Write-Error "Arquivo ZIP nÃ£o encontrado: $ZipPath"
            throw "ZIP file does not exist"
        }
        
        $zipFileInfo = Get-Item $ZipPath -ErrorAction Stop
        if ($zipFileInfo.Length -eq 0) {
            Write-Error "Arquivo ZIP estÃ¡ vazio (0 bytes)"
            throw "ZIP file is empty"
        }
        
        # Check if file starts with ZIP signature (PK header)
        $zipStream = $null
        try {
            $zipStream = [System.IO.File]::OpenRead($ZipPath)
            $header = New-Object byte[] 4
            $bytesRead = $zipStream.Read($header, 0, 4)
            
            if ($bytesRead -lt 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
                Write-Error "Arquivo nÃ£o parece ser um ZIP vÃ¡lido (assinatura PK ausente). Tamanho: $($zipFileInfo.Length) bytes"
                throw "Invalid ZIP file format"
            }
        } finally {
            if ($zipStream) {
                $zipStream.Close()
            }
        }
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        # Try to open the ZIP file - this will fail if corrupted
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        } catch {
            Write-Error "Arquivo ZIP corrompido ou incompleto. Erro: $($_.Exception.Message)"
            throw "ZIP file is corrupted - download may have been interrupted. Please try again."
        }
        
        try {
            $entries = $zip.Entries
            
            # Count only files (exclude directories)
            $fileEntries = @()
            foreach ($entry in $entries) {
                if (-not ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/'))) {
                    $fileEntries += $entry
                }
            }
            $totalFiles = $fileEntries.Count
            if ($totalFiles -eq 0) {
                Write-Verbose "Arquivo ZIP nÃ£o contÃ©m arquivos (apenas diretÃ³rios)."
                return $true
            }
            $extractedCount = 0
            $lastUpdate = Get-Date
            
            foreach ($entry in $entries) {
                $entryPath = Join-Path $DestinationPath $entry.FullName
                
                # Create directory if it doesn't exist
                $entryDir = Split-Path $entryPath -Parent
                if ($entryDir -and -not (Test-Path $entryDir)) {
                    New-Item -ItemType Directory -Path $entryDir -Force | Out-Null
                }
                
                # Skip if entry is a directory
                if ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/')) {
                    continue
                }
                
                # Extract the file
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
                $extractedCount++
                
                # Update progress (only if -Verbose is used)
                $now = Get-Date
                if (($now - $lastUpdate).TotalMilliseconds -ge 50) {
                    $percentComplete = [math]::Round(($extractedCount / $totalFiles) * 100, 2)
                    Write-Progress -Activity "Extraindo arquivos" -Status "Progresso: $percentComplete% ($extractedCount / $totalFiles arquivos)" -PercentComplete $percentComplete
                    $lastUpdate = $now
                }
            }
            
            Write-Progress -Activity "Extraindo arquivos" -Status "ExtraÃ§Ã£o ConcluÃ­da" -PercentComplete 100 -Completed
            Write-Verbose "ExtraÃ§Ã£o concluÃ­da com sucesso."
            
            return $true
        } finally {
            # Always dispose the ZIP file, even if an error occurs
            if ($zip) {
                $zip.Dispose()
            }
        }
    } catch {
        Write-Error "Erro no Expand-ArchiveWithProgress: $($_.Exception.Message)"
        throw $_
    }
}

# Step 0: Get Steam path from registry
Write-Verbose "Iniciando: Localizando Steam..."
$steamPath = Get-SteamPath
$steamExePath = $null

if (-not $steamPath) {
    Write-Error "InstalaÃ§Ã£o do Steam nÃ£o encontrada no registro."
    Write-Host "KRAYz STORE - ERRO: Steam nÃ£o encontrado."
    exit 1
}

$steamExePath = Join-Path $steamPath "Steam.exe"

if (-not (Test-Path $steamExePath)) {
    Write-Error "Steam.exe nÃ£o encontrado em: $steamExePath"
    Write-Host "KRAYz STORE - ERRO: Steam.exe ausente."
    exit 1
}

Write-Verbose "Steam encontrado em: $steamPath"

# Step 1: Kill all Steam processes
Write-Verbose "Iniciando: Encerrando processos do Steam..."
$steamProcesses = Get-Process -Name "steam*" -ErrorAction SilentlyContinue
if ($steamProcesses) {
    foreach ($proc in $steamProcesses) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Verbose "Processo encerrado: $($proc.Name) (PID: $($proc.Id))"
        } catch {
            Write-Verbose "NÃ£o foi possÃ­vel encerrar o processo: $($proc.Name)"
        }
    }
    Start-Sleep -Seconds 2
    Write-Verbose "Todos os processos do Steam encerrados."
} else {
    Write-Verbose "Nenhum processo do Steam encontrado."
}

# Delete steam.cfg if present
$steamCfgPath = Join-Path $steamPath "steam.cfg"
if (Test-Path $steamCfgPath) {
    try {
        Remove-Item -Path $steamCfgPath -Force -ErrorAction Stop
        Write-Verbose "steam.cfg existente removido."
    } catch {
        Write-Verbose "NÃ£o foi possÃ­vel remover steam.cfg: $($_.Exception.Message)"
    }
}

# Step 2: Download and extract Steam x32 Latest Build
Write-Verbose "Iniciando: Baixando e extraindo Steam x32 Latest Build..."
$steamZipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/latest32bitsteam.zip"
$steamZipFallbackUrl = "http://files.luatools.work/OneOffFiles/latest32bitsteam.zip"
$tempSteamZip = Join-Path $env:TEMP "latest32bitsteam.zip"

try {
    Download-AndExtractWithFallback -PrimaryUrl $steamZipUrl -FallbackUrl $steamZipFallbackUrl -TempZipPath $tempSteamZip -DestinationPath $steamPath -Description "Steam x32 Latest Build"
} catch {
    Write-Error "Falha ao baixar ou extrair Steam x32 Latest Build: $($_.Exception.Message)"
    Write-Verbose "Continuando o processo..."
}

# Step 3: Download and extract zip file (only if millennium.dll is present - to replace it)
Write-Verbose "Iniciando: Verificando Millennium build..."
$millenniumDll = Join-Path $steamPath "millennium.dll"

if (Test-Path $millenniumDll) {
    Write-Verbose "millennium.dll encontrado, baixando e extraindo para substituiÃ§Ã£o..."
    $zipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/luatoolsmilleniumbuild.zip"
    $zipFallbackUrl = "http://files.luatools.work/OneOffFiles/luatoolsmilleniumbuild.zip"
    $tempZip = Join-Path $env:TEMP "luatoolsmilleniumbuild.zip"

    try {
        Download-AndExtractWithFallback -PrimaryUrl $zipUrl -FallbackUrl $zipFallbackUrl -TempZipPath $tempZip -DestinationPath $steamPath -Description "Millennium build"
    } catch {
        Write-Error "Falha ao baixar ou extrair Millennium build: $($_.Exception.Message)"
        Write-Verbose "Continuando o processo..."
    }
} else {
    Write-Verbose "millennium.dll nÃ£o encontrado, pulando download e extraÃ§Ã£o."
}

# Step 4: Create steam.cfg file
Write-Verbose "Iniciando: Criando steam.cfg..."
$steamCfgPath = Join-Path $steamPath "steam.cfg"

# Create config file using echo commands as specified
$cfgContent = "BootStrapperInhibitAll=enable`nBootStrapperForceSelfUpdate=disable"
Set-Content -Path $steamCfgPath -Value $cfgContent -Force
Write-Verbose "steam.cfg criado com sucesso."

# Step 5: Launch Steam
Write-Verbose "Iniciando: LanÃ§ando Steam..."
$arguments = @("-clearbeta")

try {
    $process = Start-Process -FilePath $steamExePath -ArgumentList $arguments -PassThru -WindowStyle Normal
    Write-Verbose "Steam lanÃ§ado com sucesso. PID: $($process.Id)"
} catch {
    Write-Error "Falha ao iniciar o Steam: $($_.Exception.Message)"
}

# Final output
Write-Host "#Requires -Version 5.1
# Steam 32-bit Downgrader with Christmas Theme

# Ensure temp directory exists (fix for systems where $env:TEMP points to non-existent directory)
Write-Verbose "Verificando diretÃ³rio temporÃ¡rio..."
if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
    # Fallback to user's AppData\Local\Temp
    if ($env:LOCALAPPDATA -and (Test-Path $env:LOCALAPPDATA)) {
        $env:TEMP = Join-Path $env:LOCALAPPDATA "Temp"
    }
    # If still not valid, try last resort
    if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
        # Last resort: create a temp directory in the script's location or current directory
        if ($PSScriptRoot) {
            $env:TEMP = Join-Path $PSScriptRoot "temp"
        } else {
            $env:TEMP = Join-Path (Get-Location).Path "temp"
        }
    }
}
# Ensure the temp directory exists
if (-not (Test-Path $env:TEMP)) {
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
}
Write-Verbose "DiretÃ³rio temporÃ¡rio OK: $env:TEMP"

# Function to get Steam path from registry
function Get-SteamPath {
    $steamPath = $null
    
    Write-Verbose "Procurando instalaÃ§Ã£o do Steam no registro..."
    
    # Try HKCU first (User registry)
    $regPath = "HKCU:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em HKCU."
            return $steamPath
        }
    }
    
    # Try HKLM (System registry)
    $regPath = "HKLM:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em HKLM."
            return $steamPath
        }
    }
    
    # Try 32-bit registry on 64-bit systems
    $regPath = "HKLM:\Software\WOW6432Node\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            Write-Verbose "Steam encontrado em WOW6432Node."
            return $steamPath
        }
    }
    
    Write-Verbose "Steam nÃ£o encontrado no registro."
    return $null
}

# Function to download file with inline progress bar
function Download-FileWithProgress {
    param(
        [string]$Url,
        [string]$OutFile
    )
    
    try {
        Write-Verbose "Iniciando download de $Url para $OutFile"
        # Add cache-busting to prevent PowerShell cache
        $uri = New-Object System.Uri($Url)
        $uriBuilder = New-Object System.UriBuilder($uri)
        $timestamp = (Get-Date -Format 'yyyyMMddHHmmss')
        if ($uriBuilder.Query) {
            $uriBuilder.Query = $uriBuilder.Query.TrimStart('?') + "&t=" + $timestamp
        } else {
            $uriBuilder.Query = "t=" + $timestamp
        }
        $cacheBustUrl = $uriBuilder.ToString()
        
        # First request to get content length and verify response
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = 30000 # 30 seconds timeout
        $request.ReadWriteTimeout = 30000
        
        try {
            $response = $request.GetResponse()
        } catch {
            Write-Error "ConexÃ£o falhou ao obter informaÃ§Ãµes do arquivo: $($_.Exception.Message)"
            throw "Connection timeout or failed to connect to server"
        }
        
        # Check response code
        $statusCode = [int]$response.StatusCode
        if ($statusCode -ne 200) {
            $response.Close()
            Write-Error "CÃ³digo de resposta invÃ¡lido: $statusCode (esperado 200)"
            throw "Server returned status code $statusCode instead of 200"
        }
        
        # Check content length
        $totalLength = $response.ContentLength
        if ($totalLength -le 0) {
            $response.Close()
            Write-Error "Tamanho do conteÃºdo invÃ¡lido: $totalLength (esperado > 0)"
            throw "Server did not return valid content length"
        }
        
        $response.Close()
        Write-Verbose "Tamanho total do arquivo: $([math]::Round($totalLength / 1MB, 2)) MB"
        
        # Second request to download the file (no timeout - allow long downloads)
        $request = [System.Net.HttpWebRequest]::Create($cacheBustUrl)
        $request.CachePolicy = New-Object System.Net.Cache.RequestCachePolicy([System.Net.Cache.RequestCacheLevel]::NoCacheNoStore)
        $request.Headers.Add("Cache-Control", "no-cache, no-store, must-revalidate")
        $request.Headers.Add("Pragma", "no-cache")
        $request.Timeout = -1 # No timeout
        $request.ReadWriteTimeout = -1 # No timeout
        
        $response = $null
        try {
            $response = $request.GetResponse()
        } catch {
            Write-Error "ConexÃ£o falhou durante o download: $($_.Exception.Message)"
            throw "Connection failed during download"
        }
        
        try {
            # Ensure the output directory exists
            $outDir = Split-Path $OutFile -Parent
            if ($outDir -and -not (Test-Path $outDir)) {
                New-Item -ItemType Directory -Path $outDir -Force | Out-Null
            }
            
            $responseStream = $null
            $targetStream = $null
            $responseStream = $response.GetResponseStream()
            $targetStream = New-Object -TypeName System.IO.FileStream -ArgumentList $OutFile, Create
            
            $buffer = New-Object byte[] 10KB
            $count = $responseStream.Read($buffer, 0, $buffer.Length)
            $downloadedBytes = $count
            $lastUpdate = Get-Date
            $lastBytesDownloaded = $downloadedBytes
            $lastBytesUpdateTime = Get-Date
            $stuckTimeoutSeconds = 60 # 1 minute timeout for stuck downloads
            
            while ($count -gt 0) {
                $targetStream.Write($buffer, 0, $count)
                $count = $responseStream.Read($buffer, 0, $buffer.Length)
                $downloadedBytes += $count
                
                # Check if download is stuck (no progress for 1 minute)
                $now = Get-Date
                if ($downloadedBytes -gt $lastBytesDownloaded) {
                    # Bytes increased, reset stuck timer
                    $lastBytesDownloaded = $downloadedBytes
                    $lastBytesUpdateTime = $now
                } else {
                    # No bytes downloaded, check if stuck
                    $timeSinceLastBytes = ($now - $lastBytesUpdateTime).TotalSeconds
                    if ($timeSinceLastBytes -ge $stuckTimeoutSeconds) {
                        # Clean up partial file - streams will be closed in finally block
                        if (Test-Path $OutFile) {
                            Remove-Item $OutFile -Force -ErrorAction SilentlyContinue
                        }
                        Write-Error "Download travado (0 kbps por $stuckTimeoutSeconds segundos). Baixado: $downloadedBytes bytes, Esperado: $totalLength bytes"
                        throw "Download stalled - no data received for $stuckTimeoutSeconds seconds"
                    }
                }
                
                # Update progress (only if -Verbose is used)
                if (($now - $lastUpdate).TotalMilliseconds -ge 100) {
                    if ($totalLength -gt 0) {
                        $percentComplete = [math]::Round(($downloadedBytes / $totalLength) * 100, 2)
                        $downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
                        $totalMB = [math]::Round($totalLength / 1MB, 2)
                        Write-Progress -Activity "Baixando arquivo" -Status "Progresso: $percentComplete% ($downloadedMB MB / $totalMB MB)" -PercentComplete $percentComplete
                    } else {
                        $downloadedMB = [math]::Round($downloadedBytes / 1MB, 2)
                        Write-Progress -Activity "Baixando arquivo" -Status "Baixado $downloadedMB MB..." -PercentComplete -1
                    }
                    $lastUpdate = $now
                }
            }
            
            Write-Progress -Activity "Baixando arquivo" -Status "Download ConcluÃ­do" -PercentComplete 100 -Completed
            Write-Verbose "Download concluÃ­do com sucesso."
            
            return $true
        } finally {
            # Always close streams, even if an error occurs
            if ($targetStream) {
                $targetStream.Close()
            }
            if ($responseStream) {
                $responseStream.Close()
            }
            if ($response) {
                $response.Close()
            }
        }
    } catch {
        Write-Error "Erro no Download-FileWithProgress: $($_.Exception.Message)"
        throw $_
    }
}

# Function to download and extract with fallback URL support
function Download-AndExtractWithFallback {
    param(
        [string]$PrimaryUrl,
        [string]$FallbackUrl,
        [string]$TempZipPath,
        [string]$DestinationPath,
        [string]$Description
    )
    
    $urls = @($PrimaryUrl, $FallbackUrl)
    $lastError = $null
    
    foreach ($url in $urls) {
        $isFallback = ($url -eq $FallbackUrl)
        
        try {
            Write-Verbose "Iniciando processo para: $Description"
            # Clean up any existing temp file
            if (Test-Path $TempZipPath) {
                Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            }
            
            if ($isFallback) {
                Write-Verbose "Tentativa primÃ¡ria falhou, usando URL de fallback..."
            }
            
            Download-FileWithProgress -Url $url -OutFile $TempZipPath
            Write-Verbose "Download de $Description concluÃ­do."
            
            # Try to extract - this will validate the ZIP
            Write-Verbose "Extraindo $Description para: $DestinationPath"
            Expand-ArchiveWithProgress -ZipPath $TempZipPath -DestinationPath $DestinationPath
            Write-Verbose "ExtraÃ§Ã£o de $Description concluÃ­da."
            
            # Clean up temp file
            Remove-Item -Path $TempZipPath -Force -ErrorAction SilentlyContinue
            
            return $true
        } catch {
            $lastError = $_
            $errorMessage = $_.ToString()
            if ($_.Exception -and $_.Exception.Message) {
                $errorMessage = $_.Exception.Message
            }
            
            if ($isFallback) {
                Write-Error "Download e extraÃ§Ã£o falharam para ambas as URLs. Ãšltimo erro: $($lastError.Exception.Message)"
                throw "Both primary and fallback downloads failed."
            } else {
                if ($errorMessage -match "Invalid ZIP|corrupted|End of Central Directory|PK signature|ZIP file|Connection.*failed|timeout|stalled|stuck|failed to connect") {
                    Write-Verbose "Download falhou (possÃ­vel bloqueio ou problema de conexÃ£o), tentando fallback..."
                    continue
                } else {
                    throw $_
                }
            }
        }
    }
    
    if ($lastError) {
        throw $lastError
    } else {
        throw "Download failed for unknown reason"
    }
}

# Function to extract archive with inline progress bar
function Expand-ArchiveWithProgress {
    param(
        [string]$ZipPath,
        [string]$DestinationPath
    )
    
    try {
        Write-Verbose "Verificando arquivo ZIP: $ZipPath"
        # Validate ZIP file exists and has content
        if (-not (Test-Path $ZipPath)) {
            Write-Error "Arquivo ZIP nÃ£o encontrado: $ZipPath"
            throw "ZIP file does not exist"
        }
        
        $zipFileInfo = Get-Item $ZipPath -ErrorAction Stop
        if ($zipFileInfo.Length -eq 0) {
            Write-Error "Arquivo ZIP estÃ¡ vazio (0 bytes)"
            throw "ZIP file is empty"
        }
        
        # Check if file starts with ZIP signature (PK header)
        $zipStream = $null
        try {
            $zipStream = [System.IO.File]::OpenRead($ZipPath)
            $header = New-Object byte[] 4
            $bytesRead = $zipStream.Read($header, 0, 4)
            
            if ($bytesRead -lt 4 -or $header[0] -ne 0x50 -or $header[1] -ne 0x4B) {
                Write-Error "Arquivo nÃ£o parece ser um ZIP vÃ¡lido (assinatura PK ausente). Tamanho: $($zipFileInfo.Length) bytes"
                throw "Invalid ZIP file format"
            }
        } finally {
            if ($zipStream) {
                $zipStream.Close()
            }
        }
        
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        # Try to open the ZIP file - this will fail if corrupted
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
        } catch {
            Write-Error "Arquivo ZIP corrompido ou incompleto. Erro: $($_.Exception.Message)"
            throw "ZIP file is corrupted - download may have been interrupted. Please try again."
        }
        
        try {
            $entries = $zip.Entries
            
            # Count only files (exclude directories)
            $fileEntries = @()
            foreach ($entry in $entries) {
                if (-not ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/'))) {
                    $fileEntries += $entry
                }
            }
            $totalFiles = $fileEntries.Count
            if ($totalFiles -eq 0) {
                Write-Verbose "Arquivo ZIP nÃ£o contÃ©m arquivos (apenas diretÃ³rios)."
                return $true
            }
            $extractedCount = 0
            $lastUpdate = Get-Date
            
            foreach ($entry in $entries) {
                $entryPath = Join-Path $DestinationPath $entry.FullName
                
                # Create directory if it doesn't exist
                $entryDir = Split-Path $entryPath -Parent
                if ($entryDir -and -not (Test-Path $entryDir)) {
                    New-Item -ItemType Directory -Path $entryDir -Force | Out-Null
                }
                
                # Skip if entry is a directory
                if ($entry.FullName.EndsWith('\') -or $entry.FullName.EndsWith('/')) {
                    continue
                }
                
                # Extract the file
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $entryPath, $true)
                $extractedCount++
                
                # Update progress (only if -Verbose is used)
                $now = Get-Date
                if (($now - $lastUpdate).TotalMilliseconds -ge 50) {
                    $percentComplete = [math]::Round(($extractedCount / $totalFiles) * 100, 2)
                    Write-Progress -Activity "Extraindo arquivos" -Status "Progresso: $percentComplete% ($extractedCount / $totalFiles arquivos)" -PercentComplete $percentComplete
                    $lastUpdate = $now
                }
            }
            
            Write-Progress -Activity "Extraindo arquivos" -Status "ExtraÃ§Ã£o ConcluÃ­da" -PercentComplete 100 -Completed
            Write-Verbose "ExtraÃ§Ã£o concluÃ­da com sucesso."
            
            return $true
        } finally {
            # Always dispose the ZIP file, even if an error occurs
            if ($zip) {
                $zip.Dispose()
            }
        }
    } catch {
        Write-Error "Erro no Expand-ArchiveWithProgress: $($_.Exception.Message)"
        throw $_
    }
}

# Step 0: Get Steam path from registry
Write-Verbose "Iniciando: Localizando Steam..."
$steamPath = Get-SteamPath
$steamExePath = $null

if (-not $steamPath) {
    Write-Error "InstalaÃ§Ã£o do Steam nÃ£o encontrada no registro."
    Write-Host "KRAYz STORE - ERRO: Steam nÃ£o encontrado."
    exit 1
}

$steamExePath = Join-Path $steamPath "Steam.exe"

if (-not (Test-Path $steamExePath)) {
    Write-Error "Steam.exe nÃ£o encontrado em: $steamExePath"
    Write-Host "KRAYz STORE - ERRO: Steam.exe ausente."
    exit 1
}

Write-Verbose "Steam encontrado em: $steamPath"

# Step 1: Kill all Steam processes
Write-Verbose "Iniciando: Encerrando processos do Steam..."
$steamProcesses = Get-Process -Name "steam*" -ErrorAction SilentlyContinue
if ($steamProcesses) {
    foreach ($proc in $steamProcesses) {
        try {
            Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            Write-Verbose "Processo encerrado: $($proc.Name) (PID: $($proc.Id))"
        } catch {
            Write-Verbose "NÃ£o foi possÃ­vel encerrar o processo: $($proc.Name)"
        }
    }
    Start-Sleep -Seconds 2
    Write-Verbose "Todos os processos do Steam encerrados."
} else {
    Write-Verbose "Nenhum processo do Steam encontrado."
}

# Delete steam.cfg if present
$steamCfgPath = Join-Path $steamPath "steam.cfg"
if (Test-Path $steamCfgPath) {
    try {
        Remove-Item -Path $steamCfgPath -Force -ErrorAction Stop
        Write-Verbose "steam.cfg existente removido."
    } catch {
        Write-Verbose "NÃ£o foi possÃ­vel remover steam.cfg: $($_.Exception.Message)"
    }
}

# Step 2: Download and extract Steam x32 Latest Build
Write-Verbose "Iniciando: Baixando e extraindo Steam x32 Latest Build..."
$steamZipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/latest32bitsteam.zip"
$steamZipFallbackUrl = "http://files.luatools.work/OneOffFiles/latest32bitsteam.zip"
$tempSteamZip = Join-Path $env:TEMP "latest32bitsteam.zip"

try {
    Download-AndExtractWithFallback -PrimaryUrl $steamZipUrl -FallbackUrl $steamZipFallbackUrl -TempZipPath $tempSteamZip -DestinationPath $steamPath -Description "Steam x32 Latest Build"
} catch {
    Write-Error "Falha ao baixar ou extrair Steam x32 Latest Build: $($_.Exception.Message)"
    Write-Verbose "Continuando o processo..."
}

# Step 3: Download and extract zip file (only if millennium.dll is present - to replace it)
Write-Verbose "Iniciando: Verificando Millennium build..."
$millenniumDll = Join-Path $steamPath "millennium.dll"

if (Test-Path $millenniumDll) {
    Write-Verbose "millennium.dll encontrado, baixando e extraindo para substituiÃ§Ã£o..."
    $zipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/luatoolsmilleniumbuild.zip"
    $zipFallbackUrl = "http://files.luatools.work/OneOffFiles/luatoolsmilleniumbuild.zip"
    $tempZip = Join-Path $env:TEMP "luatoolsmilleniumbuild.zip"

    try {
        Download-AndExtractWithFallback -PrimaryUrl $zipUrl -FallbackUrl $zipFallbackUrl -TempZipPath $tempZip -DestinationPath $steamPath -Description "Millennium build"
    } catch {
        Write-Error "Falha ao baixar ou extrair Millennium build: $($_.Exception.Message)"
        Write-Verbose "Continuando o processo..."
    }
} else {
    Write-Verbose "millennium.dll nÃ£o encontrado, pulando download e extraÃ§Ã£o."
}

# Step 4: Create steam.cfg file
Write-Verbose "Iniciando: Criando steam.cfg..."
$steamCfgPath = Join-Path $steamPath "steam.cfg"

# Create config file using echo commands as specified
$cfgContent = "BootStrapperInhibitAll=enable`nBootStrapperForceSelfUpdate=disable"
Set-Content -Path $steamCfgPath -Value $cfgContent -Force
Write-Verbose "steam.cfg criado com sucesso."

# Step 5: Launch Steam
Write-Verbose "Iniciando: LanÃ§ando Steam..."
$arguments = @("-clearbeta")

try {
    $process = Start-Process -FilePath $steamExePath -ArgumentList $arguments -PassThru -WindowStyle Normal
    Write-Verbose "Steam lanÃ§ado com sucesso. PID: $($process.Id)"
} catch {
    Write-Error "Falha ao iniciar o Steam: $($_.Exception.Message)"
}

# Final output
Write-Host "Nexus Hub v 4.2"
