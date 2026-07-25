<#
.SYNOPSIS
  All-in-one Windows manager for a Palworld 1.0 dedicated server.

.DESCRIPTION
  Installs SteamCMD, installs/updates Palworld Dedicated Server, edits
  PalWorldSettings.ini safely, starts/stops the server, creates backups,
  restores saves, manages Windows Firewall rules, calls the Palworld REST API,
  and creates optional scheduled backup tasks.

  Run from PowerShell:
    .\PalworldServerManager.ps1 help
    .\PalworldServerManager.ps1 install -ServerName "Neo Palworld" -PublicLobby
    .\PalworldServerManager.ps1 start
    .\PalworldServerManager.ps1 backup

  Notes:
    - Public players need router port forwarding for UDP 8211 by default.
    - The REST API is for local/LAN management. Do not expose it to the Internet.
    - RCON is deprecated by Pocketpair and is disabled by default here.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet(
        'help',
        'doctor',
        'install',
        'update',
        'start',
        'stop',
        'restart',
        'status',
        'backup',
        'restore',
        'list-backups',
        'settings',
        'set',
        'preset',
        'firewall',
        'ports',
        'api',
        'info',
        'players',
        'metrics',
        'announce',
        'save',
        'shutdown',
        'mods',
        'schedule-backup',
        'unschedule-backup',
        'logs',
        'tail'
    )]
    [string]$Action = 'help',

    [string]$Root = '',

    [string]$ServerName,
    [string]$ServerDescription,
    [string]$AdminPassword,
    [string]$ServerPassword,

    [int]$Port = 8211,
    [int]$Players = 32,
    [switch]$PublicLobby,
    [string]$PublicIP,
    [int]$PublicPort = 0,

    [switch]$EnableRestApi,
    [int]$RestPort = 8212,
    [string]$ApiHost = '127.0.0.1',
    [string]$ApiUser = 'admin',

    [switch]$EnableRcon,
    [int]$RconPort = 25575,

    [string[]]$Set,
    [string]$Key,
    [string]$Value,
    [string]$PresetName = 'launch-public',

    [string]$BackupName,
    [int]$Keep = 30,
    [int]$ShutdownWait = 30,
    [string]$Message = 'Server maintenance',
    [switch]$NoBackup,
    [switch]$Force,
    [switch]$NoValidate,

    [switch]$UsePerfArgs,
    [int]$WorkerThreads = 0,
    [string]$LogFormat = 'Json',

    [string]$RestoreFile,
    [string]$ApiEndpoint = 'info',
    [ValidateSet('GET', 'POST')]
    [string]$ApiMethod = 'GET',
    [string]$JsonBody,

    [string[]]$ModPackage,
    [string]$WorkshopRootDir,
    [switch]$DisableMods,

    [switch]$OpenRestApiFirewall,
    [switch]$OpenRconFirewall,
    [int]$BackupEveryMinutes = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Root)) {
    $scriptBase = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptBase)) {
        $scriptBase = (Get-Location).Path
    }
    $Root = Join-Path $scriptBase 'PalworldServer'
}

$Script:SteamAppId = '2394010'
$Script:SteamCmdZipUrl = 'https://steamcdn-a.akamaihd.net/client/installer/steamcmd.zip'
$Script:TaskNameBackup = 'PalworldServerManager Backup'

function Write-Info {
    param([string]$Text)
    Write-Host "[INFO] $Text" -ForegroundColor Cyan
}

function Write-Warn {
    param([string]$Text)
    Write-Host "[WARN] $Text" -ForegroundColor Yellow
}

function Write-Good {
    param([string]$Text)
    Write-Host "[ OK ] $Text" -ForegroundColor Green
}

function Write-Bad {
    param([string]$Text)
    Write-Host "[FAIL] $Text" -ForegroundColor Red
}

function Get-Layout {
    $resolvedRoot = [System.IO.Path]::GetFullPath($Root)
    [ordered]@{
        Root              = $resolvedRoot
        SteamCmdDir       = Join-Path $resolvedRoot 'SteamCMD'
        SteamCmdExe       = Join-Path $resolvedRoot 'SteamCMD\steamcmd.exe'
        ServerDir         = Join-Path $resolvedRoot 'PalServer'
        ServerExe         = Join-Path $resolvedRoot 'PalServer\PalServer.exe'
        DefaultSettings   = Join-Path $resolvedRoot 'PalServer\DefaultPalWorldSettings.ini'
        SettingsFile      = Join-Path $resolvedRoot 'PalServer\Pal\Saved\Config\WindowsServer\PalWorldSettings.ini'
        SavedDir          = Join-Path $resolvedRoot 'PalServer\Pal\Saved'
        LogsDir           = Join-Path $resolvedRoot 'PalServer\Pal\Saved\Logs'
        BackupsDir        = Join-Path $resolvedRoot 'Backups'
        ManagerLogsDir    = Join-Path $resolvedRoot 'ManagerLogs'
        StateFile         = Join-Path $resolvedRoot 'manager-state.json'
        ModsFile          = Join-Path $resolvedRoot 'PalServer\Mods\PalModSettings.ini'
    }
}

function Ensure-Directory {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path | Out-Null
    }
}

function Get-State {
    $layout = Get-Layout
    if (Test-Path -LiteralPath $layout.StateFile) {
        $json = Get-Content -LiteralPath $layout.StateFile -Raw
        if ($json.Trim().Length -gt 0) {
            $obj = $json | ConvertFrom-Json
            $hash = @{}
            foreach ($prop in $obj.PSObject.Properties) {
                $hash[$prop.Name] = $prop.Value
            }
            return $hash
        }
    }
    return @{}
}

function Save-State {
    param([hashtable]$State)
    $layout = Get-Layout
    Ensure-Directory $layout.Root
    $State['LastTouchedUtc'] = (Get-Date).ToUniversalTime().ToString('o')
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $layout.StateFile -Encoding UTF8
}

function Set-StateValue {
    param(
        [hashtable]$State,
        [string]$Name,
        [object]$NewValue,
        [bool]$OnlyWhenBound = $true
    )
    if ((-not $OnlyWhenBound) -or $PSBoundParameters.ContainsKey($Name)) {
        $State[$Name] = $NewValue
    }
}

function New-Password {
    param([int]$Length = 28)
    $chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@#$%+-_=.'
    $bytes = [byte[]]::new($Length)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    } finally {
        $rng.Dispose()
    }
    $out = New-Object System.Text.StringBuilder
    foreach ($b in $bytes) {
        [void]$out.Append($chars[$b % $chars.Length])
    }
    $out.ToString()
}

function Show-Help {
    $layout = Get-Layout
    @"
PalworldServerManager.ps1 - all-in-one Palworld dedicated server manager

Default server root:
  $($layout.Root)

First-time setup:
  .\PalworldServerManager.ps1 install -ServerName "Neo Palworld" -PublicLobby
  .\PalworldServerManager.ps1 firewall
  .\PalworldServerManager.ps1 start

Daily use:
  .\PalworldServerManager.ps1 status
  .\PalworldServerManager.ps1 backup
  .\PalworldServerManager.ps1 update
  .\PalworldServerManager.ps1 restart

Settings:
  .\PalworldServerManager.ps1 settings
  .\PalworldServerManager.ps1 set -Set "ServerName=Neo Palworld","ExpRate=1.5","PalCaptureRate=1.2"
  .\PalworldServerManager.ps1 preset -PresetName casual

Useful presets:
  launch-public   Safe public baseline: REST local, built-in backups, player list, JSON logs.
  balanced        Vanilla-ish public/community tuning.
  casual          Faster leveling/capture/gathering and softer death penalty.
  performance     Reduces high-load settings for weaker hardware.
  pvp             Enables PvP-oriented flags.
  hardcore        Enables hardcore/Pals-lost style risk.

Backups and restore:
  .\PalworldServerManager.ps1 list-backups
  .\PalworldServerManager.ps1 restore -RestoreFile ".\PalworldServer\Backups\palworld-save-....zip"
  .\PalworldServerManager.ps1 schedule-backup -BackupEveryMinutes 60

REST API helpers, local only:
  .\PalworldServerManager.ps1 info
  .\PalworldServerManager.ps1 players
  .\PalworldServerManager.ps1 metrics
  .\PalworldServerManager.ps1 announce -Message "Restart in 5 minutes"
  .\PalworldServerManager.ps1 shutdown -ShutdownWait 60 -Message "Restarting for update"

Mods:
  .\PalworldServerManager.ps1 mods -ModPackage "PackageOne","PackageTwo"
  .\PalworldServerManager.ps1 mods -WorkshopRootDir "C:\Program Files (x86)\Steam\steamapps\workshop\content\1623730"
  .\PalworldServerManager.ps1 mods -DisableMods

Router note:
  Forward UDP $Port from your router to this PC. The script can add Windows Firewall
  rules, but it cannot configure your router automatically.

Security note:
  Do not open REST API or RCON to the public Internet. REST is enabled for local
  management and intentionally not opened in Windows Firewall unless you ask for it.
"@ | Write-Host
}

function Install-SteamCmd {
    $layout = Get-Layout
    Ensure-Directory $layout.Root
    Ensure-Directory $layout.SteamCmdDir

    if (Test-Path -LiteralPath $layout.SteamCmdExe) {
        Write-Good "SteamCMD already exists: $($layout.SteamCmdExe)"
        return
    }

    $zip = Join-Path $layout.Root 'steamcmd.zip'
    Write-Info "Downloading SteamCMD from Valve CDN..."
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Script:SteamCmdZipUrl -OutFile $zip
    Expand-Archive -Path $zip -DestinationPath $layout.SteamCmdDir -Force
    Remove-Item -LiteralPath $zip -Force

    if (-not (Test-Path -LiteralPath $layout.SteamCmdExe)) {
        throw "SteamCMD download completed but steamcmd.exe was not found."
    }
    Write-Good "SteamCMD installed."
}

function Invoke-SteamCmdUpdate {
    param([switch]$Validate)
    $layout = Get-Layout
    Install-SteamCmd
    Ensure-Directory $layout.ServerDir

    $args = @(
        '+force_install_dir', $layout.ServerDir,
        '+login', 'anonymous',
        '+app_update', $Script:SteamAppId
    )
    if ($Validate) {
        $args += 'validate'
    }
    $args += '+quit'

    Write-Info "Installing/updating Palworld Dedicated Server app $Script:SteamAppId..."
    & $layout.SteamCmdExe @args
    if ($LASTEXITCODE -ne 0) {
        throw "SteamCMD failed with exit code $LASTEXITCODE."
    }
    if (-not (Test-Path -LiteralPath $layout.ServerExe)) {
        throw "PalServer.exe was not found after install/update: $($layout.ServerExe)"
    }
    Write-Good "Palworld Dedicated Server files are installed."
}

function Ensure-SettingsFile {
    $layout = Get-Layout
    if (Test-Path -LiteralPath $layout.SettingsFile) {
        return
    }
    if (-not (Test-Path -LiteralPath $layout.DefaultSettings)) {
        throw "DefaultPalWorldSettings.ini not found. Run install/update first."
    }
    Ensure-Directory ([System.IO.Path]::GetDirectoryName($layout.SettingsFile))
    Copy-Item -LiteralPath $layout.DefaultSettings -Destination $layout.SettingsFile -Force
    Write-Good "Created PalWorldSettings.ini from default settings."
}

function Split-TopLevelComma {
    param([string]$Text)
    $items = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $depth = 0
    $inQuote = $false
    $escape = $false

    foreach ($ch in $Text.ToCharArray()) {
        if ($escape) {
            [void]$current.Append($ch)
            $escape = $false
            continue
        }
        if ($ch -eq '\') {
            [void]$current.Append($ch)
            $escape = $true
            continue
        }
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            [void]$current.Append($ch)
            continue
        }
        if (-not $inQuote) {
            if ($ch -eq '(') { $depth++ }
            if ($ch -eq ')' -and $depth -gt 0) { $depth-- }
            if ($ch -eq ',' -and $depth -eq 0) {
                $items.Add($current.ToString().Trim())
                [void]$current.Clear()
                continue
            }
        }
        [void]$current.Append($ch)
    }
    if ($current.Length -gt 0) {
        $items.Add($current.ToString().Trim())
    }
    return $items
}

function Split-TopLevelEquals {
    param([string]$Text)
    $depth = 0
    $inQuote = $false
    $escape = $false
    for ($i = 0; $i -lt $Text.Length; $i++) {
        $ch = $Text[$i]
        if ($escape) {
            $escape = $false
            continue
        }
        if ($ch -eq '\') {
            $escape = $true
            continue
        }
        if ($ch -eq '"') {
            $inQuote = -not $inQuote
            continue
        }
        if (-not $inQuote) {
            if ($ch -eq '(') { $depth++ }
            if ($ch -eq ')' -and $depth -gt 0) { $depth-- }
            if ($ch -eq '=' -and $depth -eq 0) {
                return @($Text.Substring(0, $i).Trim(), $Text.Substring($i + 1).Trim())
            }
        }
    }
    return @($Text.Trim(), '')
}

function Read-PalSettings {
    Ensure-SettingsFile
    $layout = Get-Layout
    $content = Get-Content -LiteralPath $layout.SettingsFile -Raw
    $match = [regex]::Match($content, '(?s)OptionSettings=\((?<body>.*)\)')
    if (-not $match.Success) {
        throw "OptionSettings=(...) was not found in $($layout.SettingsFile)"
    }

    $ordered = New-Object System.Collections.Specialized.OrderedDictionary
    foreach ($entry in (Split-TopLevelComma $match.Groups['body'].Value)) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $pair = Split-TopLevelEquals $entry
        if ($pair[0]) {
            $ordered[$pair[0]] = $pair[1]
        }
    }
    return $ordered
}

function ConvertTo-PalRawValue {
    param(
        [string]$Name,
        [string]$InputValue,
        [object]$ExistingRaw
    )
    if ($null -eq $InputValue) {
        return '""'
    }
    $trimmed = $InputValue.Trim()
    if ($trimmed.StartsWith('raw:', [StringComparison]::OrdinalIgnoreCase)) {
        return $trimmed.Substring(4)
    }
    if ($trimmed -match '^(?i:true|false)$') {
        if ($trimmed -match '^(?i:true)$') { return 'True' }
        return 'False'
    }
    if ($trimmed -match '^-?\d+(\.\d+)?$') {
        return $trimmed
    }
    if ($trimmed.StartsWith('(') -and $trimmed.EndsWith(')')) {
        return $trimmed
    }
    if ($trimmed.StartsWith('"') -and $trimmed.EndsWith('"')) {
        return $trimmed
    }

    $stringKeys = @(
        'AdminPassword',
        'BanListURL',
        'PublicIP',
        'Region',
        'ServerDescription',
        'ServerName',
        'ServerPassword'
    )
    if ($stringKeys -contains $Name) {
        $escaped = $trimmed.Replace('\', '\\').Replace('"', '\"')
        return '"' + $escaped + '"'
    }

    if ($null -ne $ExistingRaw -and [string]$ExistingRaw -match '^".*"$') {
        $escapedExisting = $trimmed.Replace('\', '\\').Replace('"', '\"')
        return '"' + $escapedExisting + '"'
    }

    return $trimmed
}

function Write-PalSettings {
    param([System.Collections.Specialized.OrderedDictionary]$Settings)
    $layout = Get-Layout
    $content = Get-Content -LiteralPath $layout.SettingsFile -Raw
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($keyName in $Settings.Keys) {
        $parts.Add(('{0}={1}' -f $keyName, $Settings[$keyName]))
    }
    $replacement = 'OptionSettings=(' + ($parts -join ',') + ')'
    $newContent = [regex]::Replace($content, '(?s)OptionSettings=\(.*\)', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $replacement }, 1)
    Set-Content -LiteralPath $layout.SettingsFile -Value $newContent -Encoding UTF8
}

function Set-PalSettingValues {
    param([hashtable]$Values)
    $settings = Read-PalSettings
    foreach ($name in $Values.Keys) {
        $existing = $null
        if ($settings.Contains($name)) { $existing = $settings[$name] }
        $settings[$name] = ConvertTo-PalRawValue -Name $name -InputValue ([string]$Values[$name]) -ExistingRaw $existing
    }
    Write-PalSettings -Settings $settings
    Write-Good "Updated PalWorldSettings.ini."
}

function Get-UnquotedSetting {
    param([string]$Name)
    try {
        $settings = Read-PalSettings
        if (-not $settings.Contains($Name)) { return $null }
        $raw = [string]$settings[$Name]
        if ($raw.StartsWith('"') -and $raw.EndsWith('"')) {
            return $raw.Substring(1, $raw.Length - 2).Replace('\"', '"').Replace('\\', '\')
        }
        return $raw
    } catch {
        return $null
    }
}

function Parse-SetPairs {
    $values = @{}
    if ($Set) {
        foreach ($rawItem in $Set) {
            foreach ($item in (Split-TopLevelComma $rawItem)) {
                if ([string]::IsNullOrWhiteSpace($item)) { continue }
                $pair = Split-TopLevelEquals $item
                if (-not $pair[0] -or $pair.Count -lt 2) {
                    throw "Invalid -Set item '$item'. Use Key=Value."
                }
                $values[$pair[0]] = $pair[1]
            }
        }
    }
    if ($Key) {
        $values[$Key] = $Value
    }
    return $values
}

function Apply-InstallSettings {
    $state = Get-State
    if (-not $state.ContainsKey('Port')) { $state['Port'] = $Port }
    if (-not $state.ContainsKey('Players')) { $state['Players'] = $Players }
    if (-not $state.ContainsKey('PublicLobby')) { $state['PublicLobby'] = [bool]$PublicLobby }
    if (-not $state.ContainsKey('RestPort')) { $state['RestPort'] = $RestPort }
    if (-not $state.ContainsKey('LogFormat')) { $state['LogFormat'] = $LogFormat }
    if (-not $state.ContainsKey('UsePerfArgs')) { $state['UsePerfArgs'] = [bool]$UsePerfArgs }
    if (-not $state.ContainsKey('WorkerThreads')) { $state['WorkerThreads'] = $WorkerThreads }

    if ($PSBoundParameters.ContainsKey('Port')) { $state['Port'] = $Port }
    if ($PSBoundParameters.ContainsKey('Players')) { $state['Players'] = $Players }
    if ($PSBoundParameters.ContainsKey('PublicLobby')) { $state['PublicLobby'] = [bool]$PublicLobby }
    if ($PSBoundParameters.ContainsKey('PublicIP')) { $state['PublicIP'] = $PublicIP }
    if ($PSBoundParameters.ContainsKey('PublicPort') -and $PublicPort -gt 0) { $state['PublicPort'] = $PublicPort }
    if ($PSBoundParameters.ContainsKey('RestPort')) { $state['RestPort'] = $RestPort }
    if ($PSBoundParameters.ContainsKey('LogFormat')) { $state['LogFormat'] = $LogFormat }
    if ($PSBoundParameters.ContainsKey('UsePerfArgs')) { $state['UsePerfArgs'] = [bool]$UsePerfArgs }
    if ($PSBoundParameters.ContainsKey('WorkerThreads')) { $state['WorkerThreads'] = $WorkerThreads }

    $admin = $AdminPassword
    if ([string]::IsNullOrWhiteSpace($admin)) {
        $existingAdmin = Get-UnquotedSetting 'AdminPassword'
        if ([string]::IsNullOrWhiteSpace($existingAdmin)) {
            $admin = New-Password
            Write-Warn "No AdminPassword supplied. Generated one and wrote it to PalWorldSettings.ini."
            Write-Warn "Admin password: $admin"
        } else {
            $admin = $existingAdmin
        }
    }

    $settingsToApply = @{
        AdminPassword        = $admin
        RESTAPIEnabled       = 'True'
        RESTAPIPort          = [string]$RestPort
        RCONEnabled          = if ($EnableRcon) { 'True' } else { 'False' }
        RCONPort             = [string]$RconPort
        ServerPlayerMaxNum   = [string]$Players
        bIsUseBackupSaveData = 'True'
        bShowPlayerList      = 'True'
        LogFormatType        = $LogFormat
    }
    if ($ServerName) {
        $settingsToApply['ServerName'] = $ServerName
    } elseif (-not (Get-UnquotedSetting 'ServerName')) {
        $settingsToApply['ServerName'] = 'Neo Palworld'
    }
    if ($ServerDescription) {
        $settingsToApply['ServerDescription'] = $ServerDescription
    }
    if ($PSBoundParameters.ContainsKey('ServerPassword')) {
        $settingsToApply['ServerPassword'] = $ServerPassword
    }
    if ($PublicIP) {
        $settingsToApply['PublicIP'] = $PublicIP
    }
    if ($PublicPort -gt 0) {
        $settingsToApply['PublicPort'] = [string]$PublicPort
    } else {
        $settingsToApply['PublicPort'] = [string]$Port
    }

    Set-PalSettingValues $settingsToApply
    $state['AdminPasswordSet'] = $true
    Save-State $state
}

function Get-LaunchArgs {
    $state = Get-State
    $launchPort = if ($state.ContainsKey('Port')) { [int]$state['Port'] } else { $Port }
    $launchPlayers = if ($state.ContainsKey('Players')) { [int]$state['Players'] } else { $Players }
    $launchLogFormat = if ($state.ContainsKey('LogFormat')) { [string]$state['LogFormat'] } else { $LogFormat }

    $args = @("-port=$launchPort", "-players=$launchPlayers", "-logformat=$launchLogFormat")
    if ($state.ContainsKey('PublicLobby') -and [bool]$state['PublicLobby']) {
        $args += '-publiclobby'
    }
    if ($state.ContainsKey('PublicIP') -and -not [string]::IsNullOrWhiteSpace([string]$state['PublicIP'])) {
        $args += "-publicip=$($state['PublicIP'])"
    }
    if ($state.ContainsKey('PublicPort') -and [int]$state['PublicPort'] -gt 0) {
        $args += "-publicport=$($state['PublicPort'])"
    }

    $perf = $false
    if ($state.ContainsKey('UsePerfArgs')) { $perf = [bool]$state['UsePerfArgs'] }
    if ($perf) {
        $args += @('-useperfthreads', '-NoAsyncLoadingThread', '-UseMultithreadForDS')
        if ($state.ContainsKey('WorkerThreads') -and [int]$state['WorkerThreads'] -gt 0) {
            $args += "-NumberOfWorkerThreadsServer=$($state['WorkerThreads'])"
        }
    }
    return $args
}

function Get-PalServerProcesses {
    $layout = Get-Layout
    $serverRoot = $layout.ServerDir.ToLowerInvariant()
    try {
        return Get-CimInstance Win32_Process |
            Where-Object {
                $_.ExecutablePath -and
                $_.ExecutablePath.ToLowerInvariant().StartsWith($serverRoot) -and
                ($_.Name -like 'PalServer*' -or $_.CommandLine -like '*PalServer*')
            }
    } catch {
        Write-Warn "Could not inspect process command lines: $($_.Exception.Message)"
        return Get-Process -Name 'PalServer*' -ErrorAction SilentlyContinue
    }
}

function Test-ServerRunning {
    @((Get-PalServerProcesses)).Count -gt 0
}

function Start-PalServer {
    $layout = Get-Layout
    if (-not (Test-Path -LiteralPath $layout.ServerExe)) {
        throw "PalServer.exe not found. Run install first."
    }
    if (Test-ServerRunning) {
        Write-Warn "Palworld server already appears to be running."
        return
    }
    Ensure-SettingsFile
    $args = Get-LaunchArgs
    Write-Info "Starting PalServer.exe $($args -join ' ')"
    Start-Process -FilePath $layout.ServerExe -WorkingDirectory $layout.ServerDir -ArgumentList $args -WindowStyle Minimized | Out-Null
    Start-Sleep -Seconds 3
    if (Test-ServerRunning) {
        Write-Good "Palworld server started."
    } else {
        Write-Warn "Start was requested, but no PalServer process was found yet. Check logs."
    }
}

function Get-ApiPassword {
    if ($AdminPassword) { return $AdminPassword }
    $fromConfig = Get-UnquotedSetting 'AdminPassword'
    if ($fromConfig) { return $fromConfig }
    throw "AdminPassword is required for REST API calls. Set it in config or pass -AdminPassword."
}

function Invoke-PalApi {
    param(
        [string]$Endpoint,
        [string]$Method = 'GET',
        [object]$BodyObject = $null,
        [switch]$Quiet
    )
    $state = Get-State
    $effectiveRestPort = if ($state.ContainsKey('RestPort')) { [int]$state['RestPort'] } else { $RestPort }
    $password = Get-ApiPassword
    $authText = '{0}:{1}' -f $ApiUser, $password
    $authBytes = [System.Text.Encoding]::ASCII.GetBytes($authText)
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String($authBytes) }

    $cleanEndpoint = $Endpoint.TrimStart('/')
    $bases = @(
        "http://$ApiHost`:$effectiveRestPort/v1/api",
        "http://$ApiHost`:$effectiveRestPort"
    )

    $lastError = $null
    foreach ($base in $bases) {
        $uri = "$base/$cleanEndpoint"
        try {
            $params = @{
                Uri         = $uri
                Method      = $Method
                Headers     = $headers
                TimeoutSec  = 8
                ErrorAction = 'Stop'
            }
            if ($null -ne $BodyObject) {
                $params['ContentType'] = 'application/json'
                $params['Body'] = ($BodyObject | ConvertTo-Json -Depth 8)
            }
            if (-not $Quiet) { Write-Info "$Method $uri" }
            return Invoke-RestMethod @params
        } catch {
            $lastError = $_
        }
    }
    throw $lastError
}

function Save-World {
    try {
        Invoke-PalApi -Endpoint 'save' -Method 'POST' -Quiet | Out-Null
        Write-Good "World save requested through REST API."
        return $true
    } catch {
        Write-Warn "Could not call REST /save: $($_.Exception.Message)"
        return $false
    }
}

function Stop-PalServer {
    param([switch]$Hard)
    $processes = @(Get-PalServerProcesses)
    if ($processes.Count -eq 0) {
        Write-Warn "No Palworld server process found."
        return
    }

    if (-not $Hard) {
        try {
            Save-World | Out-Null
            Invoke-PalApi -Endpoint 'shutdown' -Method 'POST' -BodyObject @{ waittime = $ShutdownWait; message = $Message } -Quiet | Out-Null
            Write-Info "Shutdown requested. Waiting up to $($ShutdownWait + 30) seconds..."
            $deadline = (Get-Date).AddSeconds($ShutdownWait + 30)
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 2
                if (-not (Test-ServerRunning)) {
                    Write-Good "Palworld server stopped gracefully."
                    return
                }
            }
        } catch {
            Write-Warn "Graceful REST shutdown failed: $($_.Exception.Message)"
        }
    }

    if ($Hard -or $Force) {
        Write-Warn "Force-stopping Palworld server process."
        foreach ($proc in @(Get-PalServerProcesses)) {
            Stop-Process -Id $proc.ProcessId -Force
        }
        Write-Good "Palworld server process stopped."
    } else {
        Write-Warn "Server is still running. Use -Force if you need a hard stop."
    }
}

function New-Backup {
    param([string]$Name)
    $layout = Get-Layout
    if (-not (Test-Path -LiteralPath $layout.SavedDir)) {
        throw "Saved directory not found yet: $($layout.SavedDir). Start the server once first."
    }

    Ensure-Directory $layout.BackupsDir
    Save-World | Out-Null
    Start-Sleep -Seconds 2

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $safeName = if ($Name) { $Name -replace '[^\w.-]+', '_' } else { "palworld-save-$stamp" }
    $zip = Join-Path $layout.BackupsDir "$safeName.zip"
    if (Test-Path -LiteralPath $zip) {
        throw "Backup already exists: $zip"
    }

    $temp = Join-Path $env:TEMP "palworld-backup-$stamp"
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    Ensure-Directory $temp
    Copy-Item -LiteralPath $layout.SavedDir -Destination (Join-Path $temp 'Saved') -Recurse -Force
    if (Test-Path -LiteralPath $layout.SettingsFile) {
        Ensure-Directory (Join-Path $temp 'Config')
        Copy-Item -LiteralPath $layout.SettingsFile -Destination (Join-Path $temp 'Config\PalWorldSettings.ini') -Force
    }
    $stateFile = (Get-Layout).StateFile
    if (Test-Path -LiteralPath $stateFile) {
        Copy-Item -LiteralPath $stateFile -Destination (Join-Path $temp 'manager-state.json') -Force
    }

    Compress-Archive -Path (Join-Path $temp '*') -DestinationPath $zip -CompressionLevel Optimal
    Remove-Item -LiteralPath $temp -Recurse -Force
    Write-Good "Backup created: $zip"
    Prune-Backups -KeepCount $Keep
}

function Prune-Backups {
    param([int]$KeepCount)
    if ($KeepCount -le 0) { return }
    $layout = Get-Layout
    if (-not (Test-Path -LiteralPath $layout.BackupsDir)) { return }
    $backups = Get-ChildItem -LiteralPath $layout.BackupsDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending
    $old = @($backups | Select-Object -Skip $KeepCount)
    foreach ($file in $old) {
        Remove-Item -LiteralPath $file.FullName -Force
        Write-Info "Pruned old backup: $($file.Name)"
    }
}

function Restore-Backup {
    $layout = Get-Layout
    $zip = $RestoreFile
    if (-not $zip) {
        if ($BackupName) {
            $candidate = Join-Path $layout.BackupsDir $BackupName
            if (-not $candidate.EndsWith('.zip')) { $candidate += '.zip' }
            $zip = $candidate
        } else {
            $zip = Get-ChildItem -LiteralPath $layout.BackupsDir -Filter '*.zip' |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1 -ExpandProperty FullName
        }
    }
    if (-not $zip -or -not (Test-Path -LiteralPath $zip)) {
        throw "Backup zip not found. Use list-backups first."
    }

    if (Test-ServerRunning) {
        if (-not $Force) {
            throw "Server is running. Re-run with -Force to stop and restore."
        }
        Stop-PalServer -Hard:$false
    }

    if (-not $NoBackup -and (Test-Path -LiteralPath $layout.SavedDir)) {
        New-Backup -Name ('pre-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    $temp = Join-Path $env:TEMP ('palworld-restore-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force }
    Expand-Archive -Path $zip -DestinationPath $temp -Force
    $savedSource = Join-Path $temp 'Saved'
    if (-not (Test-Path -LiteralPath $savedSource)) {
        throw "Backup does not contain a Saved folder: $zip"
    }
    if (Test-Path -LiteralPath $layout.SavedDir) {
        Remove-Item -LiteralPath $layout.SavedDir -Recurse -Force
    }
    Ensure-Directory ([System.IO.Path]::GetDirectoryName($layout.SavedDir))
    Copy-Item -LiteralPath $savedSource -Destination $layout.SavedDir -Recurse -Force
    Remove-Item -LiteralPath $temp -Recurse -Force
    Write-Good "Restored backup: $zip"
}

function Show-Backups {
    $layout = Get-Layout
    if (-not (Test-Path -LiteralPath $layout.BackupsDir)) {
        Write-Warn "No backups directory exists yet."
        return
    }
    Get-ChildItem -LiteralPath $layout.BackupsDir -Filter '*.zip' |
        Sort-Object LastWriteTime -Descending |
        Select-Object LastWriteTime, Length, FullName |
        Format-Table -AutoSize
}

function Show-Settings {
    $settings = Read-PalSettings
    foreach ($name in $settings.Keys) {
        '{0}={1}' -f $name, $settings[$name]
    }
}

function Apply-Preset {
    param([string]$Name)
    $presets = @{
        'launch-public' = @{
            bIsUseBackupSaveData = 'True'
            bShowPlayerList      = 'True'
            RESTAPIEnabled       = 'True'
            RESTAPIPort          = [string]$RestPort
            RCONEnabled          = 'False'
            ChatPostLimitPerMinute = '10'
            LogFormatType        = $LogFormat
        }
        balanced = @{
            ExpRate                    = '1.0'
            PalCaptureRate             = '1.0'
            PalSpawnNumRate            = '1.0'
            CollectionDropRate         = '1.0'
            EnemyDropItemRate          = '1.0'
            DeathPenalty               = 'All'
            BaseCampMaxNum             = '4'
            BaseCampWorkerMaxNum       = '20'
            BuildObjectDeteriorationDamageRate = '1.0'
        }
        casual = @{
            ExpRate              = '1.5'
            PalCaptureRate       = '1.5'
            CollectionDropRate   = '1.5'
            EnemyDropItemRate    = '1.25'
            PalEggDefaultHatchingTime = '0.5'
            DeathPenalty         = 'Item'
            BuildObjectDeteriorationDamageRate = '0.5'
        }
        performance = @{
            PalSpawnNumRate                  = '0.8'
            BaseCampMaxNum                   = '4'
            BaseCampWorkerMaxNum             = '20'
            DropItemMaxNum                   = '2000'
            DropItemAliveMaxHours            = '1.0'
            ServerReplicatePawnCullDistance  = '10000'
            ItemContainerForceMarkDirtyInterval = '1.0'
        }
        pvp = @{
            bIsPvP                         = 'True'
            bEnablePlayerToPlayerDamage    = 'True'
            bEnableFriendlyFire            = 'False'
            bEnableDefenseOtherGuildPlayer = 'True'
            DeathPenalty                   = 'Item'
        }
        hardcore = @{
            bHardcore      = 'True'
            bPalLost       = 'True'
            DeathPenalty   = 'All'
            ExpRate        = '1.0'
        }
    }
    if (-not $presets.ContainsKey($Name)) {
        throw "Unknown preset '$Name'. Available: $($presets.Keys -join ', ')"
    }
    Set-PalSettingValues $presets[$Name]
    Write-Good "Applied preset: $Name"
}

function Set-Firewall {
    $state = Get-State
    $gamePort = if ($state.ContainsKey('Port')) { [int]$state['Port'] } else { $Port }
    $effectiveRestPort = if ($state.ContainsKey('RestPort')) { [int]$state['RestPort'] } else { $RestPort }

    if (-not (Get-Command New-NetFirewallRule -ErrorAction SilentlyContinue)) {
        throw "New-NetFirewallRule is not available on this system."
    }

    $gameRuleName = "Palworld Dedicated Server UDP $gamePort"
    if (-not (Get-NetFirewallRule -DisplayName $gameRuleName -ErrorAction SilentlyContinue)) {
        New-NetFirewallRule -DisplayName $gameRuleName -Direction Inbound -Action Allow -Protocol UDP -LocalPort $gamePort | Out-Null
        Write-Good "Added Windows Firewall rule: $gameRuleName"
    } else {
        Write-Good "Firewall rule already exists: $gameRuleName"
    }

    if ($OpenRestApiFirewall) {
        $restRuleName = "Palworld REST API TCP $effectiveRestPort"
        if (-not (Get-NetFirewallRule -DisplayName $restRuleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $restRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $effectiveRestPort | Out-Null
            Write-Warn "Opened REST API firewall port. Do not expose this through your router."
        }
    }
    if ($OpenRconFirewall) {
        $rconRuleName = "Palworld RCON TCP $RconPort"
        if (-not (Get-NetFirewallRule -DisplayName $rconRuleName -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -DisplayName $rconRuleName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $RconPort | Out-Null
            Write-Warn "Opened RCON firewall port. RCON is deprecated and should stay LAN-only."
        }
    }
}

function Show-PortAdvice {
    $state = Get-State
    $gamePort = if ($state.ContainsKey('Port')) { [int]$state['Port'] } else { $Port }
    $effectiveRestPort = if ($state.ContainsKey('RestPort')) { [int]$state['RestPort'] } else { $RestPort }
    $public = $null
    try {
        $public = Invoke-RestMethod -Uri 'https://api.ipify.org?format=text' -TimeoutSec 5
    } catch {
        $public = '(could not detect)'
    }
    @"
Palworld public server ports:

  Required router forward:
    UDP $gamePort -> this PC

  Windows Firewall:
    Run: .\PalworldServerManager.ps1 firewall

  Public IP:
    $public

  Connect directly in Palworld:
    <your-public-ip>:$gamePort

  Community listing:
    Start with -PublicLobby during install, or set PublicLobby in manager-state.json.

  Keep private:
    TCP $effectiveRestPort REST API and TCP $RconPort RCON should remain LAN/local only.
"@ | Write-Host
}

function Show-Status {
    $layout = Get-Layout
    $state = Get-State
    $processes = @(Get-PalServerProcesses)
    Write-Host "Root:        $($layout.Root)"
    Write-Host "Server exe:  $($layout.ServerExe)"
    Write-Host "Config:      $($layout.SettingsFile)"
    Write-Host "Running:     $($processes.Count -gt 0)"
    foreach ($proc in $processes) {
        Write-Host "Process:     PID $($proc.ProcessId) $($proc.Name)"
    }
    if ($state.Count -gt 0) {
        Write-Host "Launch args: $((Get-LaunchArgs) -join ' ')"
    }
    try {
        $info = Invoke-PalApi -Endpoint 'info' -Method 'GET' -Quiet
        Write-Good "REST API reachable."
        $info | ConvertTo-Json -Depth 8
    } catch {
        Write-Warn "REST API not reachable: $($_.Exception.Message)"
    }
}

function Invoke-Doctor {
    $layout = Get-Layout
    Write-Host "Palworld server doctor"
    Write-Host ""
    Write-Host "Root: $($layout.Root)"

    if (Test-Path -LiteralPath $layout.SteamCmdExe) { Write-Good "SteamCMD installed." } else { Write-Warn "SteamCMD missing. Run install." }
    if (Test-Path -LiteralPath $layout.ServerExe) { Write-Good "PalServer.exe installed." } else { Write-Warn "PalServer.exe missing. Run install." }
    if (Test-Path -LiteralPath $layout.SettingsFile) { Write-Good "PalWorldSettings.ini exists." } else { Write-Warn "Settings file missing. Run install/update or start once." }

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        $ramGb = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
        if ($ramGb -ge 16) { Write-Good "RAM: $ramGb GB" } else { Write-Warn "RAM: $ramGb GB. 16 GB is the official requirement; 32 GB+ is recommended for larger servers." }
        Write-Info "CPU logical processors: $($cs.NumberOfLogicalProcessors)"
    } catch {
        Write-Warn "Could not read CPU/RAM info: $($_.Exception.Message)"
    }

    try {
        $drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($layout.Root).TrimEnd('\').TrimEnd(':'))
        $freeGb = [math]::Round($drive.Free / 1GB, 1)
        if ($freeGb -ge 20) { Write-Good "Free disk on server drive: $freeGb GB" } else { Write-Warn "Free disk on server drive: $freeGb GB. Keep room for backups and updates." }
    } catch {
        Write-Warn "Could not read disk info: $($_.Exception.Message)"
    }

    if (Test-ServerRunning) { Write-Good "Server process is running." } else { Write-Warn "Server process is not running." }
    Show-PortAdvice
}

function Invoke-Update {
    if (-not $NoBackup) {
        try { New-Backup -Name ('pre-update-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) } catch { Write-Warn "Pre-update backup skipped: $($_.Exception.Message)" }
    }
    if (Test-ServerRunning) {
        Stop-PalServer
        if (Test-ServerRunning -and $Force) { Stop-PalServer -Hard }
    }
    Invoke-SteamCmdUpdate -Validate:(!$NoValidate)
}

function Configure-Mods {
    $layout = Get-Layout
    Ensure-Directory ([System.IO.Path]::GetDirectoryName($layout.ModsFile))
    if ($DisableMods) {
        "[PalModSettings]`r`nbGlobalEnableMod=false`r`n" | Set-Content -LiteralPath $layout.ModsFile -Encoding UTF8
        Write-Good "Disabled mods in PalModSettings.ini."
        return
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('[PalModSettings]')
    if ($ModPackage -and $ModPackage.Count -gt 0) {
        $lines.Add('bGlobalEnableMod=true')
        foreach ($pkg in $ModPackage) {
            if (-not [string]::IsNullOrWhiteSpace($pkg)) {
                $lines.Add("ActiveModList=$pkg")
            }
        }
    } else {
        $lines.Add('bGlobalEnableMod=false')
    }
    if ($WorkshopRootDir) {
        $lines.Add("WorkshopRootDir=$WorkshopRootDir")
    }
    $lines | Set-Content -LiteralPath $layout.ModsFile -Encoding UTF8
    Write-Good "Wrote mod settings: $($layout.ModsFile)"
    Write-Warn "Restart the server to deploy mod changes."
}

function Register-BackupTask {
    if (-not (Get-Command Register-ScheduledTask -ErrorAction SilentlyContinue)) {
        throw "ScheduledTasks module is not available."
    }
    $scriptPath = $PSCommandPath
    $argument = '-NoProfile -ExecutionPolicy Bypass -File "{0}" backup -Root "{1}" -Keep {2}' -f $scriptPath, (Get-Layout).Root, $Keep
    $actionObj = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argument
    $triggerObj = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Minutes $BackupEveryMinutes) -RepetitionDuration (New-TimeSpan -Days 3650)
    Register-ScheduledTask -TaskName $Script:TaskNameBackup -Action $actionObj -Trigger $triggerObj -Description 'PalworldServerManager automatic save backup' -Force | Out-Null
    Write-Good "Scheduled backup task registered every $BackupEveryMinutes minutes."
}

function Unregister-BackupTask {
    if (Get-ScheduledTask -TaskName $Script:TaskNameBackup -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Script:TaskNameBackup -Confirm:$false
        Write-Good "Scheduled backup task removed."
    } else {
        Write-Warn "Scheduled backup task was not found."
    }
}

function Show-Logs {
    param([switch]$Wait)
    $layout = Get-Layout
    if (-not (Test-Path -LiteralPath $layout.LogsDir)) {
        Write-Warn "No server logs directory yet: $($layout.LogsDir)"
        return
    }
    $latest = Get-ChildItem -LiteralPath $layout.LogsDir -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        Write-Warn "No log files found in $($layout.LogsDir)"
        return
    }
    Write-Info "Showing log: $($latest.FullName)"
    if ($Wait) {
        Get-Content -LiteralPath $latest.FullName -Tail 120 -Wait
    } else {
        Get-Content -LiteralPath $latest.FullName -Tail 120
    }
}

switch ($Action) {
    'help' {
        Show-Help
    }
    'doctor' {
        Invoke-Doctor
    }
    'install' {
        Ensure-Directory (Get-Layout).Root
        Invoke-SteamCmdUpdate -Validate:(!$NoValidate)
        Ensure-SettingsFile
        Apply-InstallSettings
        Apply-Preset 'launch-public'
        Write-Good "Install complete."
        Write-Warn "Next: run '.\PalworldServerManager.ps1 firewall' as Administrator, then forward UDP $Port on your router."
    }
    'update' {
        Invoke-Update
        Write-Good "Update complete."
    }
    'start' {
        Start-PalServer
    }
    'stop' {
        Stop-PalServer -Hard:$Force
    }
    'restart' {
        if (-not $NoBackup) {
            try { New-Backup -Name ('pre-restart-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) } catch { Write-Warn "Pre-restart backup skipped: $($_.Exception.Message)" }
        }
        Stop-PalServer
        if (Test-ServerRunning -and $Force) { Stop-PalServer -Hard }
        Start-PalServer
    }
    'status' {
        Show-Status
    }
    'backup' {
        New-Backup -Name $BackupName
    }
    'restore' {
        Restore-Backup
    }
    'list-backups' {
        Show-Backups
    }
    'settings' {
        Show-Settings
    }
    'set' {
        $pairs = Parse-SetPairs
        if ($pairs.Count -eq 0) { throw "Nothing to set. Use -Set Key=Value or -Key Name -Value Value." }
        Set-PalSettingValues $pairs
    }
    'preset' {
        Apply-Preset $PresetName
    }
    'firewall' {
        Set-Firewall
    }
    'ports' {
        Show-PortAdvice
    }
    'api' {
        $body = $null
        if ($JsonBody) { $body = $JsonBody | ConvertFrom-Json }
        Invoke-PalApi -Endpoint $ApiEndpoint -Method $ApiMethod -BodyObject $body | ConvertTo-Json -Depth 12
    }
    'info' {
        Invoke-PalApi -Endpoint 'info' -Method 'GET' | ConvertTo-Json -Depth 12
    }
    'players' {
        Invoke-PalApi -Endpoint 'players' -Method 'GET' | ConvertTo-Json -Depth 12
    }
    'metrics' {
        Invoke-PalApi -Endpoint 'metrics' -Method 'GET' | ConvertTo-Json -Depth 12
    }
    'announce' {
        Invoke-PalApi -Endpoint 'announce' -Method 'POST' -BodyObject @{ message = $Message } | ConvertTo-Json -Depth 12
    }
    'save' {
        Save-World | Out-Null
    }
    'shutdown' {
        Invoke-PalApi -Endpoint 'shutdown' -Method 'POST' -BodyObject @{ waittime = $ShutdownWait; message = $Message } | ConvertTo-Json -Depth 12
    }
    'mods' {
        Configure-Mods
    }
    'schedule-backup' {
        Register-BackupTask
    }
    'unschedule-backup' {
        Unregister-BackupTask
    }
    'logs' {
        Show-Logs
    }
    'tail' {
        Show-Logs -Wait
    }
    default {
        Show-Help
    }
}
