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
        DesktopLogsRoot               = Join-Path $env:LOCALAPPDATA 'Codex\Logs'
        SessionsRoot                  = Join-Path $codexHome 'sessions'
        DataRoot                      = $dataRoot
        StatePath                     = Join-Path $dataRoot 'state.json'
        EventLogPath                  = Join-Path $dataRoot 'watchdog.jsonl'
        SnapshotRoot                  = Join-Path $dataRoot 'snapshots'
        ScriptPath                    = $script:WatchdogScriptPath
        LauncherPath                  = Join-Path $scriptRoot 'CodexWatchdogLauncher.vbs'
        UserHome                      = [Environment]::GetFolderPath('UserProfile')
        InstallRoot                   = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'Programs\CodexWatchdog'
        SourceScriptPath              = $script:WatchdogScriptPath
        SourceLauncherPath            = Join-Path $scriptRoot 'CodexWatchdogLauncher.vbs'
        StartupDirectory              = [Environment]::GetFolderPath('Startup')
        PreDispatchFreezeMinutes      = 3
        ProgressStaleMinutes          = 60
        StaleConfirmationMinutes      = 5
        AppServerMissingMinutes       = 5
        AppServerMissingChecks        = 3
        StartupGraceMinutes           = 5
        RecoveryVerificationSeconds   = 60
        GracefulShutdownSeconds       = 15
        ForceShutdownVerificationSeconds = 5
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

function Test-CodexUtcTimestampEqual {
    param($Left,$Right)

    if ($null -eq $Left -or $null -eq $Right -or
        [string]::IsNullOrWhiteSpace([string]$Left) -or [string]::IsNullOrWhiteSpace([string]$Right)) { return $false }
    try {
        $leftUtc=ConvertTo-UtcDateTimeOffset -Value $Left
        $rightUtc=ConvertTo-UtcDateTimeOffset -Value $Right
        return [bool]($leftUtc.UtcDateTime.Ticks -eq $rightUtc.UtcDateTime.Ticks)
    } catch { return $false }
}

function Test-CodexUtcTimestampAtOrAfter {
    param($Left,$Right)

    if ($null -eq $Left -or $null -eq $Right -or
        [string]::IsNullOrWhiteSpace([string]$Left) -or [string]::IsNullOrWhiteSpace([string]$Right)) { return $false }
    try {
        $leftUtc=ConvertTo-UtcDateTimeOffset -Value $Left
        $rightUtc=ConvertTo-UtcDateTimeOffset -Value $Right
        return [bool]($leftUtc.UtcDateTime.Ticks -ge $rightUtc.UtcDateTime.Ticks)
    } catch { return $false }
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
        lastHealthyCore             = $null
        coreSwitchAttempt           = $null
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
        foreach ($key in @('lastHealthyCore', 'coreSwitchAttempt')) {
            if (-not $state.ContainsKey($key)) { $state[$key] = $null }
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

function Test-CodexPathHasReparsePoint {
    param([Parameter(Mandatory)][string]$Path)

    try {
        $current = [IO.Path]::GetFullPath($Path)
        while ($current) {
            if (Test-Path -LiteralPath $current) {
                $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $true }
            }
            $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
            if (-not $parent -or $parent -ieq $current) { break }
            $current = $parent
        }
        return $false
    } catch {
        return $true
    }
}

function Get-CodexPersistedEnvironmentValue {
    param([Parameter(Mandatory)][ValidateSet('User','Machine')][string]$Source)
    $key = $null
    try {
        if ($Source -eq 'User') {
            $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment',$false)
        } else {
            $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SYSTEM\CurrentControlSet\Control\Session Manager\Environment',$false)
        }
        $effective = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH',$Source)
        if ($key -and $key.GetValueNames() -contains 'CODEX_CLI_PATH') {
            $rawValue = [string]$key.GetValue('CODEX_CLI_PATH',$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind = [string]$key.GetValueKind('CODEX_CLI_PATH')
            if ($kind -eq 'ExpandString') { $effective = [Environment]::ExpandEnvironmentVariables($rawValue) }
            elseif ($null -eq $effective) { $effective = $rawValue }
            return [ordered]@{Value=$effective;RawValue=$rawValue;RegistryKind=$kind}
        }
        return [ordered]@{Value=$effective;RawValue=$effective;RegistryKind=''}
    } catch {
        return [ordered]@{Value=[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH',$Source);RawValue=[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH',$Source);RegistryKind=''}
    }
    finally { if ($key) { $key.Dispose() } }
}

function Test-CodexVersionedCorePath {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$InstallRoot)

    try {
        $fullPath=[IO.Path]::GetFullPath($Path)
        $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($InstallRoot),$fullPath)
        if ([IO.Path]::IsPathRooted($relative) -or @($relative -split '[\\/]') -contains '..') { return $false }
        $parts=@($relative -split '[\\/]')
        return [bool]($parts.Count -eq 4 -and $parts[0] -ieq 'runtime' -and
            $parts[1] -and $parts[2] -ieq 'bin' -and $parts[3] -ieq 'codex.exe')
    } catch { return $false }
}

function Resolve-CodexManifestDeclaredCorePath {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$VersionDirectory
    )

    $declared=[string]$Manifest.coreRelativePath
    if ([string]::IsNullOrWhiteSpace($declared) -or [IO.Path]::IsPathRooted($declared) -or
        (@($declared -split '[\\/]') -contains '..')) { return '' }
    foreach ($base in @($InstallRoot,$VersionDirectory)) {
        try {
            $candidate=[IO.Path]::GetFullPath((Join-Path $base $declared.Replace('/',[IO.Path]::DirectorySeparatorChar)))
            if (Test-CodexVersionedCorePath -Path $candidate -InstallRoot $InstallRoot) { return $candidate }
        } catch { }
    }
    return ''
}

function Get-CodexManifestCoreHash {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Manifest,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$VersionDirectory
    )

    if (-not ($Manifest.validation -is [System.Collections.IDictionary]) -or $Manifest.validation.passed -ne $true) {
        throw 'The managed core metadata has not passed validation.'
    }
    $declaredPath=Resolve-CodexManifestDeclaredCorePath -Manifest $Manifest -InstallRoot $InstallRoot -VersionDirectory $VersionDirectory
    if (-not $declaredPath -or $declaredPath -ine [IO.Path]::GetFullPath($ExecutablePath)) {
        throw 'The managed core metadata does not declare this core path.'
    }
    $matches=@()
    foreach ($component in @($Manifest.components)) {
        $relativePath=[string]$component.relativePath
        $componentHash=[string]$component.sha256
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or
            (@($relativePath -split '[\\/]') -contains '..')) { continue }
        foreach ($base in @($InstallRoot,$VersionDirectory)) {
            try {
                $candidate=[IO.Path]::GetFullPath((Join-Path $base $relativePath.Replace('/',[IO.Path]::DirectorySeparatorChar)))
                if ($candidate -ieq [IO.Path]::GetFullPath($ExecutablePath)) { $matches += $componentHash.ToUpperInvariant() }
            } catch { }
        }
    }
    $uniqueHashes=@($matches | Select-Object -Unique)
    if ($uniqueHashes.Count -ne 1 -or $uniqueHashes[0] -notmatch '^[A-F0-9]{64}$') {
        throw 'The managed core metadata is missing a unique SHA-256 component entry.'
    }
    if (-not (Test-Path -LiteralPath $ExecutablePath -PathType Leaf) -or (Test-CodexPathHasReparsePoint -Path $ExecutablePath)) {
        throw 'The managed core file is missing or contains a reparse point.'
    }
    $actualHash=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
    if ($actualHash -cne $uniqueHashes[0]) { throw 'The managed core hash does not match its validation metadata.' }
    return [string]$uniqueHashes[0]
}

function Find-CodexArchivedCoreManifest {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$VersionDirectory,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    $archiveRoot=Join-Path $InstallRoot 'temp'
    if (-not (Test-Path -LiteralPath $archiveRoot -PathType Container) -or (Test-CodexPathHasReparsePoint -Path $archiveRoot)) { return '' }
    $archives=@(Get-ChildItem -LiteralPath $archiveRoot -Directory -Filter 'previous-package-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 16)
    foreach ($archive in $archives) {
        if (Test-CodexPathHasReparsePoint -Path $archive.FullName) { continue }
        $manifestPath=Join-Path $archive.FullName 'manifest.json'
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) { continue }
        if (Test-CodexPathHasReparsePoint -Path $manifestPath) { continue }
        try {
            $manifest=Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 16 -ErrorAction Stop
        } catch {
            throw 'A previous-package manifest is corrupt; historical core trust is unavailable.'
        }
        if (-not ($manifest -is [System.Collections.IDictionary])) {
            throw 'A previous-package manifest is malformed; historical core trust is unavailable.'
        }
        $declaredPath=Resolve-CodexManifestDeclaredCorePath -Manifest $manifest -InstallRoot $InstallRoot -VersionDirectory $VersionDirectory
        if (-not $declaredPath -or $declaredPath -ine [IO.Path]::GetFullPath($ExecutablePath)) { continue }
        # Once metadata claims this exact executable, any validation or hash failure is final.
        $null=Get-CodexManifestCoreHash -Manifest $manifest -ExecutablePath $ExecutablePath -InstallRoot $InstallRoot -VersionDirectory $VersionDirectory
        return $manifestPath
    }
    return ''
}

function Get-CodexManagedCoreIdentity {
    <# Resolves a versioned runtime core through its nearest validated publisher manifest. #>
    param(
        [Parameter(Mandatory)][string]$ExecutablePath,
        [switch]$SkipHashVerification
    )

    $identity = [ordered]@{
        Managed = $false
        Valid = $false
        HashVerified = $false
        Executable = ''
        Version = ''
        Sha256 = ''
        MetadataPath = ''
        Error = $null
    }
    try {
        if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath)) { throw 'The configured codex.exe path must be absolute.' }
        $path = [IO.Path]::GetFullPath($ExecutablePath)
        if ([IO.Path]::GetFileName($path) -ine 'codex.exe') { throw 'CODEX_CLI_PATH must name codex.exe.' }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The configured codex.exe does not exist.' }
        if (Test-CodexPathHasReparsePoint -Path $path) { throw 'The configured core path contains a reparse point.' }

        $binDirectory = [IO.DirectoryInfo]::new([IO.Path]::GetDirectoryName($path))
        if ($binDirectory.Name -ine 'bin' -or $null -eq $binDirectory.Parent -or $null -eq $binDirectory.Parent.Parent -or
            $binDirectory.Parent.Parent.Name -ine 'runtime' -or $null -eq $binDirectory.Parent.Parent.Parent) {
            return $identity
        }

        $versionDirectory = $binDirectory.Parent
        $runtimeDirectory = $versionDirectory.Parent
        $installRoot = $runtimeDirectory.Parent
        $identity.Managed = $true
        $identity.Executable = $path
        foreach ($directory in @($binDirectory, $versionDirectory, $runtimeDirectory, $installRoot)) {
            if (-not (Test-Path -LiteralPath $directory.FullName -PathType Container) -or
                (Test-CodexPathHasReparsePoint -Path $directory.FullName)) {
                throw 'The managed core directory chain is missing or contains a reparse point.'
            }
        }

        $versionReceipt = @(
            (Join-Path $versionDirectory.FullName '.capacity-manifest.json'),
            (Join-Path $versionDirectory.FullName 'manifest.json'),
            (Join-Path $versionDirectory.FullName 'receipt.json')
        ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
        $rootManifest = Join-Path $installRoot.FullName 'manifest.json'
        $metadataPath = if ($versionReceipt) { [string]$versionReceipt } elseif (Test-Path -LiteralPath $rootManifest -PathType Leaf) { $rootManifest } else { '' }
        if (-not $metadataPath) { throw 'A versioned runtime core is missing its validation manifest.' }
        if (-not $versionReceipt -and $metadataPath -ieq $rootManifest) {
            if (Test-CodexPathHasReparsePoint -Path $rootManifest) { throw 'The managed core metadata path contains a reparse point.' }
            $currentManifest=Get-Content -LiteralPath $rootManifest -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 16 -ErrorAction Stop
            if (-not ($currentManifest -is [System.Collections.IDictionary]) -or
                -not ($currentManifest.validation -is [System.Collections.IDictionary]) -or
                $currentManifest.validation.passed -ne $true) {
                throw 'The managed core metadata has not passed validation.'
            }
            $rootDeclaredCore=Resolve-CodexManifestDeclaredCorePath -Manifest $currentManifest -InstallRoot $installRoot.FullName -VersionDirectory $versionDirectory.FullName
            if (-not $rootDeclaredCore) { throw 'The root manifest does not declare a versioned core in this installation.' }
            if ($rootDeclaredCore -ine $path) {
                $currentVersionDirectory=[IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($rootDeclaredCore))
                if (-not (Test-CodexVersionedCorePath -Path $rootDeclaredCore -InstallRoot $installRoot.FullName)) {
                    throw 'The root manifest does not declare a versioned core in this installation.'
                }
                $null=Get-CodexManifestCoreHash -Manifest $currentManifest -ExecutablePath $rootDeclaredCore -InstallRoot $installRoot.FullName -VersionDirectory $currentVersionDirectory
                $archivedManifest=Find-CodexArchivedCoreManifest -InstallRoot $installRoot.FullName -VersionDirectory $versionDirectory.FullName -ExecutablePath $path
                if (-not $archivedManifest) { throw 'The selected historical core has no matching validated package manifest.' }
                $metadataPath=$archivedManifest
            }
        }
        $identity.MetadataPath = $metadataPath
        if (Test-CodexPathHasReparsePoint -Path $metadataPath) { throw 'The managed core metadata path contains a reparse point.' }

        $manifest = Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable -Depth 16 -ErrorAction Stop
        if (-not ($manifest -is [System.Collections.IDictionary]) -or
            -not ($manifest.validation -is [System.Collections.IDictionary]) -or
            $manifest.validation.passed -ne $true) {
            throw 'The managed core metadata has not passed validation.'
        }

        $rootRelativePath = [IO.Path]::GetRelativePath($installRoot.FullName, $path).Replace('\', '/')
        $versionRelativePath = [IO.Path]::GetRelativePath($versionDirectory.FullName, $path).Replace('\', '/')
        $declaredCore = [string]$manifest.coreRelativePath
        $declaredCoreMatches = $false
        if (-not [string]::IsNullOrWhiteSpace($declaredCore) -and
            -not [IO.Path]::IsPathRooted($declaredCore) -and
            (@($declaredCore -split '[\\/]') -notcontains '..')) {
            foreach ($base in @($installRoot.FullName, $versionDirectory.FullName)) {
                $candidate = [IO.Path]::GetFullPath((Join-Path $base $declaredCore.Replace('/', [IO.Path]::DirectorySeparatorChar)))
                if ($candidate -ieq $path) { $declaredCoreMatches = $true; break }
            }
        }
        if (-not $declaredCoreMatches) { throw 'The managed core metadata does not declare this core path.' }

        $components = @($manifest.components)
        $matches = @()
        foreach ($component in $components) {
            $relativePath = [string]$component.relativePath
            $componentHash = [string]$component.sha256
            if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or
                (@($relativePath -split '[\\/]') -contains '..')) { continue }
            foreach ($base in @($installRoot.FullName, $versionDirectory.FullName)) {
                $candidate = [IO.Path]::GetFullPath((Join-Path $base $relativePath.Replace('/', [IO.Path]::DirectorySeparatorChar)))
                if ($candidate -ieq $path) {
                    $matches += [pscustomobject]@{ Path=$candidate; Sha256=$componentHash }
                }
            }
        }
        $expectedHashes = @($matches | ForEach-Object { [string]$_.Sha256.ToUpperInvariant() } | Select-Object -Unique)
        if ($expectedHashes.Count -ne 1 -or $expectedHashes[0] -notmatch '^[A-F0-9]{64}$') {
            throw 'The managed core metadata is missing a unique SHA-256 component entry.'
        }
        $identity.Sha256 = $expectedHashes[0]
        $identity.Version = if ($manifest.localVersion) { [string]$manifest.localVersion } elseif ($manifest.version) { [string]$manifest.version } else { $versionDirectory.Name }
        if (-not $SkipHashVerification) {
            $actualHash = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            if ($actualHash -cne $identity.Sha256) { throw 'The managed core hash does not match its validation metadata.' }
            $identity.HashVerified = $true
        }
        $identity.Valid = $true
        return $identity
    } catch {
        $identity.Executable = ''
        $identity.Error = $_.Exception.Message
        return $identity
    }
}

function Get-CodexAppServerOverride {
    <# Persisted User settings take precedence over Machine settings. The inherited Process value is intentionally ignored. #>
    param(
        [System.Collections.IDictionary]$EnvironmentValues,
        [switch]$SkipHashVerification
    )

    $readHostValues = -not $PSBoundParameters.ContainsKey('EnvironmentValues')
    if ($readHostValues) {
        $userSelection = Get-CodexPersistedEnvironmentValue -Source User
        $machineSelection = Get-CodexPersistedEnvironmentValue -Source Machine
        $EnvironmentValues = [ordered]@{
            User = $userSelection.Value
            Machine = $machineSelection.Value
            UserRawValue = $userSelection.RawValue
            UserKind = $userSelection.RegistryKind
            MachineRawValue = $machineSelection.RawValue
            MachineKind = $machineSelection.RegistryKind
        }
    }
    foreach ($source in @('User', 'Machine')) {
        $value = [string]$EnvironmentValues[$source]
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        try {
            if (-not [IO.Path]::IsPathFullyQualified($value) -or [IO.Path]::GetFileName($value) -ine 'codex.exe') {
                throw 'CODEX_CLI_PATH must be an absolute path to codex.exe.'
            }
            $path = [IO.Path]::GetFullPath($value)
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'The configured codex.exe does not exist.' }
            if (Test-CodexPathHasReparsePoint -Path $path) { throw 'The configured core path contains a reparse point.' }
            $identity = Get-CodexManagedCoreIdentity -ExecutablePath $path -SkipHashVerification:$SkipHashVerification
            if ($identity.Managed -and -not $identity.Valid) { throw $identity.Error }
            return [ordered]@{
                Executable = $path
                Source = $source
                Error = $null
                Managed = [bool]$identity.Managed
                MetadataValidated = [bool]$identity.Valid
                HashVerified = [bool]$identity.HashVerified
                Sha256 = [string]$identity.Sha256
                Version = [string]$identity.Version
                MetadataPath = [string]$identity.MetadataPath
                RawValue = if ($readHostValues) { [string]$EnvironmentValues["${source}RawValue"] } elseif ($EnvironmentValues.Contains("${source}RawValue")) { [string]$EnvironmentValues["${source}RawValue"] } else { $value }
                RegistryKind = [string]$EnvironmentValues["${source}Kind"]
            }
        } catch {
            return [ordered]@{ Executable=''; Source=$source; Error=$_.Exception.Message; Managed=$false; MetadataValidated=$false; HashVerified=$false; Sha256=''; Version=''; MetadataPath=''; RawValue=$value; RegistryKind='' }
        }
    }
    return [ordered]@{ Executable=''; Source='None'; Error=$null; Managed=$false; MetadataValidated=$false; HashVerified=$false; Sha256=''; Version=''; MetadataPath=''; RawValue=''; RegistryKind='' }
}

function Get-CodexPackageInfo {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config,[switch]$SkipCoreHashVerification)

    $appServerOverride = if ($SkipCoreHashVerification) {
        Get-CodexAppServerOverride -SkipHashVerification
    } else {
        Get-CodexAppServerOverride
    }

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
            AppServerOverride   = $appServerOverride
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
        AppServerOverride   = $appServerOverride
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

function Get-CodexRootAncestorId {
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][int[]]$RootIds,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ProcessById
    )

    $currentId = $ProcessId
    $seen = @{}
    for ($depth = 0; $depth -lt 20; $depth++) {
        if ($RootIds -contains $currentId) { return $currentId }
        if ($seen.ContainsKey($currentId) -or -not $ProcessById.Contains($currentId)) { return $null }
        $seen[$currentId] = $true
        $currentId = [int]$ProcessById[$currentId].ParentProcessId
    }
    return $null
}

function Test-CodexStockAppServerExecutablePath {
    <# .SYNOPSIS Accepts the bundled stock core or its verified fixed-format cache copy. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    try {
        if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath) -or
            [IO.Path]::GetFileName($ExecutablePath) -ine 'codex.exe' -or -not $Package.AppServerExecutable) { return $false }
        $candidatePath=[IO.Path]::GetFullPath($ExecutablePath)
        $bundledPath=[IO.Path]::GetFullPath([string]$Package.AppServerExecutable)
        if ($candidatePath -ieq $bundledPath) { return $true }

        $binRoot=[string](Get-JsonPropertyValue -Object $Package -Name 'AppServerBinRoot')
        if (-not $binRoot -or -not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -or
            (Test-CodexPathHasReparsePoint -Path $candidatePath)) { return $false }
        $relative=[IO.Path]::GetRelativePath([IO.Path]::GetFullPath($binRoot),$candidatePath)
        if ([IO.Path]::IsPathRooted($relative) -or $relative -notmatch '^[A-Fa-f0-9]{16}[\\/]codex\.exe$') { return $false }

        $cacheFile=Get-Item -LiteralPath $candidatePath -Force -ErrorAction Stop
        $bundledFile=Get-Item -LiteralPath $bundledPath -Force -ErrorAction Stop
        if ($cacheFile.PSIsContainer -or $bundledFile.PSIsContainer -or $cacheFile.Length -le 0 -or $cacheFile.Length -ne $bundledFile.Length) { return $false }
        if (Test-CodexPathHasReparsePoint -Path $bundledPath) { return $false }
        $cacheHash=(Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        $bundledHash=(Get-FileHash -LiteralPath $bundledPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
        return [bool]($cacheHash -ceq $bundledHash)
    } catch { return $false }
}

function Test-CodexAppServerExecutablePath {
    <# .SYNOPSIS Accepts the current persisted override or stock core when stock is selected. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][string]$ExecutablePath
    )

    try {
        if (-not [IO.Path]::IsPathFullyQualified($ExecutablePath)) { return $false }
        $candidatePath = [IO.Path]::GetFullPath($ExecutablePath)
        if ([IO.Path]::GetFileName($candidatePath) -ine 'codex.exe') {
            return $false
        }
        $override=Get-JsonPropertyValue -Object $Package -Name 'AppServerOverride'
        if ($override -and $override.Error) { return $false }
        $overridePath=[string](Get-JsonPropertyValue -Object $override -Name 'Executable')
        if (-not $overridePath) { return Test-CodexStockAppServerExecutablePath -Package $Package -ExecutablePath $candidatePath }
        if ($candidatePath -ine $overridePath -or
            -not (Test-Path -LiteralPath $candidatePath -PathType Leaf) -or
            (Test-CodexPathHasReparsePoint -Path $candidatePath)) { return $false }
        if ($override.Managed) {
            return [bool]($override.MetadataValidated -and $override.HashVerified)
        }
        # Compatibility for a directly selected, unmanaged exact path is retained,
        # but it is never eligible for automatic core-switch recovery.
        return $true
    } catch {
        return $false
    }
}

function Get-CodexProcessObservation {
    <# .SYNOPSIS Identifies selected, trusted-previous, stock, and unknown app servers. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [object[]]$Processes,
        [System.Collections.IDictionary]$TrustedPreviousCore
    )

    if (-not $Package.Found) {
        return [ordered]@{
            DesktopPresent      = $false
            AppServerPresent    = $false
            AppServerStatus     = 'Missing'
            UnknownAppServerProcessIds = @()
            UnknownAppServerExecutables = @()
            RootProcessIds      = @()
            RootProcessIdentities = @()
            AppServerProcessIds = @()
            AppServerProcessIdentities = @()
            SelectedCorePresent = $false
            TrustedPreviousCorePresent = $false
            CoreSwitchPending = $false
            CoreSelection = [ordered]@{ Kind='Unavailable'; Path=''; Sha256=''; Version=''; Source='None'; Managed=$false; HashVerified=$false }
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
    $rootIdentities = @($rootProcesses | ForEach-Object {
        [ordered]@{
            processId = [int]$_.ProcessId
            startedUtc = if ($_.CreationDate) { ConvertTo-UtcString $_.CreationDate } else { '' }
            executablePath = [string]$_.ExecutablePath
        }
    })

    $override = if ($Package.Contains('AppServerOverride')) { $Package.AppServerOverride } else { $null }
    $coreSelection = if ($override -and $override.Error) {
        [ordered]@{ Kind='Invalid'; Path=''; Sha256=''; Version=''; Source=[string]$override.Source; Managed=$false; HashVerified=$false }
    } elseif ($override -and $override.Executable) {
        [ordered]@{
            Kind = if ($override.Managed) { 'Managed' } else { 'Legacy' }
            Path = [string]$override.Executable
            Sha256 = [string]$override.Sha256
            Version = [string]$override.Version
            Source = [string]$override.Source
            Managed = [bool]$override.Managed
            HashVerified = [bool]$override.HashVerified
            RawValue = [string](Get-JsonPropertyValue -Object $override -Name 'RawValue')
        }
    } else {
        [ordered]@{
            Kind = 'Stock'
            Path = [string]$Package.AppServerExecutable
            Sha256 = ''
            Version = if ($Package.Contains('Version')) { [string]$Package.Version } else { '' }
            Source = 'None'
            Managed = $false
            HashVerified = $true
            RawValue = ''
        }
    }

    $appServerRoleProcesses = @($Processes | Where-Object {
        $_.Name -ieq 'codex.exe' -and
        ((Get-JsonPropertyValue -Object $_ -Name 'CommandLine') -match '(?i)(?:^|\s)app-server(?:\s|$)' -or
         [string]::IsNullOrWhiteSpace([string](Get-JsonPropertyValue -Object $_ -Name 'CommandLine')))
    })
    $appServerIdentities = @()
    $selectedIds = @()
    $previousIds = @()
    $unknownAppServers = @()
    $previousCore = $TrustedPreviousCore
    $previousCoreRecord = if ($previousCore -and $previousCore.Contains('core')) { $previousCore.core } else { $null }
    $previousProcessRecord = if ($previousCore -and $previousCore.Contains('process')) { $previousCore.process } else { $null }
    $previousDiffersFromSelected = $false
    if ($previousCoreRecord -and $coreSelection.Path -and
        ([string]$previousCoreRecord.path -ine [string]$coreSelection.Path -or
         ([string]$previousCoreRecord.sha256).ToUpperInvariant() -cne ([string]$coreSelection.Sha256).ToUpperInvariant())) {
        $previousDiffersFromSelected = $true
    } elseif ($previousCoreRecord -and $coreSelection.Kind -eq 'Stock' -and
        [string]$previousCoreRecord.path -ine [string]$coreSelection.Path) {
        $previousDiffersFromSelected = $true
    }

    foreach ($process in $appServerRoleProcesses) {
        $processId = [int]$process.ProcessId
        $processCreationDate = Get-JsonPropertyValue -Object $process -Name 'CreationDate'
        $isDescendant = $rootIds.Count -gt 0 -and
            (Test-ProcessDescendsFrom -ProcessId ([int]$process.ParentProcessId) -AncestorIds $rootIds -ProcessById $processById)
        $hasServerRole = [string](Get-JsonPropertyValue -Object $process -Name 'CommandLine') -match '(?i)(?:^|\s)app-server(?:\s|$)'
        $desktopAncestorId = if ($isDescendant) {
            Get-CodexRootAncestorId -ProcessId ([int]$process.ParentProcessId) -RootIds $rootIds -ProcessById $processById
        } else { $null }
        $desktopIdentity = $rootIdentities | Where-Object { [int]$_.processId -eq [int]$desktopAncestorId } | Select-Object -First 1
        $serverStartedAfterDesktop = $desktopIdentity -and $processCreationDate -and
            (Test-CodexUtcTimestampAtOrAfter -Left $processCreationDate -Right $desktopIdentity.startedUtc)
        $isDescendant = [bool]($isDescendant -and $serverStartedAfterDesktop)
        $isDirectDesktopChild = [bool]($desktopIdentity -and [int]$process.ParentProcessId -eq [int]$desktopIdentity.processId)
        $isSelected = $isDescendant -and $hasServerRole -and $process.ExecutablePath -and
            (Test-CodexAppServerExecutablePath -Package $Package -ExecutablePath ([string]$process.ExecutablePath))
        $previousProcessPath = [string](Get-JsonPropertyValue -Object $previousProcessRecord -Name 'executablePath')
        if (-not $previousProcessPath -and $previousCoreRecord) { $previousProcessPath = [string]$previousCoreRecord.path }
        $isCachedStockPath = $false
        if ($process.ExecutablePath -and $coreSelection.Kind -eq 'Stock') {
            try {
                $isCachedStockPath = [IO.Path]::GetFullPath([string]$process.ExecutablePath) -ine
                    [IO.Path]::GetFullPath([string]$Package.AppServerExecutable)
            } catch { $isCachedStockPath = $false }
        }
        if ($isSelected -and $isCachedStockPath -and -not $isDirectDesktopChild) { $isSelected = $false }
        $isCachedPreviousStockPath = $false
        if ($previousCoreRecord -and [string]$previousCoreRecord.kind -eq 'Stock' -and $previousProcessPath) {
            try {
                $isCachedPreviousStockPath = [IO.Path]::GetFullPath($previousProcessPath) -ine
                    [IO.Path]::GetFullPath([string]$Package.AppServerExecutable)
            } catch { $isCachedPreviousStockPath = $false }
        }
        $isTrustedPrevious = $false
        if (-not $isSelected -and $isDescendant -and $previousDiffersFromSelected -and $previousCoreRecord -and $previousProcessRecord -and
            (-not $isCachedPreviousStockPath -or $isDirectDesktopChild) -and
            [int]$previousProcessRecord.pid -eq $processId -and
            $previousProcessPath -and $process.ExecutablePath -ieq $previousProcessPath -and
            $previousProcessRecord.startUtc -and $processCreationDate -and $desktopIdentity -and
            [int]$previousProcessRecord.desktopPid -eq [int]$desktopIdentity.processId -and
            (Test-CodexUtcTimestampEqual -Left $previousProcessRecord.desktopStartUtc -Right $desktopIdentity.startedUtc)) {
            try {
                $isTrustedPrevious = Test-CodexUtcTimestampEqual -Left $processCreationDate -Right $previousProcessRecord.startUtc
                if ($isTrustedPrevious -and [string]$previousCoreRecord.kind -eq 'Managed') {
                    if (-not [string]$previousCoreRecord.sha256 -or $process.ExecutablePath -ine [string]$previousCoreRecord.path -or
                        (Test-CodexPathHasReparsePoint -Path ([string]$process.ExecutablePath))) {
                        $isTrustedPrevious = $false
                    } else {
                        $actualPreviousHash = (Get-FileHash -LiteralPath ([string]$process.ExecutablePath) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
                        $isTrustedPrevious = $actualPreviousHash -ceq ([string]$previousCoreRecord.sha256).ToUpperInvariant()
                    }
                } elseif ($isTrustedPrevious -and [string]$previousCoreRecord.kind -eq 'Stock') {
                    $isTrustedPrevious = Test-CodexStockAppServerExecutablePath -Package $Package -ExecutablePath ([string]$process.ExecutablePath)
                } else {
                    # A prior unmanaged exact override can still be recognized while
                    # selected, but it does not authorize an automatic core switch.
                    $isTrustedPrevious = $false
                }
            } catch {
                $isTrustedPrevious = $false
            }
        }

        if ($isSelected -or $isTrustedPrevious) {
            $classification = if ($isTrustedPrevious) { 'TrustedPrevious' } elseif ($coreSelection.Kind -eq 'Stock') { 'Stock' } elseif ($coreSelection.Kind -eq 'Legacy') { 'Legacy' } else { 'Selected' }
            $serverIdentity = [ordered]@{
                processId = $processId
                parentProcessId = [int]$process.ParentProcessId
                startedUtc = if ($processCreationDate) { ConvertTo-UtcString $processCreationDate } else { '' }
                executablePath = [string]$process.ExecutablePath
                desktopProcessId = if ($desktopIdentity) { [int]$desktopIdentity.processId } else { 0 }
                desktopStartedUtc = if ($desktopIdentity) { [string]$desktopIdentity.startedUtc } else { '' }
                coreKind = if ($isTrustedPrevious) { [string]$previousCoreRecord.kind } else { [string]$coreSelection.Kind }
                coreSha256 = if ($isTrustedPrevious) { [string]$previousCoreRecord.sha256 } else { [string]$coreSelection.Sha256 }
                coreVersion = if ($isTrustedPrevious) { [string]$previousCoreRecord.version } else { [string]$coreSelection.Version }
                classification = $classification
            }
            $appServerIdentities += $serverIdentity
            if ($isSelected) { $selectedIds += $processId }
            if ($isTrustedPrevious) { $previousIds += $processId }
        } elseif ([int]$process.ParentProcessId -in $rootIds) {
            # Unknown direct children block recovery; nested CLI/tool processes do not.
            $unknownAppServers += $process
        }
    }
    $appServerIds = @($appServerIdentities | ForEach-Object { [int]$_.processId } | Select-Object -Unique)

    $allPackageIds = @(@($rootIds) + @($appServerIds) | Select-Object -Unique)
    $rootStartTimes = @($rootProcesses | ForEach-Object {
        $value = Get-JsonPropertyValue -Object $_ -Name 'CreationDate'
        if ($value) { ConvertTo-UtcDateTimeOffset $value }
    } | Sort-Object)
    $appServerStartTimes = @($appServerIdentities | Where-Object { $_.startedUtc } | ForEach-Object {
        ConvertTo-UtcDateTimeOffset $_.startedUtc
    } | Sort-Object)

    return [ordered]@{
        DesktopPresent       = $rootIds.Count -gt 0
        AppServerPresent     = $appServerIds.Count -gt 0
        AppServerStatus      = if ($unknownAppServers.Count -gt 0) { 'Unknown' } elseif ($appServerIds.Count -gt 0) { 'Recognized' } else { 'Missing' }
        UnknownAppServerProcessIds = @($unknownAppServers | ForEach-Object { [int]$_.ProcessId })
        UnknownAppServerExecutables = @($unknownAppServers | ForEach-Object { [string]$_.ExecutablePath })
        RootProcessIds       = $rootIds
        RootProcessIdentities = $rootIdentities
        AppServerProcessIds  = $appServerIds
        AppServerProcessIdentities = $appServerIdentities
        SelectedCorePresent = $selectedIds.Count -gt 0
        TrustedPreviousCorePresent = $previousIds.Count -gt 0
        CoreSwitchPending = [bool]($previousDiffersFromSelected -and $coreSelection.Managed -and $rootIds.Count -gt 0 -and
            ($previousIds.Count -gt 0 -or $selectedIds.Count -eq 0))
        CoreSelection = $coreSelection
        AllPackageProcessIds = $allPackageIds
        RootStartedUtc       = if ($rootStartTimes.Count -gt 0) { $rootStartTimes[0] } else { $null }
        AppServerStartedUtc  = if ($appServerStartTimes.Count -gt 0) { $appServerStartTimes[0] } else { $null }
    }
}

function Get-VerifiedCodexProcessHandle {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Identity)

    $handle = $null
    try {
        $processId = [int](Get-JsonPropertyValue -Object $Identity -Name 'processId')
        $startedUtc = Get-JsonPropertyValue -Object $Identity -Name 'startedUtc'
        $executablePath = [string](Get-JsonPropertyValue -Object $Identity -Name 'executablePath')
        $coreKind = [string](Get-JsonPropertyValue -Object $Identity -Name 'coreKind')
        $coreSha256 = [string](Get-JsonPropertyValue -Object $Identity -Name 'coreSha256')
        if ($processId -le 0 -or -not $startedUtc -or -not $executablePath) { return $null }

        $fresh = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
        if (-not $fresh -or [int]$fresh.ProcessId -ne $processId -or
            -not $fresh.ExecutablePath -or [string]$fresh.ExecutablePath -ine $executablePath -or
            -not $fresh.CreationDate -or -not (Test-CodexUtcTimestampEqual -Left $fresh.CreationDate -Right $startedUtc)) { return $null }
        if ($coreKind -eq 'Managed') {
            if (-not $coreSha256 -or (Test-CodexPathHasReparsePoint -Path $executablePath) -or
                (Get-FileHash -LiteralPath $executablePath -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant() -cne $coreSha256.ToUpperInvariant()) { return $null }
        }
        $handle = Get-Process -Id $processId -ErrorAction Stop
        $safeHandle = $handle.SafeHandle
        if (-not $safeHandle -or $safeHandle.IsInvalid -or $safeHandle.IsClosed) {
            $handle.Dispose()
            $handle = $null
            return $null
        }

        $handleStartTime = $handle.StartTime
        if (-not $handleStartTime -or
            [Math]::Abs(($handleStartTime.ToUniversalTime() - (ConvertTo-UtcDateTimeOffset $startedUtc).UtcDateTime).TotalSeconds) -gt 2) {
            $handle.Dispose()
            $handle = $null
            return $null
        }

        # Recheck the live PID after materializing the retained process handle.
        # This closes the gap where it could exit and be reused between the first
        # CIM lookup and Get-Process, while later actions use the same wrapper.
        $freshAfterOpen = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $processId" -ErrorAction Stop
        if (-not $freshAfterOpen -or [int]$freshAfterOpen.ProcessId -ne $processId -or
            -not $freshAfterOpen.ExecutablePath -or [string]$freshAfterOpen.ExecutablePath -ine $executablePath -or
            -not $freshAfterOpen.CreationDate -or
            -not (Test-CodexUtcTimestampEqual -Left $freshAfterOpen.CreationDate -Right $startedUtc)) {
            $handle.Dispose()
            $handle = $null
            return $null
        }
        return $handle
    } catch {
        if ($handle) { try { $handle.Dispose() } catch { } }
        return $null
    }
}

function Get-FreshSafeCodexProcessIdentity {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Identity,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$TrustedPreviousCore,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedCore
    )

    $package = Get-CodexPackageInfo -Config $Config
    if (-not $package.Found) { throw 'Codex disappeared before the process could be acted on.' }
    $selection = Get-CodexDesiredCoreIdentity -Package $package
    if (-not (Test-CodexCoreSelectionMatches -Actual $selection -Expected $ExpectedCore)) {
        throw 'The persisted core selection changed before the process could be acted on.'
    }
    $observation = Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
    if ($observation.AppServerStatus -eq 'Unknown') {
        throw 'An unrecognized live Codex app-server was found; refusing to close or stop the application.'
    }
    $identities = @($observation.RootProcessIdentities) + @($observation.AppServerProcessIdentities)
    return $identities | Where-Object {
        $observedKind = [string](Get-JsonPropertyValue -Object $_ -Name 'coreKind')
        $observedHash = [string](Get-JsonPropertyValue -Object $_ -Name 'coreSha256')
        $expectedHash = [string](Get-JsonPropertyValue -Object $Identity -Name 'coreSha256')
        [int]$_.processId -eq [int]$Identity.processId -and
        [string]$_.startedUtc -ceq [string]$Identity.startedUtc -and
        [string]$_.executablePath -ieq [string]$Identity.executablePath -and
        ($observedKind -cne 'Managed' -or $observedHash.ToUpperInvariant() -ceq $expectedHash.ToUpperInvariant())
    } | Select-Object -First 1
}

function Test-CodexCoreSelectionMatches {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Actual,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Expected
    )

    if (-not $Actual.Path -or -not $Expected.Path -or [string]$Actual.Path -ine [string]$Expected.Path) { return $false }
    if ([string]$Actual.Source -cne [string]$Expected.Source) { return $false }
    if ([bool]$Expected.Managed) {
        return [bool]($Actual.Managed -and $Actual.HashVerified -and $Expected.HashVerified -and
            [string]$Actual.Sha256 -match '^[A-Fa-f0-9]{64}$' -and
            ([string]$Actual.Sha256).ToUpperInvariant() -ceq ([string]$Expected.Sha256).ToUpperInvariant())
    }
    return [bool](-not $Actual.Managed -and ([string]$Actual.Sha256).ToUpperInvariant() -ceq ([string]$Expected.Sha256).ToUpperInvariant())
}

function Test-CodexCoreSelectionMatchesRecord {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Selection,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [string]$Source
    )

    $recordPath = [string](Get-JsonPropertyValue -Object $Record -Name 'path')
    $recordHash = [string](Get-JsonPropertyValue -Object $Record -Name 'sha256')
    $recordSource = [string](Get-JsonPropertyValue -Object $Record -Name 'source')
    $recordKind = [string](Get-JsonPropertyValue -Object $Record -Name 'kind')
    if (-not $recordPath -or [string]$Selection.Path -ine $recordPath -or
        ([string]$Selection.Sha256).ToUpperInvariant() -cne $recordHash.ToUpperInvariant()) { return $false }
    if ($recordSource -and [string]$Selection.Source -cne $recordSource) { return $false }
    if ($Source -and [string]$Selection.Source -cne $Source) { return $false }
    if ($recordKind -and [string]$Selection.Kind -cne $recordKind) { return $false }
    return $true
}

function Assert-CodexShutdownProcessSet {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CapturedByProcessId
    )

    if ($Observation.AppServerStatus -eq 'Unknown') {
        throw 'An unrecognized live Codex app-server appeared during shutdown.'
    }

    $currentIdentities = @($Observation.RootProcessIdentities) + @($Observation.AppServerProcessIdentities)
    if ($currentIdentities.Count -ne @($Observation.AllPackageProcessIds).Count) {
        throw 'A live Codex process no longer has a complete verified identity; refusing to launch another instance.'
    }
    foreach ($identity in $currentIdentities) {
        $processId = [int](Get-JsonPropertyValue -Object $identity -Name 'processId')
        if (-not $CapturedByProcessId.Contains($processId)) {
            throw 'A new Codex process appeared during shutdown; refusing to launch another instance.'
        }
        $captured = $CapturedByProcessId[$processId]
        if (-not (Test-CodexUtcTimestampEqual -Left (Get-JsonPropertyValue -Object $identity -Name 'startedUtc') -Right (Get-JsonPropertyValue -Object $captured -Name 'startedUtc')) -or
            [string](Get-JsonPropertyValue -Object $identity -Name 'executablePath') -ine [string](Get-JsonPropertyValue -Object $captured -Name 'executablePath')) {
            throw 'A Codex process identity changed during shutdown; refusing to act on a reused process ID.'
        }
    }
    return [bool](@($Observation.AllPackageProcessIds).Count -eq 0)
}

function Get-VerifiedCodexShutdownHandles {
    param(
        [Parameter(Mandatory)][object[]]$Identities,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CapturedByProcessId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$TrustedPreviousCore,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedCore
    )

    $handles=@()
    try {
        $package=Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { throw 'Codex disappeared before process handles could be verified.' }
        if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $package) -Expected $ExpectedCore)) {
            throw 'The persisted core selection changed before process handles could be verified.'
        }
        $observation=Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
        $null=Assert-CodexShutdownProcessSet -Observation $observation -CapturedByProcessId $CapturedByProcessId
        $currentIds=@($observation.AllPackageProcessIds | ForEach-Object { [int]$_ })

        foreach ($identity in $Identities) {
            $processId=[int](Get-JsonPropertyValue -Object $identity -Name 'processId')
            if ($processId -notin $currentIds) { continue }
            $freshIdentity=Get-FreshSafeCodexProcessIdentity -Identity $identity -Config $Config `
                -TrustedPreviousCore $TrustedPreviousCore -ExpectedCore $ExpectedCore
            if (-not $freshIdentity) {
                throw "Captured Codex process $processId is still present but no longer has a verified identity."
            }
            $process=Get-VerifiedCodexProcessHandle -Identity $freshIdentity
            if (-not $process) {
                throw "Captured Codex process $processId is still present but its process handle could not be verified."
            }
            $handles+=,[pscustomobject]@{Identity=$freshIdentity;Process=$process}
        }

        $package=Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { throw 'Codex disappeared during process-handle verification.' }
        if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $package) -Expected $ExpectedCore)) {
            throw 'The persisted core selection changed during process-handle verification.'
        }
        $observation=Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
        $null=Assert-CodexShutdownProcessSet -Observation $observation -CapturedByProcessId $CapturedByProcessId
        $currentIds=@($observation.AllPackageProcessIds | ForEach-Object { [int]$_ })

        $activeHandles=@()
        foreach ($record in $handles) {
            $processId=[int](Get-JsonPropertyValue -Object $record.Identity -Name 'processId')
            $hasExited=[bool]$record.Process.HasExited
            if ($processId -in $currentIds -and -not $hasExited) {
                $activeHandles+=,$record
            } elseif (-not $hasExited) {
                throw "Captured Codex process $processId is absent from the fresh process list but its verified handle is still running."
            } else {
                $record.Process.Dispose()
            }
        }
        return $activeHandles
    } catch {
        foreach ($record in $handles) { if ($record.Process) { $record.Process.Dispose() } }
        throw
    }
}

function Test-CodexShutdownHandlesExited {
    param([Parameter(Mandatory)][object[]]$Handles)
    foreach ($record in $Handles) {
        try { if (-not $record.Process.HasExited) { return $false } }
        catch { return $false }
    }
    return $true
}

function Get-VerifiedCapturedCodexProcessHandles {
    param(
        [Parameter(Mandatory)][object[]]$CapturedHandles,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CapturedByProcessId,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedCore,
        [System.Collections.IDictionary]$TrustedPreviousCore
    )

    $handles=@()
    try {
        $package=Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { throw 'Codex disappeared before force-stop.' }
        if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $package) -Expected $ExpectedCore)) {
            throw 'The persisted core selection changed before force-stop.'
        }
        $observation=Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
        $null=Assert-CodexShutdownProcessSet -Observation $observation -CapturedByProcessId $CapturedByProcessId

        foreach ($captured in $CapturedHandles) {
            $processId=[int](Get-JsonPropertyValue -Object $captured.Identity -Name 'processId')
            if ($captured.Process.HasExited) { continue }
            $process=Get-VerifiedCodexProcessHandle -Identity $captured.Identity
            if (-not $process) {
                if ($captured.Process.HasExited) { continue }
                throw "Captured Codex process $processId is still alive but its verified process handle could not be reacquired."
            }
            if ($process.HasExited) { $process.Dispose(); continue }
            $handles+=,[pscustomobject]@{Identity=$captured.Identity;Process=$process}
        }

        $package=Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { throw 'Codex disappeared during force-stop preflight.' }
        if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $package) -Expected $ExpectedCore)) {
            throw 'The persisted core selection changed during force-stop preflight.'
        }
        $observation=Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
        $null=Assert-CodexShutdownProcessSet -Observation $observation -CapturedByProcessId $CapturedByProcessId
        return $handles
    } catch {
        foreach ($record in $handles) { if ($record.Process) { $record.Process.Dispose() } }
        throw
    }
}

function Set-LastHealthyCoreFromObservation {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Observation,
        [Parameter(Mandatory)][DateTimeOffset]$Now
    )

    if (-not $Observation.Package.Found -or -not $Observation.Integrity.Healthy -or
        $Observation.Enrollment.Status -ne 'Enabled' -or $Observation.Remote.ManualCondition -or
        -not $Observation.Process.DesktopPresent -or -not $Observation.Process.SelectedCorePresent -or
        $Observation.Process.AppServerStatus -ne 'Recognized' -or $Observation.Process.CoreSwitchPending) {
        return $false
    }

    $active = @($Observation.Process.AppServerProcessIdentities |
        Where-Object { $_.classification -in @('Selected','Stock','Legacy') } |
        Select-Object -First 1)
    if ($active.Count -eq 0 -or -not $active[0].startedUtc -or [int]$active[0].desktopProcessId -le 0 -or
        -not $active[0].desktopStartedUtc -or -not $Observation.Process.CoreSelection.Path) { return $false }

    $selection = $Observation.Process.CoreSelection
    if ($selection.Managed -and (-not $selection.HashVerified -or [string]$selection.Sha256 -notmatch '^[A-Fa-f0-9]{64}$')) { return $false }
    $State.lastHealthyCore = [ordered]@{
        selector = [ordered]@{
            source=[string]$selection.Source;path=[string]$selection.Path
            rawValue=[string]$selection.RawValue
            registryKind=if ($Observation.Package.Contains('AppServerOverride')) { [string](Get-JsonPropertyValue -Object $Observation.Package.AppServerOverride -Name 'RegistryKind') } else { '' }
        }
        core = [ordered]@{
            kind = [string]$selection.Kind
            path = [string]$selection.Path
            sha256 = [string]$selection.Sha256
            version = [string]$selection.Version
        }
        process = [ordered]@{
            pid = [int]$active[0].processId
            startUtc = [string]$active[0].startedUtc
            executablePath = [string]$active[0].executablePath
            desktopPid = [int]$active[0].desktopProcessId
            desktopStartUtc = [string]$active[0].desktopStartedUtc
        }
        healthyAtUtc = $Now.ToString('o')
    }

    if ($State.coreSwitchAttempt) {
        # A freshly verified healthy app-server clears a failed handover latch,
        # including when recovery had to return to the last healthy selector.
        $State.coreSwitchAttempt = $null
    }
    return $true
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
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
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
        'UnrecognizedAppServer' {
            $checks += New-ValidationCheck -Name 'AppServerExecutableRecognized' -Status 'failed' -Expected 'A recognized app-server executable' -Observed $Observation.Process.UnknownAppServerExecutables -Details ([ordered]@{
                processIds = @($Observation.Process.UnknownAppServerProcessIds)
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
        [Parameter(Mandatory)][System.Collections.IDictionary]$Enrollment,
        [System.Collections.IDictionary]$ExpectedCore
    )

    $checks = @(
        (New-ValidationCheck -Name 'CodexPackageDiscovered' -Status $(if ($AfterPackage.Found) { 'passed' } else { 'failed' }) -Expected $true -Observed $AfterPackage.Found)
        (New-ValidationCheck -Name 'DesktopProcessPresent' -Status $(if ($Process.DesktopPresent) { 'passed' } else { 'failed' }) -Expected $true -Observed $Process.DesktopPresent)
        (New-ValidationCheck -Name 'AppServerProcessPresent' -Status $(if ($Process.AppServerPresent) { 'passed' } else { 'failed' }) -Expected $true -Observed $Process.AppServerPresent)
        (New-ValidationCheck -Name 'StateDatabaseIntegrity' -Status $(if ($Integrity.State -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Integrity.State)
        (New-ValidationCheck -Name 'LogsDatabaseIntegrity' -Status $(if ($Integrity.Logs -eq 'ok') { 'passed' } else { 'failed' }) -Expected 'ok' -Observed $Integrity.Logs)
        (New-ValidationCheck -Name 'RemoteEnrollmentEnabled' -Status $(if ($Enrollment.Status -eq 'Enabled') { 'passed' } else { 'failed' }) -Expected 'Enabled' -Observed $Enrollment.Status -Details ([ordered]@{ enabledCount = $Enrollment.EnabledCount }))
    )
    if ($Process.Contains('AppServerStatus') -and $Process.AppServerStatus -eq 'Unknown') {
        $checks += New-ValidationCheck -Name 'AppServerExecutableRecognized' -Status 'failed' -Expected 'A recognized app-server executable' -Observed $Process.UnknownAppServerExecutables
    }
    if ($ExpectedCore) {
        $matchesDesired = $Process.Contains('CoreSelection') -and
            (Test-CodexCoreSelectionMatches -Actual $Process.CoreSelection -Expected $ExpectedCore) -and
            $Process.SelectedCorePresent -and $Process.AppServerStatus -eq 'Recognized'
        $checks += New-ValidationCheck -Name 'SelectedCoreMatchesDesired' -Status $(if ($matchesDesired) { 'passed' } else { 'failed' }) -Expected ([ordered]@{source=$ExpectedCore.Source;path=$ExpectedCore.Path;sha256=$ExpectedCore.Sha256}) -Observed ([ordered]@{source=$Process.CoreSelection.Source;path=$Process.CoreSelection.Path;sha256=$Process.CoreSelection.Sha256})
    }
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
    if ($Observation.Package.Contains('AppServerOverride') -and $Observation.Package.AppServerOverride.Error) {
        return New-WatchdogDecision -Action 'Manual' -Reason 'SelectedCoreInvalid'
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

    $currentSelection = Get-JsonPropertyValue -Object $Observation.Process -Name 'CoreSelection'
    if ($State.coreSwitchAttempt -and $currentSelection) {
        $attemptTarget = Get-JsonPropertyValue -Object $State.coreSwitchAttempt -Name 'target'
        $attemptStillApplies = $attemptTarget -and
            (Test-CodexCoreSelectionMatchesRecord -Selection $currentSelection -Record $attemptTarget)
        $lastHealthyStillApplies = $false
        $lastHealthyCore = Get-JsonPropertyValue -Object $State.lastHealthyCore -Name 'core'
        if ($lastHealthyCore) {
            $lastHealthySelector = Get-JsonPropertyValue -Object $State.lastHealthyCore -Name 'selector'
            $lastHealthyStillApplies = Test-CodexCoreSelectionMatchesRecord -Selection $currentSelection `
                -Record $lastHealthyCore -Source ([string](Get-JsonPropertyValue -Object $lastHealthySelector -Name 'source'))
        }
        if (-not $attemptStillApplies -and -not $lastHealthyStillApplies) {
            # A changed persisted selector is a new, explicit recovery choice.
            $State.coreSwitchAttempt = $null
        }
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
    if ($Observation.Process.Contains('AppServerStatus') -and $Observation.Process.AppServerStatus -eq 'Unknown') {
        $State.appServerMissingSinceUtc = $null
        $State.appServerMissingChecks = 0
        return New-WatchdogDecision -Action 'Manual' -Reason 'UnrecognizedAppServer'
    }
    $protectors = @($Observation.Threads | Where-Object Status -in @('Healthy', 'Starting', 'ToolRunning', 'WaitingForInput'))
    $preDispatch = @($Observation.Threads | Where-Object Status -eq 'PreDispatchFreeze')

    if ($Observation.Process.Contains('CoreSwitchPending') -and $Observation.Process.CoreSwitchPending) {
        $State.appServerMissingSinceUtc = $null
        $State.appServerMissingChecks = 0
        $attempt = $State.coreSwitchAttempt
        $selection = $Observation.Process.CoreSelection
        $sameAttempt = $attempt -and $attempt.target -and
            [string]$attempt.target.path -ieq [string]$selection.Path -and
            ([string]$attempt.target.sha256).ToUpperInvariant() -ceq ([string]$selection.Sha256).ToUpperInvariant() -and
            [string]$attempt.target.source -ceq [string]$selection.Source
        if ($sameAttempt -and [string]$attempt.status -in @('Attempting', 'RollbackAttempted', 'Failed')) {
            return New-WatchdogDecision -Action 'Manual' -Reason 'CoreSwitchAttemptAlreadyUsed'
        }
        if ($protectors.Count -gt 0) {
            return New-WatchdogDecision -Action 'None' -Reason 'HealthyTaskProtectsSharedApp' -ProtectedByThreadIds @($protectors | ForEach-Object ThreadId)
        }
        if ($suppression) { return New-WatchdogDecision -Action 'None' -Reason $suppression }
        return New-WatchdogDecision -Action 'Restart' -Reason 'CoreSelectionChanged'
    }
    if (-not $Observation.Process.AppServerPresent) {
        if ($State.coreSwitchAttempt -and [string](Get-JsonPropertyValue -Object $State.coreSwitchAttempt -Name 'status') -in @('Failed','RollbackAttempted')) {
            $State.appServerMissingSinceUtc = $null
            $State.appServerMissingChecks = 0
            return New-WatchdogDecision -Action 'Manual' -Reason 'CoreSwitchAttemptAlreadyUsed'
        }
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
    $process = Get-CodexProcessObservation -Package $package -TrustedPreviousCore $State.lastHealthyCore
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
    $override = Get-CodexAppServerOverride
    if ($override.Error) { throw 'The persisted CODEX_CLI_PATH is invalid; refusing to launch with a stale inherited selection.' }
    $priorProcessValue = [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH', 'Process')
    $hadProcessValue = [Environment]::GetEnvironmentVariables('Process').Contains('CODEX_CLI_PATH')
    $setChildSelection = {
        if ($override.Executable) {
            [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH',[string]$override.Executable,'Process')
        } else {
            Remove-Item -LiteralPath 'Env:\CODEX_CLI_PATH' -ErrorAction SilentlyContinue
        }
    }
    $restoreProcessSelection = {
        if ($hadProcessValue) {
            [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH',$priorProcessValue,'Process')
        } else {
            Remove-Item -LiteralPath 'Env:\CODEX_CLI_PATH' -ErrorAction SilentlyContinue
        }
    }
    if ($plan.Mode -eq 'Enhanced') {
        try {
            & $setChildSelection
            $launcher = Start-Process -FilePath $plan.Executable -ArgumentList $plan.Arguments -WorkingDirectory $plan.WorkingDirectory -WindowStyle Hidden -PassThru -ErrorAction Stop
            return [ordered]@{ Mode='Enhanced'; LauncherPath=$plan.LauncherPath; LauncherProcessId=$launcher.Id }
        } finally {
            & $restoreProcessSelection
        }
    }
    try {
        & $setChildSelection
        Invoke-CodexNativeActivation -Package $Package
    } finally {
        & $restoreProcessSelection
    }
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
    <# .SYNOPSIS Stops recognized package processes only when no unknown live direct app server is present. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Package,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$TrustedPreviousCore,
        [System.Collections.IDictionary]$ExpectedCore
    )

    if (-not $ExpectedCore) { $ExpectedCore = Get-CodexDesiredCoreIdentity -Package $Package }
    $observation = Get-CodexProcessObservation -Package $Package -TrustedPreviousCore $TrustedPreviousCore
    if ($observation.AppServerStatus -eq 'Unknown') { throw 'An unrecognized live Codex app-server was found; refusing to close or stop the application.' }

    $capturedIdentities = @($observation.RootProcessIdentities) + @($observation.AppServerProcessIdentities)
    $capturedByProcessId = @{}
    foreach ($identity in $capturedIdentities) {
        $processId = [int](Get-JsonPropertyValue -Object $identity -Name 'processId')
        $startedUtc = Get-JsonPropertyValue -Object $identity -Name 'startedUtc'
        $executablePath = [string](Get-JsonPropertyValue -Object $identity -Name 'executablePath')
        if ($processId -le 0 -or -not $startedUtc -or -not $executablePath -or $capturedByProcessId.Contains($processId)) {
            throw 'A live Codex process lacks a unique, complete identity; refusing to close or stop it.'
        }
        $capturedByProcessId[$processId] = $identity
    }
    if ($capturedByProcessId.Count -ne @($observation.AllPackageProcessIds).Count) {
        throw 'The live Codex process set could not be captured completely; refusing to close or stop it.'
    }

    $rootProcessIds=@($observation.RootProcessIds | ForEach-Object { [int]$_ })
    $capturedHandles=@(Get-VerifiedCodexShutdownHandles -Identities $capturedIdentities -CapturedByProcessId $capturedByProcessId `
        -Config $Config -TrustedPreviousCore $TrustedPreviousCore -ExpectedCore $ExpectedCore)
    try {
        foreach ($record in $capturedHandles) {
            $processId=[int](Get-JsonPropertyValue -Object $record.Identity -Name 'processId')
            if ($processId -in $rootProcessIds -and -not $record.Process.HasExited) { [void]$record.Process.CloseMainWindow() }
        }

        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($Config.GracefulShutdownSeconds)
        do {
            Start-Sleep -Milliseconds 500
            $livePackage = Get-CodexPackageInfo -Config $Config
            if (-not $livePackage.Found) { throw 'Codex disappeared before shutdown completed.' }
            if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $livePackage) -Expected $ExpectedCore)) {
                throw 'The persisted core selection changed during shutdown.'
            }
            $remaining = Get-CodexProcessObservation -Package $livePackage -TrustedPreviousCore $TrustedPreviousCore
            $processSetEmpty=Assert-CodexShutdownProcessSet -Observation $remaining -CapturedByProcessId $capturedByProcessId
            if ($processSetEmpty -and (Test-CodexShutdownHandlesExited -Handles $capturedHandles)) { return }
        } while ([DateTimeOffset]::UtcNow -lt $deadline)

        $livePackage = Get-CodexPackageInfo -Config $Config
        if (-not $livePackage.Found) { throw 'Codex disappeared before force-stop.' }
        if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $livePackage) -Expected $ExpectedCore)) {
            throw 'The persisted core selection changed before force-stop.'
        }
        $remaining = Get-CodexProcessObservation -Package $livePackage -TrustedPreviousCore $TrustedPreviousCore
        $null=Assert-CodexShutdownProcessSet -Observation $remaining -CapturedByProcessId $capturedByProcessId
        $killHandles=@(Get-VerifiedCapturedCodexProcessHandles -CapturedHandles $capturedHandles `
            -CapturedByProcessId $capturedByProcessId -Config $Config -ExpectedCore $ExpectedCore -TrustedPreviousCore $TrustedPreviousCore)
        try {
            foreach ($record in $killHandles) {
                try { $record.Process.Kill() } catch { }
            }
        } finally {
            foreach ($record in $killHandles) { $record.Process.Dispose() }
        }

        $verificationSeconds = [int](Get-JsonPropertyValue -Object $Config -Name 'ForceShutdownVerificationSeconds')
        $forceDeadline = [DateTimeOffset]::UtcNow.AddSeconds([Math]::Max(0,$verificationSeconds))
        do {
            Start-Sleep -Milliseconds 250
            $livePackage = Get-CodexPackageInfo -Config $Config
            if (-not $livePackage.Found) { throw 'Codex disappeared before shutdown could be verified.' }
            if (-not (Test-CodexCoreSelectionMatches -Actual (Get-CodexDesiredCoreIdentity -Package $livePackage) -Expected $ExpectedCore)) {
                throw 'The persisted core selection changed before shutdown could be verified.'
            }
            $remaining = Get-CodexProcessObservation -Package $livePackage -TrustedPreviousCore $TrustedPreviousCore
            $processSetEmpty=Assert-CodexShutdownProcessSet -Observation $remaining -CapturedByProcessId $capturedByProcessId
            if ($processSetEmpty -and (Test-CodexShutdownHandlesExited -Handles $capturedHandles)) { return }
        } while ([DateTimeOffset]::UtcNow -lt $forceDeadline)

        throw 'Codex processes remained alive after the bounded shutdown attempt; refusing to launch another instance.'
    } finally {
        foreach ($record in $capturedHandles) { $record.Process.Dispose() }
    }
}

function Get-CodexDesktopHandshakeObservation {
    <# .SYNOPSIS Verifies a current Desktop PID's successful stdio initialization handshake without exposing log text. #>
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [System.Collections.IDictionary]$Package,
        [object[]]$RootProcessIdentities = @(),
        [int[]]$RequiredProcessIds = @()
    )

    $verifiedByProcessId=@{}
    $examinedFileCount=0
    $matchingFileCount=0
    $readErrorCount=0
    $defaultLogsRoot=Join-Path $env:LOCALAPPDATA 'Codex\Logs'
    $logsRoot=[string](Get-JsonPropertyValue -Object $Config -Name 'DesktopLogsRoot')
    if(-not $logsRoot){$logsRoot=$defaultLogsRoot}
    $usesDefaultLogsRoot=$false
    try{$usesDefaultLogsRoot=[IO.Path]::GetFullPath($logsRoot).TrimEnd('\','/') -ieq [IO.Path]::GetFullPath($defaultLogsRoot).TrimEnd('\','/')}catch{}
    $logRootCandidates=[System.Collections.Generic.List[object]]::new()
    $logRootCandidates.Add([ordered]@{Path=$logsRoot;Kind=if($usesDefaultLogsRoot){'Default'}else{'Configured'}})
    # Packaged Codex redirects this LocalAppData path into its package cache.
    # The unpackaged scheduled watchdog must also use the explicit physical path.
    $packageFamily=[string](Get-JsonPropertyValue -Object $Package -Name 'PackageFamilyName')
    $packageFamilyValidated=[bool]((Get-JsonPropertyValue -Object $Package -Name 'Found') -and
        $packageFamily -cmatch '^[A-Za-z0-9][A-Za-z0-9.-]{2,49}_[A-Za-z0-9]{13}$')
    if($usesDefaultLogsRoot -and $packageFamilyValidated){
        $packageCacheRoot=Join-Path $env:LOCALAPPDATA (Join-Path 'Packages' (Join-Path $packageFamily 'LocalCache\Local\Codex\Logs'))
        $logRootCandidates.Add([ordered]@{Path=$packageCacheRoot;Kind='PackageLocalCache'})
    }
    $roots=@($RootProcessIdentities | Where-Object {
        [int](Get-JsonPropertyValue -Object $_ -Name 'processId') -gt 0
    })
    $rootIdentityChecks=[System.Collections.Generic.List[object]]::new()
    $logRootChecks=[System.Collections.Generic.List[object]]::new()
    foreach($logRootCandidate in $logRootCandidates){
        $rootEvidence=[ordered]@{
            Kind=$logRootCandidate.Kind;Available=(Test-Path -LiteralPath $logRootCandidate.Path -PathType Container)
            SearchedDirectoryCount=0;ExistingDirectoryCount=0;DirectoryReadErrorCount=0
            MatchingFileCount=0;ExaminedFileCount=0;VerifiedProcessIds=@()
        }
        $logRootChecks.Add($rootEvidence)
        $logRootCandidate['Evidence']=$rootEvidence
        $logRootCandidate['SearchedPaths']=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $logRootCandidate['ExistingPaths']=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    }
    $evidence=[ordered]@{
        RootProcessCount=@($RootProcessIdentities).Count
        InvalidRootCount=@($RootProcessIdentities).Count-$roots.Count
        RootIdentityChecks=$rootIdentityChecks
        UsesDefaultLogsRoot=$usesDefaultLogsRoot;PackageFamilyValidated=$packageFamilyValidated;LogRoots=$logRootChecks
        SearchedDirectoryCount=0;ExistingDirectoryCount=0;DirectoryReadErrorCount=0;MatchingFileCount=0
    }
    foreach($invalidRoot in @($RootProcessIdentities | Where-Object {
        [int](Get-JsonPropertyValue -Object $_ -Name 'processId') -le 0
    } | Select-Object -First 8)){
        $rootIdentityChecks.Add([ordered]@{
            ProcessId=[int](Get-JsonPropertyValue -Object $invalidRoot -Name 'processId')
            StartedUtc=$null;ExecutableNameMatches=$false;Status='ProcessIdInvalid'
        })
    }
    $searchedDirectoryPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $existingDirectoryPaths=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $requiredIds=@($RequiredProcessIds | ForEach-Object {[int]$_} | Where-Object {$_ -gt 0} | Select-Object -Unique)
    $checkedAtUtc=[DateTimeOffset]::UtcNow.ToString('o')

    if(@($logRootChecks | Where-Object Available).Count -eq 0){
        return [ordered]@{
            Verified=$false;Status='LogsRootUnavailable';VerifiedProcessIds=@();RequiredProcessIds=$requiredIds
            AllRequiredProcessesVerified=$false;ExaminedFileCount=0;ReadErrorCount=0;CheckedAtUtc=$checkedAtUtc
            Evidence=$evidence
        }
    }
    if($roots.Count -eq 0){
        return [ordered]@{
            Verified=$false;Status='NoDesktopRoots';VerifiedProcessIds=@();RequiredProcessIds=$requiredIds
            AllRequiredProcessesVerified=$false;ExaminedFileCount=0;ReadErrorCount=0;CheckedAtUtc=$checkedAtUtc
            Evidence=$evidence
        }
    }
    if($roots.Count -gt 8){
        return [ordered]@{
            Verified=$false;Status='TooManyDesktopRoots';VerifiedProcessIds=@();RequiredProcessIds=$requiredIds
            AllRequiredProcessesVerified=$false;ExaminedFileCount=0;ReadErrorCount=0;CheckedAtUtc=$checkedAtUtc
            Evidence=$evidence
        }
    }

    $filesPerEdge=4
    $headByteLimit=262144
    $tailByteLimit=262144
    $maximumLinesPerSegment=10000
    $eventPrefixPattern='(?i)^\s*(?<timestamp>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:?\d{2}))\s+(?:(?:\[(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL)\]|(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL))\s+)?\[AppServerConnection\]\s+initialize_handshake_result\b(?<payload>.*)$'
    $outcomePattern='(?i)(?:^|[\s,{])"?outcome"?\s*[:=]\s*"?(?<value>[A-Za-z0-9_-]+)"?'
    $transportPattern='(?i)(?:^|[\s,{])"?transportKind"?\s*[:=]\s*"?(?<value>[A-Za-z0-9_-]+)"?'

    foreach($rootIdentity in $roots){
        $processId=[int](Get-JsonPropertyValue -Object $rootIdentity -Name 'processId')
        $startedValue=Get-JsonPropertyValue -Object $rootIdentity -Name 'startedUtc'
        $executablePath=[string](Get-JsonPropertyValue -Object $rootIdentity -Name 'executablePath')
        $rootCheck=[ordered]@{
            ProcessId=$processId;StartedUtc=$null
            ExecutableNameMatches=([IO.Path]::GetFileName($executablePath) -ieq 'ChatGPT.exe')
            Status='ReadyForLogSearch'
        }
        $rootIdentityChecks.Add($rootCheck)
        if(-not $startedValue){$rootCheck.Status='StartTimeMissing';$evidence.InvalidRootCount++;continue}
        if(-not $rootCheck.ExecutableNameMatches){$rootCheck.Status='ExecutableNameMismatch';$evidence.InvalidRootCount++;continue}
        try{
            $rootStartedUtc=ConvertTo-UtcDateTimeOffset $startedValue
            $rootCheck.StartedUtc=$rootStartedUtc.ToString('o')
        }catch{$rootCheck.Status='StartTimeInvalid';$evidence.InvalidRootCount++;continue}

        $dateDirectories=[System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        $rootByDatePath=@{}
        foreach($baseDate in @($rootStartedUtc.UtcDateTime.Date,$rootStartedUtc.ToLocalTime().Date)){
            foreach($dayOffset in @(-1,0,1)){
                $candidateDate=$baseDate.AddDays($dayOffset)
                foreach($logRootCandidate in $logRootCandidates){
                    if(-not $logRootCandidate.Evidence.Available){continue}
                    $datePath=Join-Path $logRootCandidate.Path (Join-Path $candidateDate.ToString('yyyy') (Join-Path $candidateDate.ToString('MM') $candidateDate.ToString('dd')))
                    $null=$dateDirectories.Add($datePath)
                    $rootByDatePath[$datePath]=$logRootCandidate
                }
            }
        }

        $pidFilePattern='(?i)^codex-desktop-.+-'+[Regex]::Escape([string]$processId)+'-t\d+-i\d+-\d+-\d+\.log$'
        $matchingFiles=[System.Collections.Generic.List[System.IO.FileInfo]]::new()
        $rootEvidenceByFile=@{}
        foreach($dateDirectory in $dateDirectories){
            $logRootCandidate=$rootByDatePath[$dateDirectory]
            $rootEvidence=$logRootCandidate.Evidence
            $null=$searchedDirectoryPaths.Add($dateDirectory)
            $evidence.SearchedDirectoryCount=$searchedDirectoryPaths.Count
            $null=$logRootCandidate.SearchedPaths.Add($dateDirectory)
            $rootEvidence.SearchedDirectoryCount=$logRootCandidate.SearchedPaths.Count
            if(-not (Test-Path -LiteralPath $dateDirectory -PathType Container)){continue}
            $null=$existingDirectoryPaths.Add($dateDirectory)
            $evidence.ExistingDirectoryCount=$existingDirectoryPaths.Count
            $null=$logRootCandidate.ExistingPaths.Add($dateDirectory)
            $rootEvidence.ExistingDirectoryCount=$logRootCandidate.ExistingPaths.Count
            try{
                $dateFiles=@(Get-ChildItem -LiteralPath $dateDirectory -Filter 'codex-desktop-*.log' -File -Force -ErrorAction Stop |
                    Where-Object {$_.Name -match $pidFilePattern})
                foreach($dateFile in $dateFiles){
                    $matchingFiles.Add($dateFile)
                    $rootEvidenceByFile[$dateFile.FullName]=$rootEvidence
                    $rootEvidence.MatchingFileCount++
                }
            }catch{$readErrorCount++;$evidence.DirectoryReadErrorCount++;$rootEvidence.DirectoryReadErrorCount++}
        }
        $orderedFiles=@($matchingFiles | Sort-Object LastWriteTimeUtc,FullName)
        $matchingFileCount+=$orderedFiles.Count
        $evidence.MatchingFileCount=$matchingFileCount
        if($orderedFiles.Count -gt ($filesPerEdge*2)){
            $candidateFiles=@(@($orderedFiles | Select-Object -First $filesPerEdge)+@($orderedFiles | Select-Object -Last $filesPerEdge) |
                Sort-Object LastWriteTimeUtc,FullName | Select-Object -Unique -Property FullName)
        }else{$candidateFiles=$orderedFiles}

        foreach($candidateFile in $candidateFiles){
            $rootEvidence=$rootEvidenceByFile[$candidateFile.FullName]
            $stream=$null
            try{
                $share=[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
                $stream=[IO.FileStream]::new($candidateFile.FullName,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)
                $examinedFileCount++
                $rootEvidence.ExaminedFileCount++
                $fileLength=$stream.Length
                $segments=@(
                    [ordered]@{Offset=[long]0;Length=[long][Math]::Min($headByteLimit,$fileLength)}
                    [ordered]@{Offset=[long][Math]::Max(0,$fileLength-$tailByteLimit);Length=[long][Math]::Min($tailByteLimit,$fileLength)}
                )
                $usedOffsets=@{}
                foreach($segment in $segments){
                    if($segment.Length -le 0 -or $usedOffsets.ContainsKey([string]$segment.Offset)){continue}
                    $usedOffsets[[string]$segment.Offset]=$true
                    $null=$stream.Seek([long]$segment.Offset,[IO.SeekOrigin]::Begin)
                    $buffer=[byte[]]::new([int]$segment.Length)
                    $bytesRead=0
                    while($bytesRead -lt $buffer.Length){
                        $readCount=$stream.Read($buffer,$bytesRead,$buffer.Length-$bytesRead)
                        if($readCount -le 0){break}
                        $bytesRead+=$readCount
                    }
                    if($bytesRead -le 0){continue}
                    $segmentText=[Text.Encoding]::UTF8.GetString($buffer,0,$bytesRead)
                    if($segment.Offset -gt 0){
                        $firstNewline=$segmentText.IndexOf("`n")
                        if($firstNewline -lt 0){continue}
                        $segmentText=$segmentText.Substring($firstNewline+1)
                    }
                    if(($segment.Offset+$bytesRead) -lt $fileLength -and -not $segmentText.EndsWith("`n")){
                        $lastNewline=$segmentText.LastIndexOf("`n")
                        if($lastNewline -lt 0){continue}
                        $segmentText=$segmentText.Substring(0,$lastNewline)
                    }

                    $stringReader=[IO.StringReader]::new($segmentText)
                    try{
                        $lineCount=0
                        while($lineCount -lt $maximumLinesPerSegment){
                            $line=$stringReader.ReadLine()
                            if($null -eq $line){break}
                            $lineCount++
                            $eventMatch=[Regex]::Match($line,$eventPrefixPattern,[Text.RegularExpressions.RegexOptions]::CultureInvariant)
                            if(-not $eventMatch.Success){continue}
                            $outcomeMatch=[Regex]::Match($eventMatch.Groups['payload'].Value,$outcomePattern)
                            $transportMatch=[Regex]::Match($eventMatch.Groups['payload'].Value,$transportPattern)
                            if(-not $outcomeMatch.Success -or -not $transportMatch.Success -or
                                $outcomeMatch.Groups['value'].Value -cne 'success' -or
                                $transportMatch.Groups['value'].Value -cne 'stdio'){continue}
                            try{$handshakeUtc=ConvertTo-UtcDateTimeOffset $eventMatch.Groups['timestamp'].Value}catch{continue}
                            if($handshakeUtc -lt $rootStartedUtc){continue}
                            if($processId -notin $rootEvidence.VerifiedProcessIds){$rootEvidence.VerifiedProcessIds+=@($processId)}
                            if(-not $verifiedByProcessId.ContainsKey($processId) -or
                                $handshakeUtc -gt $verifiedByProcessId[$processId]){$verifiedByProcessId[$processId]=$handshakeUtc}
                        }
                    }finally{$stringReader.Dispose()}
                }
            }catch{$readErrorCount++}
            finally{if($stream){$stream.Dispose()}}
        }
    }

    $verifiedIds=@($verifiedByProcessId.Keys | ForEach-Object {[int]$_} | Sort-Object)
    $allRequiredVerified=$requiredIds.Count -gt 0 -and @($requiredIds | Where-Object {$verifiedByProcessId.ContainsKey([int]$_)}).Count -eq $requiredIds.Count
    $status=if($allRequiredVerified){'Verified'}elseif($matchingFileCount -eq 0){'NoPidLogs'}elseif($readErrorCount -gt 0 -and $examinedFileCount -eq 0){'LogReadFailed'}else{'HandshakeNotVerified'}
    return [ordered]@{
        Verified=($verifiedIds.Count -gt 0)
        Status=$status
        VerifiedProcessIds=$verifiedIds
        RequiredProcessIds=$requiredIds
        AllRequiredProcessesVerified=[bool]$allRequiredVerified
        ExaminedFileCount=$examinedFileCount
        ReadErrorCount=$readErrorCount
        CheckedAtUtc=$checkedAtUtc
        Evidence=$evidence
    }
}

function Wait-CodexHealthyProcesses {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$InitialPackage,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedCore,
        [System.Collections.IDictionary]$TrustedPreviousCore,
        [switch]$RequireDesktopHandshake
    )

    $lastHandshake=$null
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 2
        $package = Get-CodexPackageInfo -Config $Config
        if (-not $package.Found) { continue }
        $process = Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
        $identityMatches = $process.CoreSelection -and (Test-CodexCoreSelectionMatches -Actual $process.CoreSelection -Expected $ExpectedCore)
        $processReady=[bool]($identityMatches -and $process.DesktopPresent -and $process.SelectedCorePresent -and
            -not $process.TrustedPreviousCorePresent -and $process.AppServerStatus -eq 'Recognized')
        if($processReady -and $RequireDesktopHandshake){
            $selectedDesktopIds=@((Get-JsonPropertyValue -Object $process -Name 'AppServerProcessIdentities') | Where-Object {
                [string](Get-JsonPropertyValue -Object $_ -Name 'classification') -ne 'TrustedPrevious' -and
                [int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId') -gt 0
            } | ForEach-Object {[int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId')} | Select-Object -Unique)
            $lastHandshake=Get-CodexDesktopHandshakeObservation -Config $Config -Package $package `
                -RootProcessIdentities @(Get-JsonPropertyValue -Object $process -Name 'RootProcessIdentities') `
                -RequiredProcessIds $selectedDesktopIds
            $processReady=[bool]($selectedDesktopIds.Count -gt 0 -and $lastHandshake.AllRequiredProcessesVerified)
        }
        if ($processReady) {
            return [ordered]@{ Package=$package; Process=$process; Ready=$true; DesktopHandshake=$lastHandshake }
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    $package = Get-CodexPackageInfo -Config $Config
    if (-not $package.Found) {
        $process=Get-CodexProcessObservation -Package $package
        if($RequireDesktopHandshake){
            $lastHandshake=Get-CodexDesktopHandshakeObservation -Config $Config -Package $package `
                -RootProcessIdentities @(Get-JsonPropertyValue -Object $process -Name 'RootProcessIdentities')
        }
        return [ordered]@{Package=$package;Process=$process;Ready=$false;DesktopHandshake=$lastHandshake}
    }
    $process = Get-CodexProcessObservation -Package $package -TrustedPreviousCore $TrustedPreviousCore
    $matches = $process.CoreSelection -and (Test-CodexCoreSelectionMatches -Actual $process.CoreSelection -Expected $ExpectedCore)
    $processReady=[bool]($matches -and $process.DesktopPresent -and $process.SelectedCorePresent -and
        -not $process.TrustedPreviousCorePresent -and $process.AppServerStatus -eq 'Recognized')
    if($RequireDesktopHandshake){
        $selectedDesktopIds=@((Get-JsonPropertyValue -Object $process -Name 'AppServerProcessIdentities') | Where-Object {
            [string](Get-JsonPropertyValue -Object $_ -Name 'classification') -ne 'TrustedPrevious' -and
            [int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId') -gt 0
        } | ForEach-Object {[int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId')} | Select-Object -Unique)
        $lastHandshake=Get-CodexDesktopHandshakeObservation -Config $Config -Package $package `
            -RootProcessIdentities @(Get-JsonPropertyValue -Object $process -Name 'RootProcessIdentities') `
            -RequiredProcessIds $selectedDesktopIds
        $processReady=[bool]($processReady -and $selectedDesktopIds.Count -gt 0 -and $lastHandshake.AllRequiredProcessesVerified)
    }
    return [ordered]@{ Package=$package; Process=$process; Ready=$processReady; DesktopHandshake=$lastHandshake }
}

function Get-CodexDesiredCoreIdentity {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Package)
    $override = if ($Package.Contains('AppServerOverride')) { $Package.AppServerOverride } else { $null }
    if ($override -and $override.Error) { throw 'The persisted CODEX_CLI_PATH is invalid.' }
    if ($override -and $override.Executable) {
        return [ordered]@{
            Kind=if ($override.Managed) { 'Managed' } else { 'Legacy' }
            Path=[string]$override.Executable;Sha256=[string]$override.Sha256;Version=[string]$override.Version
            Source=[string]$override.Source;Managed=[bool]$override.Managed;HashVerified=[bool]$override.HashVerified;RawValue=[string](Get-JsonPropertyValue -Object $override -Name 'RawValue')
        }
    }
    return [ordered]@{
        Kind='Stock';Path=[string]$Package.AppServerExecutable;Sha256='';Version=$(if ($Package.Contains('Version')) { [string]$Package.Version } else { '' })
        Source='None';Managed=$false;HashVerified=$true;RawValue=''
    }
}

function Get-CoreSelectionRollbackPlan {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Attempt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$LastHealthyCore,
        [Parameter(Mandatory)][System.Collections.IDictionary]$EnvironmentValues
    )

    $target = $Attempt.target
    $previousSelector = $LastHealthyCore.selector
    $previousCore = $LastHealthyCore.core
    if (-not $target) { return [ordered]@{ CanRollback=$false;Reason='TargetSelectionMissing';UserValue=$null;RegistryKind='' } }
    $targetValue = if ($target.Contains('rawValue') -and $target.rawValue) { [string]$target.rawValue } else { [string]$target.path }
    $currentUserValue = if ($EnvironmentValues.Contains('UserRawValue') -and $EnvironmentValues.UserRawValue) { [string]$EnvironmentValues.UserRawValue } else { [string]$EnvironmentValues.User }
    if (-not $target -or [string]$target.source -cne 'User' -or
        $currentUserValue -ine $targetValue) {
        return [ordered]@{ CanRollback=$false;Reason='SelectedValueChanged';UserValue=$null;RegistryKind='' }
    }
    if (-not $previousSelector -or -not $previousCore.path -or -not (Test-Path -LiteralPath ([string]$previousCore.path) -PathType Leaf) -or
        (Test-CodexPathHasReparsePoint -Path ([string]$previousCore.path))) {
        return [ordered]@{ CanRollback=$false;Reason='PreviousCoreUnavailable';UserValue=$null;RegistryKind='' }
    }
    if ([string]$previousCore.kind -eq 'Managed') {
        try {
            $previousHash = (Get-FileHash -LiteralPath ([string]$previousCore.path) -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
            if (-not [string]$previousCore.sha256 -or $previousHash -cne ([string]$previousCore.sha256).ToUpperInvariant()) {
                return [ordered]@{ CanRollback=$false;Reason='PreviousCoreHashChanged';UserValue=$null;RegistryKind='' }
            }
        } catch { return [ordered]@{ CanRollback=$false;Reason='PreviousCoreUnavailable';UserValue=$null;RegistryKind='' } }
    }
    switch ([string]$previousSelector.source) {
        'User' {
            if ([string]$previousSelector.path -ine [string]$previousCore.path) { return [ordered]@{ CanRollback=$false;Reason='PreviousSelectorMismatch';UserValue=$null;RegistryKind='' } }
            $previousValue = if ($previousSelector.Contains('rawValue') -and $previousSelector.rawValue) { [string]$previousSelector.rawValue } else { [string]$previousSelector.path }
            $previousKind = if ($previousSelector.Contains('registryKind')) { [string]$previousSelector.registryKind } else { '' }
            return [ordered]@{ CanRollback=$true;Reason='VerifiedPreviousUserSelector';UserValue=$previousValue;RegistryKind=$previousKind }
        }
        'Machine' {
            if ([string]$EnvironmentValues.Machine -ine [string]$previousSelector.path -or
                [string]$previousSelector.path -ine [string]$previousCore.path) { return [ordered]@{ CanRollback=$false;Reason='MachineSelectorChanged';UserValue=$null;RegistryKind='' } }
            return [ordered]@{ CanRollback=$true;Reason='RestoreMachineSelector';UserValue=$null;RegistryKind='' }
        }
        'None' {
            if (-not [string]::IsNullOrWhiteSpace([string]$EnvironmentValues.Machine) -or
                ([string]$previousSelector.path -and [string]$previousSelector.path -ine [string]$previousCore.path)) {
                return [ordered]@{ CanRollback=$false;Reason='MachineSelectorChanged';UserValue=$null;RegistryKind='' }
            }
            return [ordered]@{ CanRollback=$true;Reason='RestoreStockSelector';UserValue=$null;RegistryKind='' }
        }
        default { return [ordered]@{ CanRollback=$false;Reason='PreviousSelectorUnverified';UserValue=$null;RegistryKind='' } }
    }
}

function Set-PersistedUserCodexSelection {
    param($Value,[string]$RegistryKind,$RegistryKey)
    $ownsKey=$null -eq $RegistryKey
    $key=if ($ownsKey) { [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment') } else { $RegistryKey }
    try {
        if ($null -eq $Value) {
            $key.DeleteValue('CODEX_CLI_PATH',$false)
        } else {
            $kind = [Microsoft.Win32.RegistryValueKind]::String
            if ($RegistryKind -in @('String','ExpandString')) { $kind = [Enum]::Parse([Microsoft.Win32.RegistryValueKind],$RegistryKind) }
            $key.SetValue('CODEX_CLI_PATH',$Value,$kind)
        }
    } finally { if ($ownsKey -and $key) { $key.Dispose() } }
}

function Invoke-CoreSelectionRollback {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][System.Collections.IDictionary]$State,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Attempt,
        [Parameter(Mandatory)][System.Collections.IDictionary]$CurrentPackage,
        [Parameter(Mandatory)][int]$TimeoutSeconds,
        [System.Collections.IDictionary]$EnvironmentValues
    )

    if (-not $CurrentPackage.Found) { return [ordered]@{Attempted=$false;Successful=$false;Reason='CodexPackageUnavailable'} }
    if (-not $EnvironmentValues) {
        $userSelection = Get-CodexPersistedEnvironmentValue -Source User
        $machineSelection = Get-CodexPersistedEnvironmentValue -Source Machine
        $EnvironmentValues = [ordered]@{
            User=$userSelection.Value;UserRawValue=$userSelection.RawValue;UserKind=$userSelection.RegistryKind
            Machine=$machineSelection.Value;MachineRawValue=$machineSelection.RawValue;MachineKind=$machineSelection.RegistryKind
        }
    }
    $plan = Get-CoreSelectionRollbackPlan -Attempt $Attempt -LastHealthyCore $State.lastHealthyCore -EnvironmentValues $EnvironmentValues
    if (-not $plan.CanRollback) { return [ordered]@{Attempted=$false;Successful=$false;Reason=$plan.Reason} }

    $attemptRollbackKey = '{0}|{1}' -f [string]$Attempt.target.path,[string]$Attempt.target.sha256
    if (($Attempt.Contains('rollbackKey') -and [string]$Attempt.rollbackKey -ceq $attemptRollbackKey) -or [string]$Attempt.status -eq 'RollbackAttempted') {
        return [ordered]@{Attempted=$false;Successful=$false;Reason='RollbackAlreadyAttempted'}
    }
    $Attempt.rollbackKey = $attemptRollbackKey
    $Attempt.status = 'RollbackAttempted'
    $Attempt.rollbackReason = $plan.Reason
    Save-WatchdogState -Config $Config -State $State

    try {
        $currentProcess = Get-CodexProcessObservation -Package $CurrentPackage -TrustedPreviousCore $State.lastHealthyCore
        if ($currentProcess.AppServerStatus -eq 'Unknown') { return [ordered]@{Attempted=$true;Successful=$false;Reason='UnknownAppServerPreventsRollback'} }
        if ($currentProcess.AllPackageProcessIds.Count -gt 0) {
            Stop-CodexPackageProcesses -Package $CurrentPackage -Config $Config -TrustedPreviousCore $State.lastHealthyCore
        }
        Set-PersistedUserCodexSelection -Value $plan.UserValue -RegistryKind $plan.RegistryKind
        $rollbackPackage = Get-CodexPackageInfo -Config $Config
        $expected = Get-CodexDesiredCoreIdentity -Package $rollbackPackage
        $previous = $State.lastHealthyCore.core
        if ([string]$expected.Path -ine [string]$previous.path -or
            ([string]$previous.kind -eq 'Managed' -and ([string]$expected.Sha256).ToUpperInvariant() -cne ([string]$previous.sha256).ToUpperInvariant())) {
            return [ordered]@{Attempted=$true;Successful=$false;Reason='RollbackSelectionDidNotResolveToPreviousCore'}
        }
        $launchPlan = Get-CodexDesktopLaunchPlan -Package $rollbackPackage -UserHome $Config.UserHome
        if ($launchPlan.Mode -ne 'Enhanced') { return [ordered]@{Attempted=$true;Successful=$false;Reason='EnhancedLauncherUnavailable'} }
        $null = Start-CodexDesktop -Package $rollbackPackage -UserHome $Config.UserHome -LaunchPlan $launchPlan
        $wait = Wait-CodexHealthyProcesses -Config $Config -InitialPackage $rollbackPackage -TimeoutSeconds $TimeoutSeconds `
            -ExpectedCore $expected -RequireDesktopHandshake
        $rollbackHandshake=Get-JsonPropertyValue -Object $wait -Name 'DesktopHandshake'
        if (-not $wait.Ready) {
            return [ordered]@{Attempted=$true;Successful=$false;Reason='RollbackReadinessFailed';DesktopHandshake=$rollbackHandshake}
        }
        $paths = Get-CodexDatabasePaths -Config $Config
        $integrity = Test-CodexDatabaseIntegrity -DatabasePaths $paths
        $enrollment = Get-RemoteEnrollmentObservation -DatabasePaths $paths
        $rollbackObservation = [ordered]@{
            Package=$wait.Package;Process=$wait.Process;Integrity=$integrity;Enrollment=$enrollment
            Remote=[ordered]@{ManualCondition=$false}
        }
        if (Set-LastHealthyCoreFromObservation -State $State -Observation $rollbackObservation -Now ([DateTimeOffset]::UtcNow)) {
            return [ordered]@{Attempted=$true;Successful=$true;Reason='RestoredLastHealthyCore';DesktopHandshake=$rollbackHandshake}
        }
        return [ordered]@{Attempted=$true;Successful=$false;Reason='RollbackHealthStateNotVerified'}
    } catch {
        return [ordered]@{Attempted=$true;Successful=$false;Reason='RollbackFailed'}
    }
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
    if ($Automatic) { $State.automaticRecoveryHistoryUtc = @($State.automaticRecoveryHistoryUtc) + $Now.ToString('o') }

    $coreSwitch = $Decision.Reason -eq 'CoreSelectionChanged'
    $expectedCore = Get-CodexDesiredCoreIdentity -Package $Observation.Package
    $launch = $null
    $waitResult = $null
    $rollback = $null
    $launchStarted = $false
    $stopCompleted = $false
    $failureReason = $null
    $attempt = $null
    $freshPackage = $null
    if ($coreSwitch) {
        $attempt = [ordered]@{
            status='Attempting';createdAtUtc=$Now.ToString('o')
            target=[ordered]@{source=[string]$expectedCore.Source;path=[string]$expectedCore.Path;rawValue=[string]$expectedCore.RawValue;sha256=[string]$expectedCore.Sha256;version=[string]$expectedCore.Version}
        }
        $State.coreSwitchAttempt = $attempt
        Save-WatchdogState -Config $Config -State $State
    }

    Write-WatchdogEvent -Config $Config -Event $Mode -Reason $Decision.Reason -Outcome 'started' `
        -ThreadIds $Decision.ThreadIds -ProcessIds $Observation.Process.AllPackageProcessIds -PackageVersion $Observation.Package.Version -Validation $Decision.Validation

    try {
        if ($coreSwitch) {
            $freshPackage = Get-CodexPackageInfo -Config $Config
            $freshCore = Get-CodexDesiredCoreIdentity -Package $freshPackage
            if (-not (Test-CodexCoreSelectionMatches -Actual $freshCore -Expected $expectedCore)) {
                throw 'The persisted core selection changed before recovery began.'
            }
            $launchPlan = Get-CodexDesktopLaunchPlan -Package $freshPackage -UserHome $Config.UserHome
            if ($launchPlan.Mode -ne 'Enhanced') { throw 'The canonical Enhanced launcher is unavailable for a core switch.' }
        } else {
            $freshPackage = $Observation.Package
            $launchPlan = Get-CodexDesktopLaunchPlan -Package $freshPackage -UserHome $Config.UserHome
        }
        if ($Mode -eq 'Restart') {
            Stop-CodexPackageProcesses -Package $freshPackage -Config $Config -TrustedPreviousCore $State.lastHealthyCore -ExpectedCore $expectedCore
            $stopCompleted = $true
        }
        $launch = Start-CodexDesktop -Package $freshPackage -UserHome $Config.UserHome -LaunchPlan $launchPlan
        $launchStarted = $true
        $State.startupGraceUntilUtc = $Now.AddMinutes($Config.StartupGraceMinutes).ToString('o')
        $waitResult = Wait-CodexHealthyProcesses -Config $Config -InitialPackage $freshPackage `
            -TimeoutSeconds $Config.RecoveryVerificationSeconds -ExpectedCore $expectedCore `
            -TrustedPreviousCore $State.lastHealthyCore -RequireDesktopHandshake:$coreSwitch
    } catch {
        $failureReason = if ($coreSwitch -and $_.Exception.Message -match 'unrecognized|unknown|identity|selection changed') { 'SafeRecoveryGate' } else { 'RecoveryOperationFailed' }
    }

    $rollbackPackageInput = if ($waitResult) { $waitResult.Package } elseif ($freshPackage) { $freshPackage } else { $null }
    $rollbackIsSafe = $coreSwitch -and $stopCompleted -and $rollbackPackageInput -and
        ((-not $waitResult) -or $waitResult.Process.AppServerStatus -ne 'Unknown')
    if ($rollbackIsSafe -and ((-not $waitResult) -or -not $waitResult.Ready)) {
        $rollback = Invoke-CoreSelectionRollback -Config $Config -State $State -Attempt $attempt -CurrentPackage $rollbackPackageInput -TimeoutSeconds $Config.RecoveryVerificationSeconds
    }

    $verifiedPackage = if ($waitResult) { $waitResult.Package } else { Get-CodexPackageInfo -Config $Config }
    if ($waitResult) {
        $process = $waitResult.Process
    } else {
        $process = Get-CodexProcessObservation -Package $verifiedPackage -TrustedPreviousCore $State.lastHealthyCore
    }
    $databasePaths = Get-CodexDatabasePaths -Config $Config
    $integrity = Test-CodexDatabaseIntegrity -DatabasePaths $databasePaths
    $enrollment = Get-RemoteEnrollmentObservation -DatabasePaths $databasePaths
    $recoveryValidation = Get-RecoveryValidationReport -BeforePackage $Observation.Package -AfterPackage $verifiedPackage -Process $process -Integrity $integrity -Enrollment $enrollment -ExpectedCore $expectedCore
    if ($waitResult -and -not $waitResult.Ready) {
        $recoveryValidation.checks += New-ValidationCheck -Name 'SelectedCoreReadiness' -Status 'failed' -Expected 'Desktop and app server ready on the selected core' -Observed $process.AppServerStatus
    }
    if($coreSwitch -and $waitResult -and $waitResult.DesktopHandshake){
        $handshake=$waitResult.DesktopHandshake
        $recoveryValidation.checks += New-ValidationCheck -Name 'DesktopInitializeHandshake' `
            -Status $(if($handshake.AllRequiredProcessesVerified){'passed'}else{'failed'}) `
            -Expected 'Current Desktop initialize_handshake_result success over stdio' `
            -Observed ([ordered]@{
                status=$handshake.Status;verifiedProcessIds=$handshake.VerifiedProcessIds;requiredProcessIds=$handshake.RequiredProcessIds
                examinedFileCount=[int](Get-JsonPropertyValue -Object $handshake -Name 'ExaminedFileCount')
                readErrorCount=[int](Get-JsonPropertyValue -Object $handshake -Name 'ReadErrorCount')
                evidence=(Get-JsonPropertyValue -Object $handshake -Name 'Evidence')
            })
    }
    if($rollback){
        $recoveryValidation['rollback']=[ordered]@{
            attempted=[bool]$rollback.Attempted;successful=[bool]$rollback.Successful;reason=[string]$rollback.Reason
            desktopHandshake=(Get-JsonPropertyValue -Object $rollback -Name 'DesktopHandshake')
        }
    }
    if ($failureReason) {
        $recoveryValidation.checks += New-ValidationCheck -Name 'RecoveryOperation' -Status 'failed' -Expected 'Recovery completed safely' -Observed $failureReason
    }
    $failedValidations = @($recoveryValidation.checks | Where-Object status -eq 'failed')
    $successful = $failedValidations.Count -eq 0 -and $waitResult -and $waitResult.Ready

    if ($successful) {
        $State.startupGraceUntilUtc = $null
        $State.failedRecoveryUntilUtc = $null
        $State.appServerMissingSinceUtc = $null
        $State.appServerMissingChecks = 0
        $State.staleCandidates = @()
        $healthyObservation = [ordered]@{Package=$verifiedPackage;Process=$process;Integrity=$integrity;Enrollment=$enrollment;Remote=$Observation.Remote}
        $null = Set-LastHealthyCoreFromObservation -State $State -Observation $healthyObservation -Now ([DateTimeOffset]::UtcNow)
        $outcome = 'succeeded'
    } else {
        $State.failedRecoveryUntilUtc = $Now.AddMinutes($Config.FailedRecoveryCooldownMinutes).ToString('o')
        if ($coreSwitch -and $State.coreSwitchAttempt) {
            if (-not $rollback -or -not $rollback.Attempted) { $State.coreSwitchAttempt.status = 'Failed' }
            $State.coreSwitchAttempt.failure = if ($failureReason) { $failureReason } else { 'DesiredCoreReadinessFailed' }
        }
        $outcome = if ($rollback -and $rollback.Successful) { 'failed-rolled-back' } else { 'failed' }
    }

    Write-WatchdogEvent -Config $Config -Event $Mode -Reason $Decision.Reason -Outcome $outcome `
        -ThreadIds $Decision.ThreadIds -ProcessIds $process.AllPackageProcessIds -PackageVersion $verifiedPackage.Version -Validation $recoveryValidation
    return [ordered]@{
        Attempted=$true;LaunchMethod=if ($launch) { $launch.Mode } else { '' };Successful=[bool]$successful;Outcome=$outcome
        PackageVersionBefore=$Observation.Package.Version;PackageVersionAfter=$verifiedPackage.Version
        DesktopPresent=$process.DesktopPresent;AppServerPresent=$process.AppServerPresent
        IntegrityHealthy=$integrity.Healthy;EnrollmentStatus=$enrollment.Status
        FailedValidations=@($failedValidations | ForEach-Object name);Validation=$recoveryValidation;Rollback=$rollback
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

function Get-WatchdogStableCopyPlan {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)
    $root = [IO.Path]::GetFullPath([string]$Config.InstallRoot)
    return [ordered]@{
        Root=$root
        ScriptPath=(Join-Path $root 'CodexWatchdog.ps1')
        LauncherPath=(Join-Path $root 'CodexWatchdogLauncher.vbs')
    }
}

function Install-WatchdogStableScripts {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $plan = Get-WatchdogStableCopyPlan -Config $Config
    $sourceScript = [string]$Config.SourceScriptPath
    $sourceLauncher = [string]$Config.SourceLauncherPath
    foreach ($source in @($sourceScript,$sourceLauncher)) {
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or (Test-CodexPathHasReparsePoint -Path $source)) {
            throw 'A Watchdog install source is missing or contains a reparse point.'
        }
    }
    if (Test-CodexPathHasReparsePoint -Path $plan.Root) { throw 'The stable Watchdog install path contains a reparse point.' }
    if (Test-Path -LiteralPath $plan.Root) {
        $rootItem = Get-Item -LiteralPath $plan.Root -Force
        if (-not $rootItem.PSIsContainer -or (Test-CodexPathHasReparsePoint -Path $plan.Root)) {
            throw 'The stable Watchdog install directory must be an ordinary directory.'
        }
    } else {
        $null = New-Item -ItemType Directory -Path $plan.Root -Force
    }
    if (Test-CodexPathHasReparsePoint -Path $plan.Root) { throw 'The stable Watchdog install path contains a reparse point.' }

    foreach ($pair in @(
        [pscustomobject]@{Source=$sourceScript;Destination=$plan.ScriptPath},
        [pscustomobject]@{Source=$sourceLauncher;Destination=$plan.LauncherPath}
    )) {
        $samePath = [IO.Path]::GetFullPath($pair.Source) -ieq [IO.Path]::GetFullPath($pair.Destination)
        if ($samePath) { continue }
        if (Test-Path -LiteralPath $pair.Destination) {
            $destinationItem = Get-Item -LiteralPath $pair.Destination -Force
            if ($destinationItem.PSIsContainer -or (Test-CodexPathHasReparsePoint -Path $pair.Destination)) {
                throw 'A stable Watchdog install file path must be an ordinary file.'
            }
        }
        $sourceHash = (Get-FileHash -LiteralPath $pair.Source -Algorithm SHA256 -ErrorAction Stop).Hash
        $destinationHash = if (Test-Path -LiteralPath $pair.Destination -PathType Leaf) {
            (Get-FileHash -LiteralPath $pair.Destination -Algorithm SHA256 -ErrorAction Stop).Hash
        } else { '' }
        if ($sourceHash -ceq $destinationHash) { continue }
        $temporary = Join-Path $plan.Root ('.{0}.{1}.tmp' -f [IO.Path]::GetFileName($pair.Destination),[Guid]::NewGuid().ToString('N'))
        try {
            [IO.File]::Copy($pair.Source,$temporary,$false)
            Move-Item -LiteralPath $temporary -Destination $pair.Destination -Force
        } finally {
            if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue }
        }
        if ((Get-FileHash -LiteralPath $pair.Destination -Algorithm SHA256 -ErrorAction Stop).Hash -cne $sourceHash) {
            throw 'A stable Watchdog install copy failed content verification.'
        }
    }
    if ((Test-CodexPathHasReparsePoint -Path $plan.ScriptPath) -or (Test-CodexPathHasReparsePoint -Path $plan.LauncherPath)) {
        throw 'The stable Watchdog install files cannot contain reparse points.'
    }
    $Config.ScriptPath = $plan.ScriptPath
    $Config.LauncherPath = $plan.LauncherPath
    return $plan
}

function New-WatchdogScheduledTaskXml {
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Config,
        [Parameter(Mandatory)][string]$PowerShellPath,
        [Parameter(Mandatory)][string]$WScriptPath,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Author
    )
    $escape = [Security.SecurityElement]
    $command = $escape::Escape($WScriptPath)
    $launcherPath = $escape::Escape($Config.LauncherPath)
    $pwshPath = $escape::Escape($PowerShellPath)
    $scriptPath = $escape::Escape($Config.ScriptPath)
    $workingDirectory = $escape::Escape((Split-Path -Parent $Config.ScriptPath))
    $authorXml = $escape::Escape($Author)
    $arguments = "//B //NoLogo &quot;$launcherPath&quot; &quot;$pwshPath&quot; &quot;$scriptPath&quot;"
    $date = [DateTimeOffset]::Now.ToString('s')
    $firstScheduledCheck = [DateTimeOffset]::Now.AddMinutes(1).ToString('s')
    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Date>$date</Date>
    <Author>$authorXml</Author>
    <Description>Conservative local recovery watchdog for Codex Desktop and Mobile Remote.</Description>
    <URI>$($Config.TaskPath)$($Config.TaskName)</URI>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$Sid</UserId>
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
      <UserId>$Sid</UserId>
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
}

function Install-WatchdogScheduledTask {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Config)

    $pwsh = Get-Command pwsh.exe -ErrorAction Stop | Select-Object -First 1
    if (-not (Get-Command sqlite3 -ErrorAction SilentlyContinue)) {
        throw 'sqlite3 must be installed on PATH before the watchdog can be scheduled.'
    }
    $null = Install-WatchdogStableScripts -Config $Config
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

    $xml = New-WatchdogScheduledTaskXml -Config $Config -PowerShellPath $pwsh.Source -WScriptPath $wscriptPath -Sid $sid -Author $identity.Name

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

    $coreSelection=if ($Observation.Process.Contains('CoreSelection')) {
        $Observation.Process.CoreSelection
    } else {
        [ordered]@{Kind='Unavailable';Source='None';Path='';Version='';Sha256='';HashVerified=$false}
    }
    $activeCoreProcesses=if ($Observation.Process.Contains('AppServerProcessIdentities')) {
        @($Observation.Process.AppServerProcessIdentities)
    } else { @() }
    $selectedCorePresent=[bool](Get-JsonPropertyValue -Object $Observation.Process -Name 'SelectedCorePresent')
    $trustedPreviousPresent=[bool](Get-JsonPropertyValue -Object $Observation.Process -Name 'TrustedPreviousCorePresent')
    $coreSwitchPending=[bool](Get-JsonPropertyValue -Object $Observation.Process -Name 'CoreSwitchPending')
    $observedServerStatus=[string](Get-JsonPropertyValue -Object $Observation.Process -Name 'AppServerStatus')
    $coreReady=[bool]($selectedCorePresent -and $observedServerStatus -eq 'Recognized' -and -not $trustedPreviousPresent -and -not $coreSwitchPending)
    $sourceOverride=if ($Observation.Package.Contains('AppServerOverride')) { $Observation.Package.AppServerOverride } else { $null }
    $publicOverride=if ($sourceOverride) {
        [ordered]@{
            Executable=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Executable')
            Source=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Source')
            Error=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Error')
            Managed=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Managed')
            MetadataValidated=(Get-JsonPropertyValue -Object $sourceOverride -Name 'MetadataValidated')
            HashVerified=(Get-JsonPropertyValue -Object $sourceOverride -Name 'HashVerified')
            Sha256=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Sha256')
            Version=(Get-JsonPropertyValue -Object $sourceOverride -Name 'Version')
            MetadataPath=(Get-JsonPropertyValue -Object $sourceOverride -Name 'MetadataPath')
        }
    } else { $null }

    return [ordered]@{
        timestampUtc          = $Observation.TimestampUtc
        action                = if ($WhatIfMode -and $Decision.Action -in @('Launch', 'Restart')) { "Would$($Decision.Action)" } else { $Decision.Action }
        reason                = $Decision.Reason
        packageVersion        = $Observation.Package.Version
        desktopPresent        = $Observation.Process.DesktopPresent
        appServerPresent      = $Observation.Process.AppServerPresent
        appServerStatus       = if ($Observation.Process.Contains('AppServerStatus')) { $Observation.Process.AppServerStatus } elseif ($Observation.Process.AppServerPresent) { 'Recognized' } else { 'Missing' }
        unknownAppServerProcessIds = @(if ($Observation.Process.Contains('UnknownAppServerProcessIds')) { $Observation.Process.UnknownAppServerProcessIds })
        unknownAppServerExecutables = @(if ($Observation.Process.Contains('UnknownAppServerExecutables')) { $Observation.Process.UnknownAppServerExecutables })
        appServerOverride     = $publicOverride
        rootProcessIds        = @($Observation.Process.RootProcessIds)
        appServerProcessIds   = @($Observation.Process.AppServerProcessIds)
        core = [ordered]@{
            selection=[ordered]@{
                kind=[string]$coreSelection.Kind;source=[string]$coreSelection.Source;path=[string]$coreSelection.Path
                version=[string]$coreSelection.Version;sha256=[string]$coreSelection.Sha256;hashVerified=[bool]$coreSelection.HashVerified
            }
            ready=$coreReady
            selectedPresent=$selectedCorePresent
            pending=$coreSwitchPending
            active=@($activeCoreProcesses | ForEach-Object {
                [ordered]@{
                    processId=[int]$_.processId;startedUtc=[string]$_.startedUtc;classification=[string]$_.classification
                    coreVersion=[string]$_.coreVersion;coreSha256=[string]$_.coreSha256;executablePath=[string]$_.executablePath
                }
            })
        }
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
            $stablePlan = Get-WatchdogStableCopyPlan -Config $config
            Write-WatchdogResult -AsJson:$AsJson -Result ([ordered]@{ action = 'WouldInstall'; task = "$($config.TaskPath)$($config.TaskName)"; script = $stablePlan.ScriptPath; launcher = $stablePlan.LauncherPath })
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
        if (-not $WhatIfMode -and $RequestedAction -eq 'Check') {
            $null = Set-LastHealthyCoreFromObservation -State $workingState -Observation $observation -Now $now
        }
        if ($RequestedAction -eq 'Restart') {
            $decision = New-WatchdogDecision -Action 'Restart' -Reason 'ManualRestartRequested'
        } else {
            $decision = Get-WatchdogDecision -Observation $observation -State $workingState -Config $config -Now $now
        }
        $decision.Validation = Get-TriggerValidationReport -Decision $decision -Observation $observation -State $workingState -Config $config -Now $now
        if(-not $WhatIfMode -and $RequestedAction -eq 'Check' -and $decision.Action -eq 'None' -and
            [string](Get-JsonPropertyValue -Object $observation.Process -Name 'AppServerStatus') -eq 'Recognized' -and
            [bool](Get-JsonPropertyValue -Object $observation.Process -Name 'SelectedCorePresent')){
            $selectedDesktopIds=@((Get-JsonPropertyValue -Object $observation.Process -Name 'AppServerProcessIdentities') | Where-Object {
                [string](Get-JsonPropertyValue -Object $_ -Name 'classification') -ne 'TrustedPrevious' -and
                [int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId') -gt 0
            } | ForEach-Object {[int](Get-JsonPropertyValue -Object $_ -Name 'desktopProcessId')} | Select-Object -Unique)
            if($selectedDesktopIds.Count -gt 0){
                try{
                    $handshakeProbe=Get-CodexDesktopHandshakeObservation -Config $config -Package $observation.Package `
                        -RootProcessIdentities @(Get-JsonPropertyValue -Object $observation.Process -Name 'RootProcessIdentities') `
                        -RequiredProcessIds $selectedDesktopIds
                }catch{
                    $handshakeProbe=[ordered]@{Verified=$false;Status='ObservationFailed';AllRequiredProcessesVerified=$false}
                }
                if(-not $decision.Validation){$decision.Validation=[ordered]@{phase='observation';checks=@()}}
                $decision.Validation['desktopHandshake']=$handshakeProbe
            }
        }

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
