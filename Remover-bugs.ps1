#Requires -Version 5.1
# Steam 32-bit Downgrader with Christmas Theme

# Ensure temp directory exists (fix for systems where $env:TEMP points to non-existent directory)
Write-Verbose "Verificando diretório temporário..."
if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
    if ($env:LOCALAPPDATA -and (Test-Path $env:LOCALAPPDATA)) {
        $env:TEMP = Join-Path $env:LOCALAPPDATA "Temp"
    }
    if (-not $env:TEMP -or -not (Test-Path $env:TEMP)) {
        if ($PSScriptRoot) {
            $env:TEMP = Join-Path $PSScriptRoot "temp"
        } else {
            $env:TEMP = Join-Path (Get-Location).Path "temp"
        }
    }
}
if (-not (Test-Path $env:TEMP)) {
    New-Item -ItemType Directory -Path $env:TEMP -Force | Out-Null
}
Write-Verbose "Diretório temporário OK: $env:TEMP"

# Function to get Steam path from registry
function Get-SteamPath {
    $steamPath = $null

    $regPath = "HKCU:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "SteamPath" -ErrorAction SilentlyContinue).SteamPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }

    $regPath = "HKLM:\Software\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }

    $regPath = "HKLM:\Software\WOW6432Node\Valve\Steam"
    if (Test-Path $regPath) {
        $steamPath = (Get-ItemProperty -Path $regPath -Name "InstallPath" -ErrorAction SilentlyContinue).InstallPath
        if ($steamPath -and (Test-Path $steamPath)) {
            return $steamPath
        }
    }

    return $null
}

# Step 0: Get Steam path
$steamPath = Get-SteamPath
if (-not $steamPath) {
    Write-Host "Nexus Hub versão 4.2 - ERRO: Steam não encontrado."
    exit 1
}

$steamExePath = Join-Path $steamPath "Steam.exe"
if (-not (Test-Path $steamExePath)) {
    Write-Host "Nexus Hub versão 4.2 - ERRO: Steam.exe ausente."
    exit 1
}

# Step 1: Kill Steam processes
Get-Process -Name "steam*" -ErrorAction SilentlyContinue | ForEach-Object {
    try { Stop-Process -Id $_.Id -Force } catch {}
}
Start-Sleep -Seconds 2

# Remove steam.cfg if exists
$steamCfgPath = Join-Path $steamPath "steam.cfg"
if (Test-Path $steamCfgPath) {
    Remove-Item $steamCfgPath -Force -ErrorAction SilentlyContinue
}

# Step 2: Download Steam x32
$steamZipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/latest32bitsteam.zip"
$steamZipFallbackUrl = "http://files.luatools.work/OneOffFiles/latest32bitsteam.zip"
$tempSteamZip = Join-Path $env:TEMP "latest32bitsteam.zip"

try {
    Invoke-WebRequest -Uri $steamZipUrl -OutFile $tempSteamZip -UseBasicParsing
    Expand-Archive -Path $tempSteamZip -DestinationPath $steamPath -Force
} catch {
    Invoke-WebRequest -Uri $steamZipFallbackUrl -OutFile $tempSteamZip -UseBasicParsing
    Expand-Archive -Path $tempSteamZip -DestinationPath $steamPath -Force
}

# Step 3: Millennium replacement (if exists)
$millenniumDll = Join-Path $steamPath "millennium.dll"
if (Test-Path $millenniumDll) {
    $zipUrl = "https://github.com/madoiscool/lt_api_links/releases/download/unsteam/luatoolsmilleniumbuild.zip"
    $zipFallbackUrl = "http://files.luatools.work/OneOffFiles/luatoolsmilleniumbuild.zip"
    $tempZip = Join-Path $env:TEMP "luatoolsmilleniumbuild.zip"

    try {
        Invoke-WebRequest -Uri $zipUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $steamPath -Force
    } catch {
        Invoke-WebRequest -Uri $zipFallbackUrl -OutFile $tempZip -UseBasicParsing
        Expand-Archive -Path $tempZip -DestinationPath $steamPath -Force
    }
}

# Step 4: Create steam.cfg
$cfgContent = "BootStrapperInhibitAll=enable`nBootStrapperForceSelfUpdate=disable"
Set-Content -Path $steamCfgPath -Value $cfgContent -Force

# Step 5: Launch Steam
Start-Process -FilePath $steamExePath -ArgumentList "-clearbeta"

# Final output
Write-Host "Nexus Hub versão 4.2"
