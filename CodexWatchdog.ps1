#requires -Version 7.0

<#
.SYNOPSIS
Conservatively monitors and recovers the Windows Codex desktop application.

.DESCRIPTION
The watchdog examines only process metadata, Codex lifecycle event types, the
dedicated Remote transport logger, and read-only SQLite health/enrollment data.
It never records prompt, response, credential, or enrollment-secret content.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Check', 'Status', 'Restart', 'LaunchOnly', 'Install', 'Uninstall')]
    [string]$Action = 'Check',

    [switch]$Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:WatchdogWhatIfMode = [bool]$WhatIfPreference
# The Appx module emits unrelated alias-registration WhatIf messages while
# auto-importing. The script enforces its captured WhatIf mode explicitly.
$WhatIfPreference = $false
$script:WatchdogScriptPath = $PSCommandPath

function Get-WatchdogConfig {
    $codexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }
    $dataRoot = Join-Path $env:LOCALAPPDATA 'CodexWatchdog'
    $scriptRoot = Split-Path -Parent $script:WatchdogScriptPath

    return [ordered]@{
        SchemaVersion                  = 1
        PackageName                   = 'OpenAI.Codex'
        TaskName                      = 'Codex Remote Watchdog'
        TaskPath                      = '\Codex\'
        CodexHome                     = $codexHome
        SessionsRoot                  = Join-Path $codexHome 'sessions'
        DataRoot                      = $dataRoot
        StatePath                     = Join-Path $dataRoot 'state.json'
        EventLogPath                  = Join-Path $dataRoot 'watchdog.jsonl'
        SnapshotRoot                  = Join-Path $dataRoot 'snapshots'
        ScriptPath                    = $script:WatchdogScriptPath
        LauncherPath                  = Join-Path $scriptRoot 'CodexWatchdogLauncher.vbs'
        UserHome                      = [Environment]::GetFolderPath('UserProfile')
        StartupDirectory              = [Environment]::GetFolderPath('Startup')
        PreDispatchFreezeMinutes      = 3
        ProgressStaleMinutes          = 60
        StaleConfirmationMinutes      = 5
        AppServerMissingMinutes       = 5
        AppServerMissingChecks        = 3
        StartupGraceMinutes           = 5
        RecoveryVerificationSeconds   = 60
        GracefulShutdownSeconds       = 15
        FailedRecoveryCooldownMinutes = 10
        MaxAutomaticRecoveriesPerHour = 3
        RemoteFailureWindowMinutes    = 15
        RemoteFailureMinimumCount     = 3
        RemoteFailureMinimumSpan      = 5
        RolloutLookbackMinutes        = 120
        RolloutNewestFileCount        = 50
        RolloutMaximumFileCount       = 100
        RolloutTailBytes              = 16777216
        EventLogMaximumBytes          = 5242880
        SnapshotMaximumCount          = 50
    }
}

function ConvertTo-UtcDateTimeOffset {
    param([Parameter(Mandatory)]$Value)

    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTime]) {
        return ([DateTimeOffset]$Value).ToUniversalTime()
    }
    return [DateTimeOffset]::Parse(
        [string]$Value,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime()
}

function ConvertTo-UtcString {
    param([Parameter(Mandatory)]$Value)
    return (ConvertTo-UtcDateTimeOffset $Value).ToString('o')
}

function New-WatchdogState {
    return [ordered]@{
        schemaVersion               = 1
        appServerMissingSinceUtc    = $null
        appServerMissingChecks      = 0
        startupGraceUntilUtc        = $null
        staleCandidates             = @()
        automaticRecoveryHistoryUtc = @()
        failedRecoveryUntilUtc      = $null
        lastCheckUtc                = $null
        lastDecision                = $null
        lastReason                  = $null
    }
}

function Copy-WatchdogState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$State)
    return (($State | ConvertTo-Json -Depth 12) | ConvertFrom-Json -AsHashtable -Depth 12)
}

function Read-WatchdogState {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    if (-not (Test-Path -LiteralPath $Config.StatePath -PathType Leaf)) {
        return New-WatchdogState
    }

    try {
        $state = Get-Content -LiteralPath $Config.StatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 12
        if ($state.schemaVersion -ne $Config.SchemaVersion) {
            return New-WatchdogState
        }

        foreach ($key in @('staleCandidates', 'automaticRecoveryHistoryUtc')) {
            if (-not $state.ContainsKey($key) -or $null -eq $state[$key]) {
                $state[$key] = @()
            } else {
                $state[$key] = @($state[$key])
            }
        }
        return $state
    } catch {
        return New-WatchdogState
    }
}

function Initialize-WatchdogDataRoot {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    foreach ($path in @($Config.DataRoot, $Config.SnapshotRoot)) {
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Save-WatchdogState {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State
    )

    Initialize-WatchdogDataRoot -Config $Config
    $temporaryPath = Join-Path $Config.DataRoot ('.state-{0}.tmp' -f [Guid]::NewGuid().ToString('N'))
    try {
        $json = $State | ConvertTo-Json -Depth 12
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporaryPath -Destination $Config.StatePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Rotate-WatchdogEventLog {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    if (-not (Test-Path -LiteralPath $Config.EventLogPath -PathType Leaf)) {
        return
    }
    if ((Get-Item -LiteralPath $Config.EventLogPath).Length -lt $Config.EventLogMaximumBytes) {
        return
    }

    $archivePath = "$($Config.EventLogPath).1"
    Move-Item -LiteralPath $Config.EventLogPath -Destination $archivePath -Force
}

function Write-WatchdogEvent {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$Event,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Outcome = 'observed',
        [string[]]$ThreadIds = @(),
        [int[]]$ProcessIds = @(),
        [string]$PackageVersion = '',
        $Validation = $null
    )

    Initialize-WatchdogDataRoot -Config $Config
    Rotate-WatchdogEventLog -Config $Config
    $record = [ordered]@{
        timestampUtc   = [DateTimeOffset]::UtcNow.ToString('o')
        event          = $Event
        reason         = $Reason
        outcome        = $Outcome
        threadIds      = @($ThreadIds | Select-Object -Unique)
        processIds     = @($ProcessIds | Select-Object -Unique)
        packageVersion = $PackageVersion
    }
    if ($null -ne $Validation) {
        $record['validation'] = $Validation
    }
    $line = $record | ConvertTo-Json -Depth 12 -Compress
    [IO.File]::AppendAllText($Config.EventLogPath, "$line$([Environment]::NewLine)", [Text.UTF8Encoding]::new($false))
}

function Write-DiagnosticSnapshot {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Decision
    )

    Initialize-WatchdogDataRoot -Config $Config
    $timestamp = [DateTimeOffset]::UtcNow
    $snapshot = [ordered]@{
        timestampUtc   = $timestamp.ToString('o')
        reason         = $Decision.Reason
        packageVersion = $Observation.Package.Version
        processIds     = @($Observation.Process.AllPackageProcessIds)
        triggerValidation = $Decision.Validation
        threads        = @($Observation.Threads | ForEach-Object {
            [ordered]@{
                threadId       = $_.ThreadId
                status         = $_.Status
                lastEventType  = $_.LastEventType
                taskStartedUtc = if ($_.TaskStartedUtc) { ConvertTo-UtcString $_.TaskStartedUtc } else { $null }
                lastProgressUtc = if ($_.LastProgressUtc) { ConvertTo-UtcString $_.LastProgressUtc } else { $null }
            }
        })
    }
    $path = Join-Path $Config.SnapshotRoot ('snapshot-{0}.json' -f $timestamp.ToString('yyyyMMddTHHmmssfffZ'))
    [IO.File]::WriteAllText($path, ($snapshot | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

    $oldSnapshots = Get-ChildItem -LiteralPath $Config.SnapshotRoot -Filter 'snapshot-*.json' -File |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -Skip $Config.SnapshotMaximumCount
    foreach ($oldSnapshot in $oldSnapshots) {
        Remove-Item -LiteralPath $oldSnapshot.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-CodexPackageInfo {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $package = Get-AppxPackage -Name $Config.PackageName -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending |
        Select-Object -First 1
    if (-not $package) {
        return [ordered]@{
            Found               = $false
            Version             = ''
            PackageFullName     = ''
            PackageFamilyName   = ''
            InstallLocation     = ''
            DesktopExecutable   = ''
            AppServerExecutable = ''
            AppServerBinRoot    = ''
            Aumid               = ''
        }
    }

    $applicationId = $null
    try {
        $manifest = Get-AppxPackageManifest -Package $package.PackageFullName
        $desktopApplication = @($manifest.Package.Applications.Application) |
            Where-Object { ([string]$_.Executable).Replace('\', '/') -ieq 'app/ChatGPT.exe' } |
            Select-Object -First 1
        if ($desktopApplication) {
            $applicationId = [string]$desktopApplication.Id
        }
    } catch {
        $applicationId = $null
    }
    if (-not $applicationId) {
        $startApp = Get-StartApps | Where-Object { $_.AppID -like "$($package.PackageFamilyName)!*" } | Select-Object -First 1
        if ($startApp) {
            $applicationId = ([string]$startApp.AppID -split '!', 2)[1]
        }
    }

    return [ordered]@{
        Found               = $true
        Version             = [string]$package.Version
        PackageFullName     = [string]$package.PackageFullName
        PackageFamilyName   = [string]$package.PackageFamilyName
        InstallLocation     = [string]$package.InstallLocation
        DesktopExecutable   = Join-Path ([string]$package.InstallLocation) 'app\ChatGPT.exe'
        AppServerExecutable = Join-Path ([string]$package.InstallLocation) 'app\resources\codex.exe'
        AppServerBinRoot    = if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin' } else { '' }
        Aumid               = if ($applicationId) { "$($package.PackageFamilyName)!$applicationId" } else { '' }
    }
}

function Test-ProcessDescendsFrom {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int[]]$AncestorIds,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProcessById
    )

    $seen = @{}
    $currentId = $ProcessId
    for ($depth = 0; $depth -lt 20; $depth++) {
        if ($AncestorIds -contains $currentId) {
            return $true
        }
        if ($seen.ContainsKey($currentId) -or -not $ProcessById.Contains($currentId)) {
            return $false
        }
        $seen[$currentId] = $true
        $currentId = [int]$ProcessById[$currentId].ParentProcessId
    }
    return $false
}

function Test-CodexAppServerExecutablePath {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    if ($Package.AppServerExecutable -and $ExecutablePath -ieq $Package.AppServerExecutable) {
        return $true
    }

    $binRoot = if ($Package.Contains('AppServerBinRoot')) { [string]$Package.AppServerBinRoot } else { '' }
    if (-not $binRoot) {
        return $false
    }

    try {
        $candidatePath = [IO.Path]::GetFullPath($ExecutablePath)
        if ([IO.Path]::GetFileName($candidatePath) -ine 'codex.exe') {
            return $false
        }

        $versionDirectory = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($candidatePath))
        if (-not $versionDirectory.Name -or $null -eq $versionDirectory.Parent) {
            return $false
        }

        $separators = [char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        $normalizedBinRoot = [IO.Path]::GetFullPath($binRoot).TrimEnd($separators)
        $candidateBinRoot = $versionDirectory.Parent.FullName.TrimEnd($separators)
        return $candidateBinRoot -ieq $normalizedBinRoot
    } catch {
        return $false
    }
}

function Get-CodexProcessObservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [object[]]$Processes
    )

    if (-not $Package.Found) {
        return [ordered]@{
            DesktopPresent      = $false
            AppServerPresent    = $false
            RootProcessIds      = @()
            AppServerProcessIds = @()
            AllPackageProcessIds = @()
            RootStartedUtc      = $null
            AppServerStartedUtc = $null
        }
    }

    if (-not $PSBoundParameters.ContainsKey('Processes')) {
        $Processes = @(Get-CimInstance Win32_Process | Where-Object { $_.Name -in @('ChatGPT.exe', 'codex.exe') })
    }

    $processById = @{}
    foreach ($process in @($Processes)) {
        $processById[[int]$process.ProcessId] = $process
    }

    $desktopCandidates = @($Processes | Where-Object {
        $_.Name -ieq 'ChatGPT.exe' -and $_.ExecutablePath -and $_.ExecutablePath -ieq $Package.DesktopExecutable
    })
    $rootProcesses = @($desktopCandidates | Where-Object {
        -not $_.CommandLine -or $_.CommandLine -notmatch '(?i)(?:^|\s)--type='
    })
    $rootIds = @($rootProcesses | ForEach-Object { [int]$_.ProcessId })

    $appServerCandidates = @($Processes | Where-Object {
        $_.Name -ieq 'codex.exe' -and
        $_.ExecutablePath -and (Test-CodexAppServerExecutablePath -Package $Package -ExecutablePath $_.ExecutablePath) -and
        $_.CommandLine -match '(?i)(?:^|\s)app-server(?:\s|$)'
    })
    $appServers = @($appServerCandidates | Where-Object {
        Test-ProcessDescendsFrom -ProcessId ([int]$_.ParentProcessId) -AncestorIds $rootIds -ProcessById $processById
    })
    $appServerIds = @($appServers | ForEach-Object { [int]$_.ProcessId })

    $allPackageIds = @($Processes | Where-Object {
        $_.ExecutablePath -and (
            $_.ExecutablePath -ieq $Package.DesktopExecutable -or
            $_.ExecutablePath -ieq $Package.AppServerExecutable -or
            $appServerIds -contains [int]$_.ProcessId
        )
    } | ForEach-Object { [int]$_.ProcessId })
    $rootStartTimes = @($rootProcesses | ForEach-Object {
        $value = Get-JsonPropertyValue -Object $_ -Name 'CreationDate'
        if ($value) { ConvertTo-UtcDateTimeOffset $value }
    } | Sort-Object)
    $appServerStartTimes = @($appServers | ForEach-Object {
        $value = Get-JsonPropertyValue -Object $_ -Name 'CreationDate'
        if ($value) { ConvertTo-UtcDateTimeOffset $value }
    } | Sort-Object)

    return [ordered]@{
        DesktopPresent       = $rootIds.Count -gt 0
        AppServerPresent     = $appServers.Count -gt 0
        RootProcessIds       = $rootIds
        AppServerProcessIds  = $appServerIds
        AllPackageProcessIds = $allPackageIds
        RootStartedUtc       = if ($rootStartTimes.Count -gt 0) { $rootStartTimes[0] } else { $null }
        AppServerStartedUtc  = if ($appServerStartTimes.Count -gt 0) { $appServerStartTimes[0] } else { $null }
    }
}

function Get-CodexDatabasePaths {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    function Get-LatestVersionedDatabase([string]$Prefix) {
        $files = @(Get-ChildItem -LiteralPath $Config.CodexHome -Filter "${Prefix}_*.sqlite" -File -ErrorAction SilentlyContinue)
        return $files | Sort-Object @{ Expression = {
            if ($_.BaseName -match '_(\d+)$') { [int]$Matches[1] } else { -1 }
        }; Descending = $true }, LastWriteTimeUtc -Descending | Select-Object -First 1
    }

    $stateDatabase = Get-LatestVersionedDatabase 'state'
    $logsDatabase = Get-LatestVersionedDatabase 'logs'
    return [ordered]@{
        State = if ($stateDatabase) { $stateDatabase.FullName } else { '' }
        Logs  = if ($logsDatabase) { $logsDatabase.FullName } else { '' }
    }
}

function Invoke-SqliteQuery {
    param(
        [Parameter(Mandatory)][string]$Database,
        [Parameter(Mandatory)][string]$Query
    )

    $sqlite = Get-Command sqlite3 -ErrorAction Stop
    $output = @(& $sqlite.Source -batch -readonly -cmd '.timeout 5000' $Database $Query 2>&1)
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "SQLite read-only query failed with exit code $exitCode."
    }
    return @($output | ForEach-Object { [string]$_ })
}

function Test-CodexDatabaseIntegrity {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$DatabasePaths)

    $details = [ordered]@{}
    $healthy = $true
    foreach ($name in @('State', 'Logs')) {
        $path = [string]$DatabasePaths[$name]
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $details[$name] = 'missing'
            $healthy = $false
            continue
        }
        try {
            $result = @(Invoke-SqliteQuery -Database $path -Query 'PRAGMA quick_check;')
            if ($result.Count -eq 1 -and $result[0].Trim() -eq 'ok') {
                $details[$name] = 'ok'
            } else {
                $details[$name] = 'failed'
                $healthy = $false
            }
        } catch {
            $details[$name] = 'unavailable'
            $healthy = $false
        }
    }

    return [ordered]@{
        Healthy = $healthy
        State   = $details.State
        Logs    = $details.Logs
    }
}

function Get-RemoteEnrollmentObservation {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$DatabasePaths)

    if (-not $DatabasePaths.State) {
        return [ordered]@{ Status = 'Unavailable'; EnabledCount = 0 }
    }
    try {
        $rows = @(Invoke-SqliteQuery -Database $DatabasePaths.State -Query @'
SELECT count(*)
FROM remote_control_enrollments
WHERE coalesce(remote_control_enabled, 0) = 1;
'@)
        $count = if ($rows.Count -gt 0) { [int]$rows[0] } else { 0 }
        return [ordered]@{
            Status       = if ($count -gt 0) { 'Enabled' } else { 'Disabled' }
            EnabledCount = $count
        }
    } catch {
        return [ordered]@{ Status = 'Unavailable'; EnabledCount = 0 }
    }
}

function Get-RemoteTransportObservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$DatabasePaths,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $empty = [ordered]@{
        ManualCondition = $false
        ManualReason    = ''
        RepeatedFailure = $false
        FailureCount    = 0
        FailureSpanMinutes = 0
    }
    if (-not $DatabasePaths.Logs) {
        return $empty
    }

    $since = $Now.AddMinutes(-$Config.RemoteFailureWindowMinutes).ToUnixTimeSeconds()
    $query = @"
SELECT ts, level,
CASE
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%mfa%' THEN 'auth_mfa'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%unauthorized%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%status%401%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%http%401%' THEN 'auth_401'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%forbidden%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%status%403%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%http%403%' THEN 'auth_403'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%conflict%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%status%409%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%http%409%' THEN 'auth_409'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%skipping auto-attach for closed connection%' THEN 'isolated_disconnect'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%fail%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%error%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%disconnect%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%closed%' THEN 'failure'
  WHEN lower(coalesce(feedback_log_body, '')) LIKE '%connected%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%connection established%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%attached%'
    OR lower(coalesce(feedback_log_body, '')) LIKE '%registered%' THEN 'success'
  ELSE 'other'
END
FROM logs
WHERE ts >= $since
  AND target LIKE 'codex_app_server_transport::transport::remote_control%'
ORDER BY ts ASC;
"@

    try {
        $rows = @(Invoke-SqliteQuery -Database $DatabasePaths.Logs -Query $query)
    } catch {
        return $empty
    }

    $events = @($rows | ForEach-Object {
        $parts = $_ -split '\|', 3
        if ($parts.Count -eq 3) {
            [ordered]@{ Timestamp = [long]$parts[0]; Level = $parts[1]; Category = $parts[2] }
        }
    })
    $manual = @($events | Where-Object { $_.Category -like 'auth_*' } | Select-Object -Last 1)
    if ($manual.Count -gt 0) {
        $empty.ManualCondition = $true
        $empty.ManualReason = $manual[0].Category
        return $empty
    }

    $lastSuccess = @($events | Where-Object Category -eq 'success' | ForEach-Object Timestamp | Measure-Object -Maximum).Maximum
    $failures = @($events | Where-Object {
        $_.Category -eq 'failure' -and (-not $lastSuccess -or $_.Timestamp -gt $lastSuccess)
    })
    if ($failures.Count -eq 0) {
        return $empty
    }

    $firstFailure = [long]$failures[0].Timestamp
    $lastFailure = [long]$failures[-1].Timestamp
    $spanMinutes = ($lastFailure - $firstFailure) / 60.0
    $latestAgeSeconds = $Now.ToUnixTimeSeconds() - $lastFailure
    $empty.FailureCount = $failures.Count
    $empty.FailureSpanMinutes = [Math]::Round($spanMinutes, 2)
    $empty.RepeatedFailure = (
        $failures.Count -ge $Config.RemoteFailureMinimumCount -and
        $spanMinutes -ge $Config.RemoteFailureMinimumSpan -and
        $latestAgeSeconds -le 120
    )
    return $empty
}

function Read-JsonlTail {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaximumBytes
    )

    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $start = [Math]::Max(0, $stream.Length - $MaximumBytes)
        [void]$stream.Seek($start, [IO.SeekOrigin]::Begin)
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true, 4096, $true)
        try {
            if ($start -gt 0) {
                [void]$reader.ReadLine()
            }
            while (-not $reader.EndOfStream) {
                $reader.ReadLine()
            }
        } finally {
            $reader.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

function Get-JsonPropertyValue {
    param(
        $Object,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $null
}

function Test-IsLifecycleProgressEvent {
    param([Parameter(Mandatory)]$Event)

    if ($Event.TopType -eq 'turn_context') { return $true }
    if ($Event.TopType -eq 'event_msg' -and $Event.PayloadType -in @(
        'user_message', 'agent_reasoning', 'agent_message', 'token_count',
        'item_completed', 'patch_apply_end', 'web_search_end'
    )) { return $true }
    if ($Event.TopType -eq 'response_item' -and $Event.PayloadType -in @(
        'reasoning', 'function_call', 'function_call_output',
        'custom_tool_call', 'custom_tool_call_output'
    )) { return $true }
    if ($Event.TopType -eq 'response_item' -and $Event.PayloadType -eq 'message' -and
        $Event.Role -in @('user', 'assistant')) { return $true }
    return $false
}

function Get-RolloutObservation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [long]$MaximumBytes = 16777216
    )

    $threadMatch = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($Path), '([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$', 'IgnoreCase')
    if (-not $threadMatch.Success) { return $null }
    $threadId = $threadMatch.Groups[1].Value
    $events = [Collections.Generic.List[object]]::new()
    $sequence = 0

    foreach ($line in Read-JsonlTail -Path $Path -MaximumBytes $MaximumBytes) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $json = $line | ConvertFrom-Json -Depth 30 -ErrorAction Stop
            $timestampValue = Get-JsonPropertyValue -Object $json -Name 'timestamp'
            $topType = [string](Get-JsonPropertyValue -Object $json -Name 'type')
            $payload = Get-JsonPropertyValue -Object $json -Name 'payload'
            $payloadType = [string](Get-JsonPropertyValue -Object $payload -Name 'type')
            $role = [string](Get-JsonPropertyValue -Object $payload -Name 'role')
            $callId = [string](Get-JsonPropertyValue -Object $payload -Name 'call_id')
            if (-not $timestampValue -or -not $topType) { continue }
            $events.Add([pscustomobject]@{
                Sequence    = $sequence
                Timestamp   = ConvertTo-UtcDateTimeOffset $timestampValue
                TopType     = $topType
                PayloadType = $payloadType
                Role        = $role
                CallId      = $callId
            })
            $sequence++
        } catch {
            # A partially written final JSONL line is normal; unparseable content is ignored.
        }
    }
    if ($events.Count -eq 0) { return $null }

    $lastStart = -1
    $lastComplete = -1
    for ($index = 0; $index -lt $events.Count; $index++) {
        $event = $events[$index]
        if ($event.TopType -eq 'event_msg' -and $event.PayloadType -eq 'task_started') { $lastStart = $index }
        if ($event.TopType -eq 'event_msg' -and $event.PayloadType -eq 'task_complete') { $lastComplete = $index }
    }

    $segmentStart = -1
    $inferred = $false
    if ($lastStart -gt $lastComplete) {
        $segmentStart = $lastStart
    } else {
        $progressAfterComplete = @($events | Where-Object {
            $_.Sequence -gt $lastComplete -and (Test-IsLifecycleProgressEvent $_)
        })
        if ($progressAfterComplete.Count -gt 0) {
            $segmentStart = $progressAfterComplete[0].Sequence
            $inferred = $true
        }
    }
    if ($segmentStart -lt 0) { return $null }

    $segment = @($events | Where-Object Sequence -ge $segmentStart)
    $progressEvents = @($segment | Where-Object { Test-IsLifecycleProgressEvent $_ })
    $taskStartedUtc = if ($inferred) { $segment[0].Timestamp } else { $events[$lastStart].Timestamp }
    $lastProgress = if ($progressEvents.Count -gt 0) { $progressEvents[-1] } else { $null }
    $openCalls = @{}
    $waiting = $false
    foreach ($event in $segment) {
        if ($event.TopType -eq 'response_item' -and $event.PayloadType -in @('function_call', 'custom_tool_call') -and $event.CallId) {
            $openCalls[$event.CallId] = $event.Timestamp
        }
        if ($event.TopType -eq 'response_item' -and $event.PayloadType -in @('function_call_output', 'custom_tool_call_output') -and $event.CallId) {
            $openCalls.Remove($event.CallId)
        }
        if ($event.PayloadType -match '(?i)(approval.*request|request_user_input|user_input.*request)') {
            $waiting = $true
        }
        if ($event.PayloadType -match '(?i)(approval.*response|user_input.*response)') {
            $waiting = $false
        }
    }

    $stage = if ($progressEvents.Count -eq 0) { 'PreDispatch' } else { 'Progressed' }
    $lastProgressUtc = if ($lastProgress) { $lastProgress.Timestamp } else { $null }
    $lastEventType = if ($lastProgress) { "$($lastProgress.TopType)/$($lastProgress.PayloadType)" } else { 'event_msg/task_started' }
    $fingerprintTimestamp = if ($lastProgressUtc) { $lastProgressUtc.UtcTicks } else { $taskStartedUtc.UtcTicks }
    $fingerprint = '{0}:{1}:{2}:{3}' -f $fingerprintTimestamp, $lastEventType, $openCalls.Count, $waiting

    return [pscustomobject][ordered]@{
        ThreadId        = $threadId
        Stage           = $stage
        TaskStartedUtc  = $taskStartedUtc
        LastProgressUtc = $lastProgressUtc
        LastEventType   = $lastEventType
        OutstandingTool = $openCalls.Count -gt 0
        Waiting         = $waiting
        Fingerprint     = $fingerprint
        Status          = ''
    }
}

function Set-ThreadHealthStatus {
    param(
        [Parameter(Mandatory)]$Thread,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    if ($Thread.OutstandingTool) {
        $Thread.Status = 'ToolRunning'
        return $Thread
    }
    if ($Thread.Waiting) {
        $Thread.Status = 'WaitingForInput'
        return $Thread
    }
    if ($Thread.Stage -eq 'PreDispatch') {
        $age = ($Now - (ConvertTo-UtcDateTimeOffset $Thread.TaskStartedUtc)).TotalMinutes
        $Thread.Status = if ($age -ge $Config.PreDispatchFreezeMinutes) { 'PreDispatchFreeze' } else { 'Starting' }
        return $Thread
    }

    if (-not $Thread.LastProgressUtc) {
        $Thread.Status = 'StaleCandidate'
        return $Thread
    }
    $progressAge = ($Now - (ConvertTo-UtcDateTimeOffset $Thread.LastProgressUtc)).TotalMinutes
    $Thread.Status = if ($progressAge -ge $Config.ProgressStaleMinutes) { 'StaleCandidate' } else { 'Healthy' }
    return $Thread
}

function Get-CodexLifecycleObservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        $AppServerStartedUtc
    )

    if (-not (Test-Path -LiteralPath $Config.SessionsRoot -PathType Container)) {
        return @()
    }
    $allFiles = @(Get-ChildItem -LiteralPath $Config.SessionsRoot -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending)
    $cutoff = $Now.UtcDateTime.AddMinutes(-$Config.RolloutLookbackMinutes)
    $trackedIds = @($State.staleCandidates | ForEach-Object { [string]$_.threadId })
    $selected = @($allFiles | Where-Object {
        $_.LastWriteTimeUtc -ge $cutoff -or $trackedIds -contains ([regex]::Match($_.BaseName, '([0-9a-f-]{36})$').Groups[1].Value)
    })
    $selected += @($allFiles | Select-Object -First $Config.RolloutNewestFileCount)
    $selected = @($selected | Group-Object FullName | ForEach-Object { $_.Group[0] } |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First $Config.RolloutMaximumFileCount)

    $threads = @()
    foreach ($file in $selected) {
        try {
            $thread = Get-RolloutObservation -Path $file.FullName -Now $Now -MaximumBytes $Config.RolloutTailBytes
            if ($thread) {
                if ($AppServerStartedUtc) {
                    $generationStart = (ConvertTo-UtcDateTimeOffset $AppServerStartedUtc).AddMinutes(-1)
                    $latestActivity = if ($thread.LastProgressUtc) { ConvertTo-UtcDateTimeOffset $thread.LastProgressUtc } else { ConvertTo-UtcDateTimeOffset $thread.TaskStartedUtc }
                    if ($latestActivity -lt $generationStart) {
                        continue
                    }
                }
                $threads += Set-ThreadHealthStatus -Thread $thread -Config $Config -Now $Now
            }
        } catch {
            # One unreadable rollout must not make a recovery decision less conservative.
        }
    }
    return @($threads | Group-Object ThreadId | ForEach-Object { $_.Group | Select-Object -First 1 })
}

function Update-StaleCandidateState {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Threads,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $existing = @{}
    foreach ($candidate in @($State.staleCandidates)) {
        $existing[[string]$candidate.threadId] = $candidate
    }
    $next = @()
    $confirmed = @()
    foreach ($thread in @($Threads | Where-Object Status -eq 'StaleCandidate')) {
        $candidate = $existing[[string]$thread.ThreadId]
        if ($candidate -and [string]$candidate.fingerprint -eq [string]$thread.Fingerprint) {
            $observedSince = ConvertTo-UtcDateTimeOffset $candidate.observedSinceUtc
        } else {
            $observedSince = $Now
        }
        $next += [ordered]@{
            threadId        = $thread.ThreadId
            fingerprint     = $thread.Fingerprint
            observedSinceUtc = $observedSince.ToString('o')
        }
        if (($Now - $observedSince).TotalMinutes -ge $Config.StaleConfirmationMinutes) {
            $confirmed += $thread.ThreadId
        }
    }
    $State.staleCandidates = $next
    return @($confirmed)
}

function Get-RecoverySuppressionReason {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $history = @($State.automaticRecoveryHistoryUtc | Where-Object {
        try { (ConvertTo-UtcDateTimeOffset $_) -gt $Now.AddHours(-1) } catch { $false }
    })
    $State.automaticRecoveryHistoryUtc = $history

    if ($State.failedRecoveryUntilUtc) {
        try {
            if ((ConvertTo-UtcDateTimeOffset $State.failedRecoveryUntilUtc) -gt $Now) {
                return 'FailedRecoveryCooldown'
            }
        } catch {
            $State.failedRecoveryUntilUtc = $null
        }
    }
    if ($history.Count -ge $Config.MaxAutomaticRecoveriesPerHour) {
        return 'AutomaticRecoveryRateLimit'
    }
    return ''
}

function New-WatchdogDecision {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Reason,
        [string[]]$ThreadIds = @(),
        [string[]]$ProtectedByThreadIds = @()
    )
    return [ordered]@{
        Action               = $Action
        Reason               = $Reason
        ThreadIds            = @($ThreadIds)
        ProtectedByThreadIds = @($ProtectedByThreadIds)
        Validation           = $null
    }
}

function New-ValidationCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('passed', 'failed', 'requested', 'info')][string]$Status,
        $Expected = $null,
        $Observed = $null,
        [System.Collections.IDictionary]$Details
    )

    $check = [ordered]@{
        name     = $Name
        status   = $Status
        expected = $Expected
        observed = $Observed
    }
    if ($Details) {
        foreach ($key in $Details.Keys) {
            $check[$key] = $Details[$key]
        }
    }
    return [pscustomobject]$check
}

function Get-TriggerValidationReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Decision,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $checks = @()
    switch ($Decision.Reason) {
        'CodexPackageNotFound' {
            $checks += New-ValidationCheck -Name 'CodexPackageDiscovered' -Status 'failed' -Expected $true -Observed $false
        }
        'DatabaseIntegrityNotHealthy' {
            $checks += New-ValidationCheck -Name 'StateDatabaseIntegrity' -Status $(if ($Observation.Integrity.State -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Observation.Integrity.State
            $checks += New-ValidationCheck -Name 'LogsDatabaseIntegrity' -Status $(if ($Observation.Integrity.Logs -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Observation.Integrity.Logs
        }
        { $_ -like 'RemoteEnrollment*' } {
            $checks += New-ValidationCheck -Name 'RemoteEnrollmentEnabled' -Status 'failed' -Expected 'Enabled' -Observed $Observation.Enrollment.Status -Details ([ordered]@{ enabledCount = $Observation.Enrollment.EnabledCount })
        }
        { $_ -like 'RemoteAuthentication:*' } {
            $checks += New-ValidationCheck -Name 'RemoteAuthenticationHealthy' -Status 'failed' -Expected 'No recent Remote authentication error' -Observed $Observation.Remote.ManualReason
        }
        'CodexDesktopAbsent' {
            $checks += New-ValidationCheck -Name 'DesktopProcessPresent' -Status 'failed' -Expected $true -Observed $Observation.Process.DesktopPresent
        }
        'AppServerMissing' {
            $missingSince = if ($State.appServerMissingSinceUtc) { ConvertTo-UtcDateTimeOffset $State.appServerMissingSinceUtc } else { $Now }
            $checks += New-ValidationCheck -Name 'AppServerProcessPresent' -Status 'failed' -Expected $true -Observed $Observation.Process.AppServerPresent -Details ([ordered]@{
                firstMissingUtc = $missingSince.ToString('o')
                missingMinutes = [Math]::Round(($Now - $missingSince).TotalMinutes, 2)
                thresholdMinutes = $Config.AppServerMissingMinutes
                consecutiveChecks = [int]$State.appServerMissingChecks
                requiredConsecutiveChecks = $Config.AppServerMissingChecks
            })
        }
        'PreDispatchLifecycleFreeze' {
            foreach ($thread in @($Observation.Threads | Where-Object { $Decision.ThreadIds -contains $_.ThreadId })) {
                $started = ConvertTo-UtcDateTimeOffset $thread.TaskStartedUtc
                $checks += New-ValidationCheck -Name 'DispatchProgressObserved' -Status 'failed' -Expected $true -Observed $false -Details ([ordered]@{
                    threadId = $thread.ThreadId
                    taskStartedUtc = $started.ToString('o')
                    elapsedMinutes = [Math]::Round(($Now - $started).TotalMinutes, 2)
                    thresholdMinutes = $Config.PreDispatchFreezeMinutes
                    lastEventType = $thread.LastEventType
                })
            }
        }
        'ConfirmedStaleTask' {
            foreach ($thread in @($Observation.Threads | Where-Object { $Decision.ThreadIds -contains $_.ThreadId })) {
                $lastProgress = if ($thread.LastProgressUtc) { ConvertTo-UtcDateTimeOffset $thread.LastProgressUtc } else { $null }
                $candidate = @($State.staleCandidates | Where-Object { $_.threadId -eq $thread.ThreadId } | Select-Object -First 1)
                $confirmedSince = if ($candidate.Count -gt 0) { ConvertTo-UtcDateTimeOffset $candidate[0].observedSinceUtc } else { $null }
                $checks += New-ValidationCheck -Name 'LifecycleProgressFresh' -Status 'failed' -Expected "Progress within $($Config.ProgressStaleMinutes) minutes" -Observed $(if ($lastProgress) { "$([Math]::Round(($Now - $lastProgress).TotalMinutes, 2)) minutes since progress" } else { 'No progress timestamp' }) -Details ([ordered]@{
                    threadId = $thread.ThreadId
                    lastProgressUtc = if ($lastProgress) { $lastProgress.ToString('o') } else { $null }
                    lastEventType = $thread.LastEventType
                    staleThresholdMinutes = $Config.ProgressStaleMinutes
                    unchangedConfirmationMinutes = $Config.StaleConfirmationMinutes
                    candidateObservedSinceUtc = if ($confirmedSince) { $confirmedSince.ToString('o') } else { $null }
                })
            }
        }
        'RepeatedRemoteTransportFailure' {
            $checks += New-ValidationCheck -Name 'RemoteTransportHealthy' -Status 'failed' -Expected "Fewer than $($Config.RemoteFailureMinimumCount) failures or a span below $($Config.RemoteFailureMinimumSpan) minutes" -Observed "$($Observation.Remote.FailureCount) failures over $($Observation.Remote.FailureSpanMinutes) minutes" -Details ([ordered]@{
                failureCount = $Observation.Remote.FailureCount
                minimumFailureCount = $Config.RemoteFailureMinimumCount
                failureSpanMinutes = $Observation.Remote.FailureSpanMinutes
                minimumFailureSpanMinutes = $Config.RemoteFailureMinimumSpan
            })
        }
        'ManualRestartRequested' {
            $checks += New-ValidationCheck -Name 'ManualRestartRequested' -Status 'requested' -Expected $null -Observed $true
        }
    }

    if ($checks.Count -eq 0) { return $null }
    return [ordered]@{
        phase  = 'trigger'
        checks = $checks
    }
}

function Get-RecoveryValidationReport {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$BeforePackage,
        [Parameter(Mandatory)][System.Collections.IDictionary]$AfterPackage,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Process,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Integrity,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Enrollment
    )

    $checks = @(
        (New-ValidationCheck -Name 'CodexPackageDiscovered' -Status $(if ($AfterPackage.Found) { 'passed' } else { 'failed' }) -Expected $true -Observed $AfterPackage.Found)
        (New-ValidationCheck -Name 'DesktopProcessPresent' -Status $(if ($Process.DesktopPresent) { 'passed' } else { 'failed' }) -Expected $true -Observed $Process.DesktopPresent)
        (New-ValidationCheck -Name 'AppServerProcessPresent' -Status $(if ($Process.AppServerPresent) { 'passed' } else { 'failed' }) -Expected $true -Observed $Process.AppServerPresent)
        (New-ValidationCheck -Name 'StateDatabaseIntegrity' -Status $(if ($Integrity.State -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Integrity.State)
        (New-ValidationCheck -Name 'LogsDatabaseIntegrity' -Status $(if ($Integrity.Logs -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Integrity.Logs)
        (New-ValidationCheck -Name 'RemoteEnrollmentEnabled' -Status $(if ($Enrollment.Status -eq 'Enabled') { 'passed' } else { 'failed' }) -Expected 'Enabled' -Observed $Enrollment.Status -Details ([ordered]@{ enabledCount = $Enrollment.EnabledCount }))
    )
    return [ordered]@{
        phase                = 'postRecovery'
        packageVersionBefore = $BeforePackage.Version
        packageVersionAfter  = $AfterPackage.Version
        packageChanged       = $BeforePackage.Version -ne $AfterPackage.Version
        checks               = $checks
    }
}

function Get-WatchdogDecision {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $suppression = Get-RecoverySuppressionReason -State $State -Config $Config -Now $Now
    $confirmedStale = @(Update-StaleCandidateState -State $State -Threads @($Observation.Threads) -Config $Config -Now $Now)

    if (-not $Observation.Package.Found) {
        return New-WatchdogDecision -Action 'Manual' -Reason 'CodexPackageNotFound'
    }
    if (-not $Observation.Integrity.Healthy) {
        return New-WatchdogDecision -Action 'Manual' -Reason 'DatabaseIntegrityNotHealthy'
    }
    if ($Observation.Enrollment.Status -ne 'Enabled') {
        return New-WatchdogDecision -Action 'Manual' -Reason "RemoteEnrollment$($Observation.Enrollment.Status)"
    }
    if ($Observation.Remote.ManualCondition) {
        return New-WatchdogDecision -Action 'Manual' -Reason "RemoteAuthentication:$($Observation.Remote.ManualReason)"
    }

    if (-not $Observation.Process.DesktopPresent) {
        $State.appServerMissingSinceUtc = $null
        $State.appServerMissingChecks = 0
        if ($State.startupGraceUntilUtc) {
            try {
                if ((ConvertTo-UtcDateTimeOffset $State.startupGraceUntilUtc) -gt $Now) {
                    return New-WatchdogDecision -Action 'None' -Reason 'StartupGracePeriod'
                }
            } catch {
                $State.startupGraceUntilUtc = $null
            }
        }
        if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression }
        return New-WatchdogDecision -Action 'Launch' -Reason 'CodexDesktopAbsent'
    }

    $State.startupGraceUntilUtc = $null
    if (-not $Observation.Process.AppServerPresent) {
        if (-not $State.appServerMissingSinceUtc) {
            $State.appServerMissingSinceUtc = $Now.ToString('o')
            $State.appServerMissingChecks = 1
        } else {
            $State.appServerMissingChecks = [int]$State.appServerMissingChecks + 1
        }
        $missingSince = ConvertTo-UtcDateTimeOffset $State.appServerMissingSinceUtc
        if (($Now - $missingSince).TotalMinutes -ge $Config.AppServerMissingMinutes -and
            $State.appServerMissingChecks -ge $Config.AppServerMissingChecks) {
            if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression }
            return New-WatchdogDecision -Action 'Restart' -Reason 'AppServerMissing'
        }
        return New-WatchdogDecision -Action 'None' -Reason 'AppServerMissingObservationWindow'
    }

    $State.appServerMissingSinceUtc = $null
    $State.appServerMissingChecks = 0
    $protectors = @($Observation.Threads | Where-Object Status -in @('Healthy', 'Starting', 'ToolRunning', 'WaitingForInput'))
    $preDispatch = @($Observation.Threads | Where-Object Status -eq 'PreDispatchFreeze')

    if ($preDispatch.Count -gt 0) {
        $suspectIds = @($preDispatch | ForEach-Object ThreadId)
        $otherProtectors = @($protectors | Where-Object { $suspectIds -notcontains $_.ThreadId })
        if ($otherProtectors.Count -gt 0) {
            return New-WatchdogDecision -Action 'None' -Reason 'HealthyTaskProtectsSharedApp' -ThreadIds $suspectIds -ProtectedByThreadIds @($otherProtectors | ForEach-Object ThreadId)
        }
        if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression -ThreadIds $suspectIds }
        return New-WatchdogDecision -Action 'Restart' -Reason 'PreDispatchLifecycleFreeze' -ThreadIds $suspectIds
    }

    if ($confirmedStale.Count -gt 0) {
        $otherProtectors = @($protectors | Where-Object { $confirmedStale -notcontains $_.ThreadId })
        if ($otherProtectors.Count -gt 0) {
            return New-WatchdogDecision -Action 'None' -Reason 'HealthyTaskProtectsSharedApp' -ThreadIds $confirmedStale -ProtectedByThreadIds @($otherProtectors | ForEach-Object ThreadId)
        }
        if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression -ThreadIds $confirmedStale }
        return New-WatchdogDecision -Action 'Restart' -Reason 'ConfirmedStaleTask' -ThreadIds $confirmedStale
    }

    if ($Observation.Remote.RepeatedFailure) {
        if ($protectors.Count -gt 0) {
            return New-WatchdogDecision -Action 'None' -Reason 'HealthyTaskProtectsSharedApp' -ProtectedByThreadIds @($protectors | ForEach-Object ThreadId)
        }
        if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression }
        return New-WatchdogDecision -Action 'Restart' -Reason 'RepeatedRemoteTransportFailure'
    }

    if ($Observation.Threads.Count -eq 0) {
        return New-WatchdogDecision -Action 'None' -Reason 'HealthyIdle'
    }
    return New-WatchdogDecision -Action 'None' -Reason 'HealthyOrProtectedActivity'
}

function Get-CodexObservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    $package = Get-CodexPackageInfo -Config $Config
    $process = Get-CodexProcessObservation -Package $package
    $databases = Get-CodexDatabasePaths -Config $Config
    $integrity = Test-CodexDatabaseIntegrity -DatabasePaths $databases
    $enrollment = Get-RemoteEnrollmentObservation -DatabasePaths $databases
    $remote = Get-RemoteTransportObservation -Config $Config -DatabasePaths $databases -Now $Now
    $threads = @(Get-CodexLifecycleObservation -Config $Config -State $State -Now $Now -AppServerStartedUtc $process.AppServerStartedUtc)

    return [ordered]@{
        TimestampUtc = $Now.ToString('o')
        Package      = $package
        Process      = $process
        Integrity    = $integrity
        Enrollment   = $enrollment
        Remote       = $remote
        Threads      = $threads
    }
}

function Get-CodexDesktopLaunchPlan {
    <#
    .SYNOPSIS
    Selects the current user's installed Enhanced skill, or native package activation when absent.
    .DESCRIPTION
    Resolves the canonical skill on every launch. It never overrides width, runtime, icons or
    administrator options. An incomplete installed skill fails explicitly instead of bypassing it.
    #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [string]$UserHome = [Environment]::GetFolderPath('UserProfile')
    )
    if ($Package.Contains('Found') -and -not $Package.Found) {
        return [ordered]@{ Mode='Unavailable'; CanLaunch=$false; LauncherPath=$null; Error='The Codex package is not installed.' }
    }
    if (-not [IO.Path]::IsPathFullyQualified($UserHome)) { throw 'The current user home must be an absolute path.' }
    $skillRoot = Join-Path $UserHome '.agents\skills\better-codex'
    $skillLauncher = Join-Path $skillRoot 'scripts\codex-custom.ps1'
    if (Test-Path -LiteralPath $skillRoot) {
        if (-not (Test-Path -LiteralPath (Join-Path $skillRoot 'SKILL.md') -PathType Leaf) -or
            -not (Test-Path -LiteralPath $skillLauncher -PathType Leaf)) {
            return [ordered]@{ Mode='Unavailable'; CanLaunch=$false; LauncherPath=$skillLauncher; Error='The installed better-codex skill is incomplete.' }
        }
        $pwsh = Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1
        return [ordered]@{
            Mode='Enhanced'; CanLaunch=$true; LauncherPath=$skillLauncher; Executable=$pwsh.Source
            Arguments=('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $skillLauncher)
            WorkingDirectory=$skillRoot; Error=$null
        }
    }
    $aumid = if ($Package.Contains('Aumid')) { [string]$Package.Aumid } else { '' }
    return [ordered]@{ Mode='Native'; CanLaunch=[bool]$aumid; LauncherPath=$null; Aumid=$aumid; Error=if($aumid){$null}else{'The Codex App User Model ID could not be resolved.'} }
}

function Invoke-CodexNativeActivation {
    <# .SYNOPSIS Activates the discovered package through Windows without an executable-path fallback. #>
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package)

    if (-not $Package.Aumid) {
        throw 'The Codex App User Model ID could not be resolved.'
    }

    if (-not ('CodexApplicationActivation' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IApplicationActivationManager {
    [PreserveSig]
    int ActivateApplication(
        [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [MarshalAs(UnmanagedType.LPWStr)] string arguments,
        int options,
        out uint processId);
}

[ComImport, Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C")]
class ApplicationActivationManager {}

public static class CodexApplicationActivation {
    public static uint Activate(string appUserModelId) {
        var manager = (IApplicationActivationManager)new ApplicationActivationManager();
        try {
            uint processId;
            int result = manager.ActivateApplication(appUserModelId, null, 0, out processId);
            Marshal.ThrowExceptionForHR(result);
            return processId;
        } finally {
            Marshal.ReleaseComObject(manager);
        }
    }
}
'@ -ErrorAction Stop
    }

    [void][CodexApplicationActivation]::Activate($Package.Aumid)
}

function Start-CodexDesktop {
    <# .SYNOPSIS Requests the selected launch without changing the skill's normal preferences. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [string]$UserHome = [Environment]::GetFolderPath('UserProfile'),
        [System.Collections.IDictionary]$LaunchPlan
    )
    $plan = if ($LaunchPlan) { $LaunchPlan } else { Get-CodexDesktopLaunchPlan -Package $Package -UserHome $UserHome }
    if (-not $plan.CanLaunch) { throw $plan.Error }
    if ($plan.Mode -eq 'Enhanced') {
        $launcher = Start-Process -FilePath $plan.Executable -ArgumentList $plan.Arguments -WorkingDirectory $plan.WorkingDirectory -WindowStyle Hidden -PassThru -ErrorAction Stop
        return [ordered]@{ Mode='Enhanced'; LauncherPath=$plan.LauncherPath; LauncherProcessId=$launcher.Id }
    }
    Invoke-CodexNativeActivation -Package $Package
    return [ordered]@{ Mode='Native'; LauncherPath=$null; LauncherProcessId=$null }
}

function Set-CodexStartupLauncher {
    <#
    .SYNOPSIS
    Creates or repairs one explicitly requested, owned Startup link to the shared launch selector.
    .DESCRIPTION
    This does not enable/disable package startup or execute the link. Call only when preserving
    an existing enabled startup intent. A GUI-subsystem launcher avoids a PowerShell flash.
    CheckOnly never writes files. Foreign links and linked paths are refused.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config,[switch]$CheckOnly)
    $startupRoot = [string]$Config.StartupDirectory
    if (-not [IO.Path]::IsPathFullyQualified($startupRoot)) { throw 'The Startup directory must be absolute.' }
    if (Test-Path -LiteralPath $startupRoot) {
        $rootItem = Get-Item -LiteralPath $startupRoot -Force
        if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'The Startup directory must be an ordinary directory.' }
    }
    foreach ($source in @($Config.ScriptPath,$Config.LauncherPath)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Startup source is missing: $source" }
    }
    $pwsh = (Get-Command pwsh.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $target = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $path = Join-Path $startupRoot 'Codex Enhanced.lnk'
    $description = 'Codex Watchdog managed startup v1'
    $arguments = '//B //NoLogo "{0}" "{1}" "{2}" "LaunchOnly"' -f $Config.LauncherPath,$pwsh,$Config.ScriptPath
    $workingDirectory = Split-Path -Parent $Config.ScriptPath
    $existed = Test-Path -LiteralPath $path
    $originalBytes = $null
    $shell = New-Object -ComObject WScript.Shell
    $link = $null
    try {
        if ($existed) {
            $item = Get-Item -LiteralPath $path -Force
            if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Refusing a linked or non-file Startup entry.' }
            $link = $shell.CreateShortcut($path)
            if ($link.Description -cne $description -or $link.TargetPath -ine $target -or
                $link.Arguments -notmatch '^//B //NoLogo "[^"]*CodexWatchdogLauncher\.vbs" "[^"]*pwsh\.exe" "[^"]*CodexWatchdog\.ps1" "LaunchOnly"$') {
                throw "Refusing to overwrite an unrelated Startup entry: $path"
            }
            $originalBytes = [IO.File]::ReadAllBytes($path)
        } else { $link = $shell.CreateShortcut($path) }
        $needsChange = -not $existed -or $link.TargetPath -ine $target -or $link.Arguments -cne $arguments -or $link.WorkingDirectory -ine $workingDirectory
        $result = [ordered]@{ path=$path;target=$target;arguments=$arguments;description=$description;workingDirectory=$workingDirectory;needsChange=[bool]$needsChange;verified=(-not $needsChange);created=$false;checkOnly=[bool]$CheckOnly }
        if ($CheckOnly -or -not $needsChange) { return $result }
        $null = New-Item -ItemType Directory -Path $startupRoot -Force
        $link.TargetPath=$target;$link.Arguments=$arguments;$link.Description=$description;$link.WorkingDirectory=$workingDirectory;$link.WindowStyle=7
        $link.Save()
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link);$link=$null
        $link=$shell.CreateShortcut($path)
        if ($link.TargetPath -ine $target -or $link.Arguments -cne $arguments -or $link.Description -cne $description -or $link.WorkingDirectory -ine $workingDirectory) { throw 'The managed Startup link failed readback verification.' }
        $result.needsChange=$false;$result.verified=$true;$result.created=-not $existed
        return $result
    } catch {
        if ($null -ne $originalBytes) { [IO.File]::WriteAllBytes($path,$originalBytes) }
        elseif (-not $existed -and (Test-Path -LiteralPath $path -PathType Leaf)) { Remove-Item -LiteralPath $path -Force }
        throw
    } finally {
        if ($link) { [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link) }
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
}

function Stop-CodexPackageProcesses {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config
    )

    $observation = Get-CodexProcessObservation -Package $Package
    foreach ($rootId in @($observation.RootProcessIds)) {
        try {
            $process = Get-Process -Id $rootId -ErrorAction Stop
            [void]$process.CloseMainWindow()
        } catch {
            # The process may already have exited.
        }
    }

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Config.GracefulShutdownSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $remaining = Get-CodexProcessObservation -Package $Package
        if ($remaining.AllPackageProcessIds.Count -eq 0) { return }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    $remaining = Get-CodexProcessObservation -Package $Package
    foreach ($processId in @($remaining.AllPackageProcessIds)) {
        Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
    }
}

function Wait-CodexHealthyProcesses {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$InitialPackage,
        [Parameter(Mandatory)][int]$TimeoutSeconds
    )

    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $package = Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { $package = $InitialPackage }
        $process = Get-CodexProcessObservation -Package $package
        if ($process.DesktopPresent -and $process.AppServerPresent) {
            return [ordered]@{ Package = $package; Process = $process }
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $package = Get-CodexPackageInfo -Config $Config
    if (-not $package.Found) { $package = $InitialPackage }
    return [ordered]@{ Package = $package; Process = (Get-CodexProcessObservation -Package $package) }
}

function Invoke-CodexRecovery {
    param(
        [Parameter(Mandatory)][ValidateSet('Launch', 'Restart')][string]$Mode,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Decision,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [switch]$Automatic
    )

    Write-DiagnosticSnapshot -Config $Config -Observation $Observation -Decision $Decision
    if ($Automatic) {
        $State.automaticRecoveryHistoryUtc = @($State.automaticRecoveryHistoryUtc) + $Now.ToString('o')
    }

    Write-WatchdogEvent -Config $Config -Event $Mode -Reason $Decision.Reason -Outcome 'started' `
        -ThreadIds $Decision.ThreadIds -ProcessIds $Observation.Process.AllPackageProcessIds -PackageVersion $Observation.Package.Version -Validation $Decision.Validation

    if ($Mode -eq 'Restart') {
        Stop-CodexPackageProcesses -Package $Observation.Package -Config $Config
    }
    $launch = Start-CodexDesktop -Package $Observation.Package -UserHome $Config.UserHome
    $State.startupGraceUntilUtc = $Now.AddMinutes($Config.StartupGraceMinutes).ToString('o')
    $waitResult = Wait-CodexHealthyProcesses -Config $Config -InitialPackage $Observation.Package -TimeoutSeconds $Config.RecoveryVerificationSeconds
    $verifiedPackage = $waitResult.Package
    $process = $waitResult.Process
    $databasePaths = Get-CodexDatabasePaths -Config $Config
    $integrity = Test-CodexDatabaseIntegrity -DatabasePaths $databasePaths
    $enrollment = Get-RemoteEnrollmentObservation -DatabasePaths $databasePaths
    $recoveryValidation = Get-RecoveryValidationReport -BeforePackage $Observation.Package -AfterPackage $verifiedPackage -Process $process -Integrity $integrity -Enrollment $enrollment
    $failedValidations = @($recoveryValidation.checks | Where-Object status -eq 'failed')
    $successful = $failedValidations.Count -eq 0

    if ($successful) {
        $State.startupGraceUntilUtc = $null
        $State.failedRecoveryUntilUtc = $null
        $State.appServerMissingSinceUtc = $null
        $State.appServerMissingChecks = 0
        $State.staleCandidates = @()
        $outcome = 'succeeded'
    } else {
        $State.failedRecoveryUntilUtc = $Now.AddMinutes($Config.FailedRecoveryCooldownMinutes).ToString('o')
        $outcome = 'failed'
    }

    Write-WatchdogEvent -Config $Config -Event $Mode -Reason $Decision.Reason -Outcome $outcome `
        -ThreadIds $Decision.ThreadIds -ProcessIds $process.AllPackageProcessIds -PackageVersion $verifiedPackage.Version -Validation $recoveryValidation
    return [ordered]@{
        Attempted        = $true
        LaunchMethod     = $launch.Mode
        Successful       = $successful
        Outcome          = $outcome
        PackageVersionBefore = $Observation.Package.Version
        PackageVersionAfter = $verifiedPackage.Version
        DesktopPresent   = $process.DesktopPresent
        AppServerPresent = $process.AppServerPresent
        IntegrityHealthy = $integrity.Healthy
        EnrollmentStatus = $enrollment.Status
        FailedValidations = @($failedValidations | ForEach-Object name)
        Validation       = $recoveryValidation
    }
}

function Enter-WatchdogMutex {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $name = "Local\CodexRemoteWatchdog-$sid"
    $mutex = [Threading.Mutex]::new($false, $name)
    try {
        $acquired = $mutex.WaitOne(0)
    } catch [Threading.AbandonedMutexException] {
        $acquired = $true
    }
    return [ordered]@{ Mutex = $mutex; Acquired = $acquired }
}

function Exit-WatchdogMutex {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Lock)
    if ($Lock.Acquired) {
        try { $Lock.Mutex.ReleaseMutex() } catch { }
    }
    $Lock.Mutex.Dispose()
}

function Install-WatchdogScheduledTask {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $pwsh = Get-Command pwsh.exe -ErrorAction Stop
    if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
        throw 'sqlite3 must be installed on PATH before the watchdog can be scheduled.'
    }
    if (-not (Test-Path -LiteralPath $Config.ScriptPath -PathType Leaf)) {
        throw "Watchdog script not found at $($Config.ScriptPath)."
    }
    if (-not (Test-Path -LiteralPath $Config.LauncherPath -PathType Leaf)) {
        throw "Hidden watchdog launcher not found at $($Config.LauncherPath)."
    }
    $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
    if (-not (Test-Path -LiteralPath $wscriptPath -PathType Leaf)) {
        throw "Windows Script Host not found at $wscriptPath."
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $sid = $identity.User.Value
    $taskService = New-Object -ComObject 'Schedule.Service'
    $taskService.Connect()
    try {
        [void]$taskService.GetFolder($Config.TaskPath.TrimEnd('\'))
    } catch {
        [void]$taskService.GetFolder('\').CreateFolder($Config.TaskPath.Trim('\'))
    }

    $escape = [Security.SecurityElement]
    $command = $escape::Escape($wscriptPath)
    $launcherPath = $escape::Escape($Config.LauncherPath)
    $pwshPath = $escape::Escape($pwsh.Source)
    $scriptPath = $escape::Escape($Config.ScriptPath)
    $workingDirectory = $escape::Escape((Split-Path -Parent $Config.ScriptPath))
    $author = $escape::Escape($identity.Name)
    $arguments = "//B //NoLogo &quot;$launcherPath&quot; &quot;$pwshPath&quot; &quot;$scriptPath&quot;"
    $date = [DateTimeOffset]::Now.ToString('s')
    $firstScheduledCheck = [DateTimeOffset]::Now.AddMinutes(1).ToString('s')
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$date</Date>
    <Author>$author</Author>
    <Description>Conservative local recovery watchdog for Codex Desktop and Mobile Remote.</Description>
    <URI>$($Config.TaskPath)$($Config.TaskName)</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$sid</UserId>
    </LogonTrigger>
    <TimeTrigger>
      <StartBoundary>$firstScheduledCheck</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
      <Enabled>true</Enabled>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$sid</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <DisallowStartOnRemoteAppSession>false</DisallowStartOnRemoteAppSession>
    <UseUnifiedSchedulingEngine>true</UseUnifiedSchedulingEngine>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT3M</ExecutionTimeLimit>
    <Priority>7</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$command</Command>
      <Arguments>$arguments</Arguments>
      <WorkingDirectory>$workingDirectory</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"@

    Register-ScheduledTask -TaskName $Config.TaskName -TaskPath $Config.TaskPath -Xml $xml -Force | Out-Null
    return Get-ScheduledTask -TaskName $Config.TaskName -TaskPath $Config.TaskPath
}

function Uninstall-WatchdogScheduledTask {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $task = Get-ScheduledTask -TaskName $Config.TaskName -TaskPath $Config.TaskPath -ErrorAction SilentlyContinue
    if ($task) {
        Unregister-ScheduledTask -TaskName $Config.TaskName -TaskPath $Config.TaskPath -Confirm:$false
        return $true
    }
    return $false
}

function ConvertTo-PublicResult {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Decision,
        [System.Collections.IDictionary]$Recovery,
        [switch]$WhatIfMode
    )

    return [ordered]@{
        timestampUtc          = $Observation.TimestampUtc
        action                = if ($WhatIfMode -and $Decision.Action -in @('Launch', 'Restart')) { "Would$($Decision.Action)" } else { $Decision.Action }
        reason                = $Decision.Reason
        packageVersion        = $Observation.Package.Version
        desktopPresent        = $Observation.Process.DesktopPresent
        appServerPresent      = $Observation.Process.AppServerPresent
        rootProcessIds        = @($Observation.Process.RootProcessIds)
        appServerProcessIds   = @($Observation.Process.AppServerProcessIds)
        databaseIntegrity     = $Observation.Integrity
        enrollmentStatus      = $Observation.Enrollment.Status
        remoteFailureCount    = $Observation.Remote.FailureCount
        activeThreads         = @($Observation.Threads | ForEach-Object {
            [ordered]@{
                threadId       = $_.ThreadId
                status         = $_.Status
                lastEventType  = $_.LastEventType
                taskStartedUtc = if ($_.TaskStartedUtc) { ConvertTo-UtcString $_.TaskStartedUtc } else { $null }
                lastProgressUtc = if ($_.LastProgressUtc) { ConvertTo-UtcString $_.LastProgressUtc } else { $null }
            }
        })
        protectedByThreadIds  = @($Decision.ProtectedByThreadIds)
        validation            = $Decision.Validation
        recovery              = $Recovery
        launch                = Get-CodexDesktopLaunchPlan -Package $Observation.Package
    }
}

function Write-WatchdogResult {
    param(
        [Parameter(Mandatory)]$Result,
        [switch]$AsJson
    )

    if ($AsJson) {
        $Result | ConvertTo-Json -Depth 10 -Compress
    } else {
        [pscustomobject]$Result
    }
}

function Invoke-CodexWatchdogMain {
    param(
        [Parameter(Mandatory)][string]$RequestedAction,
        [switch]$AsJson,
        [switch]$WhatIfMode
    )

    $config = Get-WatchdogConfig
    if ($RequestedAction -eq 'Install') {
        if ($WhatIfMode) {
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = 'WouldInstall'; task = "$($config.TaskPath)$($config.TaskName)"; script = $config.ScriptPath })
            return
        }
        $task = Install-WatchdogScheduledTask -Config $config
        Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = 'Installed'; task = "$($task.TaskPath)$($task.TaskName)"; state = $task.State.ToString(); script = $config.ScriptPath })
        return
    }
    if ($RequestedAction -eq 'Uninstall') {
        if ($WhatIfMode) {
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = 'WouldUninstall'; task = "$($config.TaskPath)$($config.TaskName)"; diagnosticsRetained = $true })
            return
        }
        $removed = Uninstall-WatchdogScheduledTask -Config $config
        Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = if ($removed) { 'Uninstalled' } else { 'NotInstalled' }; diagnosticsRetained = $true; dataRoot = $config.DataRoot })
        return
    }

    if ($RequestedAction -eq 'LaunchOnly') {
        # A logon launcher preserves ordinary app-start intent, independently of Remote health.
        $package = Get-CodexPackageInfo -Config $config
        $plan = Get-CodexDesktopLaunchPlan -Package $package -UserHome $config.UserHome
        $process = Get-CodexProcessObservation -Package $package
        if ($plan.Mode -eq 'Native' -and $process.DesktopPresent) {
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{action='None';reason='CodexAlreadyRunning';launch=$plan})
        } elseif ($WhatIfMode) {
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{action='WouldLaunch';reason='LogonLaunchRequested';launch=$plan})
        } else {
            $launch = Start-CodexDesktop -Package $package -LaunchPlan $plan
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{action='LaunchRequested';reason='LogonLaunchRequested';launch=$launch})
        }
        return
    }

    $lock = $null
    if ($RequestedAction -in @('Check', 'Restart')) {
        $lock = Enter-WatchdogMutex
        if (-not $lock.Acquired) {
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = 'Skipped'; reason = 'AnotherWatchdogInstanceIsRunning' })
            Exit-WatchdogMutex -Lock $lock
            return
        }
    }

    try {
        $now = [DateTimeOffset]::UtcNow
        $persistedState = Read-WatchdogState -Config $config
        $workingState = if ($RequestedAction -eq 'Status' -or $WhatIfMode) { Copy-WatchdogState $persistedState } else { $persistedState }
        $observation = Get-CodexObservation -Config $config -State $workingState -Now $now
        if ($RequestedAction -eq 'Restart') {
            $decision = New-WatchdogDecision -Action 'Restart' -Reason 'ManualRestartRequested'
        } else {
            $decision = Get-WatchdogDecision -Observation $observation -State $workingState -Config $config -Now $now
        }
        $decision.Validation = Get-TriggerValidationReport -Decision $decision -Observation $observation -State $workingState -Config $config -Now $now

        $recovery = $null
        if (-not $WhatIfMode -and $RequestedAction -ne 'Status' -and $decision.Action -in @('Launch', 'Restart')) {
            $recovery = Invoke-CodexRecovery -Mode $decision.Action -Config $config -State $workingState -Observation $observation -Decision $decision -Now $now -Automatic:($RequestedAction -eq 'Check')
        }

        if (-not $WhatIfMode -and $RequestedAction -ne 'Status') {
            $workingState.lastCheckUtc = $now.ToString('o')
            $workingState.lastDecision = $decision.Action
            $workingState.lastReason = $decision.Reason
            Save-WatchdogState -Config $config -State $workingState
            Write-WatchdogEvent -Config $config -Event 'Check' -Reason $decision.Reason -Outcome $decision.Action `
                -ThreadIds $decision.ThreadIds -ProcessIds $observation.Process.AllPackageProcessIds -PackageVersion $observation.Package.Version -Validation $decision.Validation
        }

        $result = ConvertTo-PublicResult -Observation $observation -Decision $decision -Recovery $recovery -WhatIfMode:$WhatIfMode
        Write-WatchdogResult -Result $result -AsJson:$AsJson
    } finally {
        if ($lock) { Exit-WatchdogMutex -Lock $lock }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        Invoke-CodexWatchdogMain -RequestedAction $Action -AsJson:$Json -WhatIfMode:$script:WatchdogWhatIfMode
    } catch {
        $errorResult = [ordered]@{
            action    = 'Error'
            reason    = $_.Exception.GetType().Name
            message   = $_.Exception.Message
            timestampUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        Write-WatchdogResult -Result $errorResult -AsJson:$Json
        exit 1
    }
}
