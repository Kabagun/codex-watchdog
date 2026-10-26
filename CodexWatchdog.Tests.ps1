$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'CodexWatchdog.ps1')

function New-TestObservation {
    param(
        [bool]$DesktopPresent = $true,
        [bool]$AppServerPresent = $true,
        [bool]$IntegrityHealthy = $true,
        [string]$EnrollmentStatus = 'Enabled',
        [bool]$RemoteRepeatedFailure = $false,
        [bool]$RemoteManualCondition = $false,
        [object[]]$Threads = @()
    )

    return [ordered]@{
        Package = [ordered]@{ Found = $true; Version = '1.2.3' }
        Process = [ordered]@{
            DesktopPresent       = $DesktopPresent
            AppServerPresent     = $AppServerPresent
            RootProcessIds       = if ($DesktopPresent) { @(100) } else { @() }
            AppServerProcessIds  = if ($AppServerPresent) { @(200) } else { @() }
            AllPackageProcessIds = @()
        }
        Integrity = [ordered]@{ Healthy = $IntegrityHealthy; State = if ($IntegrityHealthy) { 'ok' } else { 'failed' }; Logs = 'ok' }
        Enrollment = [ordered]@{ Status = $EnrollmentStatus; EnabledCount = if ($EnrollmentStatus -eq 'Enabled') { 1 } else { 0 } }
        Remote = [ordered]@{
            ManualCondition = $RemoteManualCondition
            ManualReason = if ($RemoteManualCondition) { 'auth_401' } else { '' }
            RepeatedFailure = $RemoteRepeatedFailure
            FailureCount = if ($RemoteRepeatedFailure) { 4 } else { 1 }
            FailureSpanMinutes = if ($RemoteRepeatedFailure) { 6 } else { 0 }
        }
        Threads = @($Threads)
    }
}

function New-TestThread {
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string]$Status,
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [string]$Fingerprint = 'fingerprint'
    )

    return [pscustomobject][ordered]@{
        ThreadId        = $ThreadId
        Stage           = 'Progressed'
        TaskStartedUtc  = $Now.AddMinutes(-70)
        LastProgressUtc = $Now.AddMinutes(-65)
        LastEventType   = 'event_msg/token_count'
        OutstandingTool = $Status -eq 'ToolRunning'
        Waiting         = $Status -eq 'WaitingForInput'
        Fingerprint     = $Fingerprint
        Status          = $Status
    }
}

function New-FixtureEvent {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp,
        [Parameter(Mandatory)][string]$TopType,
        [string]$PayloadType = '',
        [string]$Role = '',
        [string]$CallId = ''
    )

    $payload = [ordered]@{}
    if ($PayloadType) { $payload.type = $PayloadType }
    if ($Role) { $payload.role = $Role }
    if ($CallId) { $payload.call_id = $CallId }
    return ([ordered]@{
        timestamp = $Timestamp.ToString('o')
        type      = $TopType
        payload   = $payload
    } | ConvertTo-Json -Depth 5 -Compress)
}

function Write-RolloutFixture {
    param(
        [Parameter(Mandatory)][string]$ThreadId,
        [Parameter(Mandatory)][string[]]$Events
    )
    $path = Join-Path $TestDrive "rollout-2026-01-01T00-00-00-$ThreadId.jsonl"
    Set-Content -LiteralPath $path -Value $Events -Encoding utf8
    return $path
}

function Write-TestDesktopHandshakeFile {
    param(
        [Parameter(Mandatory)][string]$LogsRoot,
        [Parameter(Mandatory)][int]$FileProcessId,
        [Parameter(Mandatory)][DateTimeOffset]$Timestamp,
        [Parameter(Mandatory)][string]$Line,
        [string]$Payload=''
    )
    $date=$Timestamp.UtcDateTime
    $directory=Join-Path $LogsRoot (Join-Path $date.ToString('yyyy') (Join-Path $date.ToString('MM') $date.ToString('dd')))
    $null=New-Item -ItemType Directory -Path $directory -Force
    $path=Join-Path $directory ('codex-desktop-fixture-{0}-t0-i1-000000-0.log' -f $FileProcessId)
    [IO.File]::WriteAllText($path,$Line+[Environment]::NewLine+$Payload,[Text.UTF8Encoding]::new($false))
    return $path
}

function New-ManagedCoreFixture {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Version,
        [string]$Contents = 'fixture managed core; never executed',
        [switch]$RootManifest
    )
    $versionRoot = Join-Path $Root (Join-Path 'runtime' $Version)
    $binRoot = Join-Path $versionRoot 'bin'
    $null = New-Item -ItemType Directory -Path $binRoot -Force
    $core = Join-Path $binRoot 'codex.exe'
    [IO.File]::WriteAllText($core,$Contents,[Text.UTF8Encoding]::new($false))
    $hash = (Get-FileHash -LiteralPath $core -Algorithm SHA256).Hash.ToUpperInvariant()
    $relativeCore = "runtime/$Version/bin/codex.exe"
    $manifest = [ordered]@{
        localVersion=$Version
        coreRelativePath=if ($RootManifest) { $relativeCore } else { 'bin/codex.exe' }
        validation=[ordered]@{passed=$true}
        components=@([ordered]@{relativePath=if ($RootManifest) { $relativeCore } else { 'bin/codex.exe' };sha256=$hash})
    }
    $manifestPath = if ($RootManifest) { Join-Path $Root 'manifest.json' } else { Join-Path $versionRoot '.capacity-manifest.json' }
    $null = New-Item -ItemType Directory -Path $Root -Force
    [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    return [ordered]@{Root=$Root;Version=$Version;Path=$core;Hash=$hash;ManifestPath=$manifestPath}
}

function New-LegacyUpgradeFixture {
    param([Parameter(Mandatory)][string]$Root)
    $old=New-ManagedCoreFixture -Root $Root -Version 'release-1' -RootManifest
    $archiveDirectory=Join-Path $Root 'temp\previous-package-fixture'
    $null=New-Item -ItemType Directory -Path $archiveDirectory -Force
    $archiveManifest=Join-Path $archiveDirectory 'manifest.json'
    Copy-Item -LiteralPath $old.ManifestPath -Destination $archiveManifest
    $new=New-ManagedCoreFixture -Root $Root -Version 'release-3' -RootManifest
    return [ordered]@{Old=$old;New=$new;ArchiveDirectory=$archiveDirectory;ArchiveManifest=$archiveManifest}
}

function New-RegistryKeyRecorder {
    $script:registryKeyCalls=[ordered]@{Deleted=@();Set=@();Disposed=$false}
    $key=[pscustomobject]@{Calls=$script:registryKeyCalls}
    Add-Member -InputObject $key -MemberType ScriptMethod -Name DeleteValue -Value {
        param($Name,$ThrowOnMissing)
        $this.Calls.Deleted=@($this.Calls.Deleted)+[string]$Name
    }
    Add-Member -InputObject $key -MemberType ScriptMethod -Name SetValue -Value {
        param($Name,$Value,$Kind)
        $this.Calls.Set=@($this.Calls.Set)+@([ordered]@{Name=[string]$Name;Value=$Value;Kind=[string]$Kind})
    }
    Add-Member -InputObject $key -MemberType ScriptMethod -Name Dispose -Value { $this.Calls.Disposed=$true }
    return $key
}

function New-ManagedCoreProcessFixture {
    param(
        [Parameter(Mandatory)][DateTimeOffset]$Now,
        [Parameter(Mandatory)][string]$DesktopPath,
        [Parameter(Mandatory)][string]$CorePath
    )
    $desktopStart = $Now.AddMinutes(-20)
    $serverStart = $Now.AddMinutes(-19)
    $main = [pscustomobject]@{
        ProcessId=20;ParentProcessId=1;Name='ChatGPT.exe';ExecutablePath=$DesktopPath
        CommandLine='desktop';CreationDate=$desktopStart
    }
    $server = [pscustomobject]@{
        ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$CorePath
        CommandLine='codex.exe app-server';CreationDate=$serverStart
    }
    return [ordered]@{Desktop=$main;Server=$server;DesktopStartUtc=(ConvertTo-UtcString $desktopStart);ServerStartUtc=(ConvertTo-UtcString $serverStart)}
}

function New-TestProcessHandle {
    param([Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][DateTime]$StartTime)

    $handle=[pscustomobject]@{
        Id=$ProcessId;StartTime=$StartTime
        SafeHandleState=[ordered]@{Reads=0;Value=[pscustomobject]@{IsInvalid=$false;IsClosed=$false}}
    }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name SafeHandle -Value {
        $this.SafeHandleState.Reads++
        return $this.SafeHandleState.Value
    }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name HasExited -Value {
        if ($script:shutdownHandleActions -and $script:shutdownHandleActions.ContainsKey([int]$this.Id)) {
            return [bool]$script:shutdownHandleActions[[int]$this.Id].Exited
        }
        return $false
    } -SecondValue {
        param($value)
        if ($script:shutdownHandleActions -and $script:shutdownHandleActions.ContainsKey([int]$this.Id)) {
            $script:shutdownHandleActions[[int]$this.Id].Exited=[bool]$value
        }
    }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name CloseMainWindow -Value {
        $script:shutdownHandleActions[[int]$this.Id].CloseCount++
        if ($script:shutdownHandleActions[[int]$this.Id].CloseExits) {
            $this.HasExited=$true
            $script:shutdownHandleActions[[int]$this.Id].Exited=$true
        }
        return $false
    }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Kill -Value {
        $script:shutdownHandleActions[[int]$this.Id].KillCount++
        if ($script:shutdownHandleActions[[int]$this.Id].KillExits) {
            $this.HasExited=$true
            $script:shutdownHandleActions[[int]$this.Id].Exited=$true
        }
    }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value {
        $this.SafeHandleState.Value.IsClosed=$true
    }
    return $handle
}

function New-StockCacheFixture {
    param([Parameter(Mandatory)][string]$Root,[string]$Contents='fixture package stock core; never executed')

    $bundled=Join-Path $Root 'package\app\resources\codex.exe'
    $binRoot=Join-Path $Root 'user\OpenAI\Codex\bin'
    $cached=Join-Path $binRoot '2993767bd1dfb009\codex.exe'
    $null=New-Item -ItemType Directory -Path (Split-Path -Parent $bundled),(Split-Path -Parent $cached) -Force
    [IO.File]::WriteAllText($bundled,$Contents,[Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($cached,$Contents,[Text.UTF8Encoding]::new($false))
    return [ordered]@{
        Package=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=Join-Path $Root 'package\app\ChatGPT.exe'
            AppServerExecutable=$bundled;AppServerBinRoot=$binRoot
        }
        Cached=$cached;Hash=(Get-FileHash -LiteralPath $bundled -Algorithm SHA256).Hash.ToUpperInvariant()
    }
}

Describe 'Verified process shutdown handles' {
    BeforeEach {
        $script:verifiedProcessStarted=[DateTimeOffset]::Parse('2026-10-26T11:12:13.1234567+03:00')
        $script:verifiedProcessPath='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
        $script:verifiedFreshProcess=[pscustomobject]@{
            ProcessId=120;ExecutablePath=$script:verifiedProcessPath;CreationDate=$script:verifiedProcessStarted
        }
        $script:verifiedProcessHandle=New-TestProcessHandle -ProcessId 120 -StartTime $script:verifiedProcessStarted.UtcDateTime
        Mock Get-CimInstance { $script:verifiedFreshProcess }
        Mock Get-Process { $script:verifiedProcessHandle }
    }

    It 'verifies a Desktop root identity without optional app-server core fields' {
        $identity=[ordered]@{
            processId=120;startedUtc=$script:verifiedProcessStarted.ToString('o');executablePath=$script:verifiedProcessPath
        }

        $handle=Get-VerifiedCodexProcessHandle -Identity $identity

        $handle | Should Not Be $null
        $handle.Id | Should Be 120
        $script:verifiedProcessHandle.SafeHandleState.Reads | Should Be 1
        Assert-MockCalled Get-Process -Times 1 -Exactly -Scope It
    }

    It 'verifies a stock app-server identity with core fields' {
        $identity=[ordered]@{
            processId=120;startedUtc=$script:verifiedProcessStarted.ToString('o');executablePath=$script:verifiedProcessPath
            coreKind='Stock';coreSha256=''
        }

        $handle=Get-VerifiedCodexProcessHandle -Identity $identity

        $handle | Should Not Be $null
        $handle.Id | Should Be 120
    }

    It 'rejects a reused PID with a different creation instant before opening a process handle' {
        $script:verifiedFreshProcess.CreationDate=$script:verifiedProcessStarted.AddTicks(1)
        $identity=[ordered]@{
            processId=120;startedUtc=$script:verifiedProcessStarted.ToString('o');executablePath=$script:verifiedProcessPath
        }

        $handle=Get-VerifiedCodexProcessHandle -Identity $identity

        $handle | Should Be $null
        Assert-MockCalled Get-Process -Times 0 -Exactly -Scope It
    }

    It 'rejects and disposes a process wrapper whose retained OS handle is invalid' {
        $script:verifiedProcessHandle.SafeHandleState.Value.IsInvalid=$true
        $identity=[ordered]@{
            processId=120;startedUtc=$script:verifiedProcessStarted.ToString('o');executablePath=$script:verifiedProcessPath
        }

        $handle=Get-VerifiedCodexProcessHandle -Identity $identity

        $handle | Should Be $null
        $script:verifiedProcessHandle.SafeHandleState.Reads | Should Be 1
        $script:verifiedProcessHandle.SafeHandleState.Value.IsClosed | Should Be $true
    }

    It 'does not return from the real stop path while the captured Desktop root survives force-stop' {
        $config=Get-WatchdogConfig
        $config.GracefulShutdownSeconds=0
        $config.ForceShutdownVerificationSeconds=0
        $script:shutdownNow=[DateTimeOffset]::Parse('2026-10-26T11:12:13Z')
        $desktopPath='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
        $stockPath='C:\WindowsApps\OpenAI.Codex_fixture\app\resources\codex.exe'
        $desktopStart=$script:shutdownNow.AddMinutes(-2)
        $serverStart=$script:shutdownNow.AddMinutes(-1)
        $script:shutdownPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktopPath;AppServerExecutable=$stockPath
        }
        $selection=Get-CodexDesiredCoreIdentity -Package $script:shutdownPackage
        $desktopIdentity=[ordered]@{
            processId=20;startedUtc=$desktopStart.ToString('o');executablePath=$desktopPath
        }
        $serverIdentity=[ordered]@{
            processId=21;startedUtc=$serverStart.ToString('o');executablePath=$stockPath
            coreKind='Stock';coreSha256='';desktopProcessId=20;desktopStartedUtc=$desktopStart.ToString('o')
        }
        $script:shutdownProcess=[ordered]@{
            DesktopPresent=$true;AppServerPresent=$true;AppServerStatus='Recognized';CoreSelection=$selection
            SelectedCorePresent=$true;TrustedPreviousCorePresent=$false;CoreSwitchPending=$true
            UnknownAppServerProcessIds=@();UnknownAppServerExecutables=@()
            RootProcessIds=@(20);RootProcessIdentities=@($desktopIdentity)
            AppServerProcessIds=@(21);AppServerProcessIdentities=@($serverIdentity)
            AllPackageProcessIds=@(20,21)
        }
        $script:shutdownHandleActions=@{
            20=[ordered]@{CloseCount=0;KillCount=0;CloseExits=$false;KillExits=$false;Exited=$false}
            21=[ordered]@{CloseCount=0;KillCount=0;CloseExits=$false;KillExits=$false;Exited=$false}
        }
        $script:shutdownCim=@{
            20=[pscustomobject]@{ProcessId=20;ExecutablePath=$desktopPath;CreationDate=$desktopStart}
            21=[pscustomobject]@{ProcessId=21;ExecutablePath=$stockPath;CreationDate=$serverStart}
        }
        $script:shutdownVerificationSequence=@(
            $script:shutdownCim[20],$script:shutdownCim[20],$script:shutdownCim[21],$script:shutdownCim[21],
            $script:shutdownCim[20],$script:shutdownCim[20],$script:shutdownCim[21],$script:shutdownCim[21]
        )
        $script:shutdownVerificationIndex=0
        $script:currentShutdownCim=$null
        Mock Get-CodexPackageInfo { $script:shutdownPackage }
        Mock Get-CodexProcessObservation { $script:shutdownProcess }
        Mock Get-CimInstance {
            $index=$script:shutdownVerificationIndex++
            $script:currentShutdownCim=$script:shutdownVerificationSequence[$index % $script:shutdownVerificationSequence.Count]
            if ($script:unverifyShutdownRoot -and $script:currentShutdownCim.ProcessId -eq 20) { return $null }
            $script:currentShutdownCim
        }
        $script:unverifyShutdownRoot=$false
        Mock Get-Process {
            New-TestProcessHandle -ProcessId $script:currentShutdownCim.ProcessId -StartTime $script:currentShutdownCim.CreationDate.UtcDateTime
        }
        Mock Start-Sleep {}

        $failure=$null
        try {
            Stop-CodexPackageProcesses -Package $script:shutdownPackage -Config $config -ExpectedCore $selection
        } catch { $failure=$_ }

        $failure.Exception.Message | Should Be 'Codex processes remained alive after the bounded shutdown attempt; refusing to launch another instance.'
        $script:shutdownHandleActions[20].CloseCount | Should Be 1
        $script:shutdownHandleActions[20].KillCount | Should Be 1
        $script:shutdownHandleActions[21].KillCount | Should Be 1

        $script:launchCalls=0
        $script:selectorWrites=0
        Mock Save-WatchdogState {}
        Mock Write-DiagnosticSnapshot {}
        Mock Write-WatchdogEvent {}
        Mock Get-CodexDatabasePaths { [ordered]@{State='state';Logs='logs'} }
        Mock Test-CodexDatabaseIntegrity { [ordered]@{Healthy=$true;State='ok';Logs='ok'} }
        Mock Get-RemoteEnrollmentObservation { [ordered]@{Status='Enabled';EnabledCount=1} }
        Mock Get-CodexDesktopLaunchPlan { [ordered]@{Mode='Enhanced';CanLaunch=$true} }
        Mock Start-CodexDesktop { $script:launchCalls++ }
        Mock Set-PersistedUserCodexSelection { $script:selectorWrites++ }
        Mock Wait-CodexHealthyProcesses { throw 'Readiness cannot be reached after incomplete shutdown.' }
        $recoveryObservation=[ordered]@{
            Package=$script:shutdownPackage;Process=$script:shutdownProcess
            Integrity=[ordered]@{Healthy=$true;State='ok';Logs='ok'}
            Enrollment=[ordered]@{Status='Enabled';EnabledCount=1}
            Remote=[ordered]@{ManualCondition=$false;ManualReason=''};Threads=@()
        }
        $decision=New-WatchdogDecision -Action Restart -Reason 'CoreSelectionChanged'
        $recovery=Invoke-CodexRecovery -Mode Restart -Config $config -State (New-WatchdogState) `
            -Observation $recoveryObservation -Decision $decision -Now $script:shutdownNow

        $recovery.Successful | Should Be $false
        $script:launchCalls | Should Be 0
        $script:selectorWrites | Should Be 0
        Assert-MockCalled Wait-CodexHealthyProcesses -Times 0 -Exactly -Scope It

        $script:shutdownHandleActions[20].CloseCount=0
        $script:shutdownHandleActions[20].KillCount=0
        $script:shutdownHandleActions[21].KillCount=0
        $script:unverifyShutdownRoot=$true
        $script:shutdownVerificationIndex=0
        $failure=$null
        try {
            Stop-CodexPackageProcesses -Package $script:shutdownPackage -Config $config -ExpectedCore $selection
        } catch { $failure=$_ }
        $failure.Exception.Message | Should Be 'Captured Codex process 20 is still present but its process handle could not be verified.'
        $script:shutdownHandleActions[20].CloseCount | Should Be 0
        $script:shutdownHandleActions[20].KillCount | Should Be 0
        $script:shutdownHandleActions[21].KillCount | Should Be 0
    }

    It 'waits for a captured app-server orphan after the Desktop root exits and stops it by captured identity' {
        $config=Get-WatchdogConfig
        $config.GracefulShutdownSeconds=0
        $config.ForceShutdownVerificationSeconds=0
        $now=[DateTimeOffset]::Parse('2026-10-26T11:12:13Z')
        $desktopPath='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
        $stockPath='C:\WindowsApps\OpenAI.Codex_fixture\app\resources\codex.exe'
        $desktopStart=$now.AddMinutes(-2)
        $serverStart=$now.AddMinutes(-1)
        $script:shutdownPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktopPath;AppServerExecutable=$stockPath
        }
        $selection=Get-CodexDesiredCoreIdentity -Package $script:shutdownPackage
        $desktopIdentity=[ordered]@{processId=20;startedUtc=$desktopStart.ToString('o');executablePath=$desktopPath}
        $serverIdentity=[ordered]@{
            processId=21;startedUtc=$serverStart.ToString('o');executablePath=$stockPath
            coreKind='Stock';coreSha256='';desktopProcessId=20;desktopStartedUtc=$desktopStart.ToString('o')
        }
        $script:shutdownHandleActions=@{
            20=[ordered]@{CloseCount=0;KillCount=0;CloseExits=$true;KillExits=$false;Exited=$false}
            21=[ordered]@{CloseCount=0;KillCount=0;CloseExits=$false;KillExits=$true;Exited=$false}
        }
        $script:shutdownCim=@{
            20=[pscustomobject]@{ProcessId=20;ExecutablePath=$desktopPath;CreationDate=$desktopStart}
            21=[pscustomobject]@{ProcessId=21;ExecutablePath=$stockPath;CreationDate=$serverStart}
        }
        $script:shutdownVerificationSequence=@($script:shutdownCim[20],$script:shutdownCim[20],$script:shutdownCim[21],$script:shutdownCim[21],$script:shutdownCim[21],$script:shutdownCim[21])
        $script:shutdownVerificationIndex=0
        $script:currentShutdownCim=$null
        $script:shutdownProcess=[ordered]@{
            DesktopPresent=$true;AppServerPresent=$true;AppServerStatus='Recognized';CoreSelection=$selection
            RootProcessIds=@(20);RootProcessIdentities=@($desktopIdentity)
            AppServerProcessIds=@(21);AppServerProcessIdentities=@($serverIdentity)
            AllPackageProcessIds=@(20,21)
        }
        Mock Get-CodexPackageInfo { $script:shutdownPackage }
        Mock Get-CodexProcessObservation {
            if ($script:shutdownHandleActions[20].Exited) {
                return [ordered]@{
                    DesktopPresent=$false;AppServerPresent=$false;AppServerStatus='Missing';CoreSelection=$selection
                    RootProcessIds=@();RootProcessIdentities=@();AppServerProcessIds=@();AppServerProcessIdentities=@()
                    AllPackageProcessIds=@()
                }
            }
            return $script:shutdownProcess
        }
        Mock Get-CimInstance {
            $index=$script:shutdownVerificationIndex++
            $script:currentShutdownCim=$script:shutdownVerificationSequence[$index % $script:shutdownVerificationSequence.Count]
            $script:currentShutdownCim
        }
        Mock Get-Process {
            New-TestProcessHandle -ProcessId $script:currentShutdownCim.ProcessId -StartTime $script:currentShutdownCim.CreationDate.UtcDateTime
        }
        Mock Start-Sleep {}

        Stop-CodexPackageProcesses -Package $script:shutdownPackage -Config $config -ExpectedCore $selection

        $script:shutdownHandleActions[20].CloseCount | Should Be 1
        $script:shutdownHandleActions[21].KillCount | Should Be 1
        $script:shutdownHandleActions[21].Exited | Should Be $true
    }
}

Describe 'Codex watchdog decision rules' {
    BeforeEach {
        $config = Get-WatchdogConfig
        $state = New-WatchdogState
        $now = [DateTimeOffset]::Parse('2026-07-23T12:00:00Z')
    }

    It 'does nothing when Codex is healthy and idle' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'HealthyIdle'
    }

    It 'launches Codex when the desktop process is absent' {
        $observation = New-TestObservation -DesktopPresent $false -AppServerPresent $false
        $decision = Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Launch'
        $decision.Reason | Should Be 'CodexDesktopAbsent'
    }

    It 'honors startup grace before relaunching' {
        $state.startupGraceUntilUtc = $now.AddMinutes(4).ToString('o')
        $observation = New-TestObservation -DesktopPresent $false -AppServerPresent $false
        $decision = Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'StartupGracePeriod'
    }

    It 'restarts after the app server is missing for five minutes and three checks' {
        $state.appServerMissingSinceUtc = $now.AddMinutes(-6).ToString('o')
        $state.appServerMissingChecks = 2
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -AppServerPresent $false) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Restart'
        $decision.Reason | Should Be 'AppServerMissing'
    }

    It 'restarts an unprotected pre-dispatch freeze' {
        $thread = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000001' -Status 'PreDispatchFreeze' -Now $now
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($thread)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Restart'
        $decision.Reason | Should Be 'PreDispatchLifecycleFreeze'
    }

    It 'protects the shared app when another task is healthy' {
        $frozen = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000001' -Status 'PreDispatchFreeze' -Now $now
        $healthy = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000002' -Status 'Healthy' -Now $now
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($frozen, $healthy)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'HealthyTaskProtectsSharedApp'
        ($decision.ProtectedByThreadIds -contains $healthy.ThreadId) | Should Be $true
    }

    It 'protects outstanding tools regardless of age' {
        $thread = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000003' -Status 'ToolRunning' -Now $now
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($thread)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'HealthyOrProtectedActivity'
    }

    It 'protects user-input and approval waits' {
        $thread = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000004' -Status 'WaitingForInput' -Now $now
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($thread)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
    }

    It 'requires five minutes of unchanged confirmation for a stale task' {
        $thread = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000005' -Status 'StaleCandidate' -Now $now -Fingerprint 'same'
        $state.staleCandidates = @([ordered]@{
            threadId = $thread.ThreadId
            fingerprint = 'same'
            observedSinceUtc = $now.AddMinutes(-6).ToString('o')
        })
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($thread)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Restart'
        $decision.Reason | Should Be 'ConfirmedStaleTask'
    }

    It 'does not confirm a stale task whose fingerprint changed' {
        $thread = New-TestThread -ThreadId '00000000-0000-0000-0000-000000000005' -Status 'StaleCandidate' -Now $now -Fingerprint 'new'
        $state.staleCandidates = @([ordered]@{
            threadId = $thread.ThreadId
            fingerprint = 'old'
            observedSinceUtc = $now.AddMinutes(-6).ToString('o')
        })
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -Threads @($thread)) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
    }

    It 'ignores a single Remote disconnect' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -RemoteRepeatedFailure $false) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
    }

    It 'restarts after repeated Remote transport failures while idle' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -RemoteRepeatedFailure $true) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Restart'
        $decision.Reason | Should Be 'RepeatedRemoteTransportFailure'
    }

    It 'does not restart for Remote authentication failures' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -RemoteManualCondition $true) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Manual'
        $decision.Reason | Should Be 'RemoteAuthentication:auth_401'
    }

    It 'does not restart when Remote enrollment is disabled' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -EnrollmentStatus 'Disabled') -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Manual'
        $decision.Reason | Should Be 'RemoteEnrollmentDisabled'
    }

    It 'does not recover automatically after an integrity failure' {
        $decision = Get-WatchdogDecision -Observation (New-TestObservation -IntegrityHealthy $false) -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Manual'
        $decision.Reason | Should Be 'DatabaseIntegrityNotHealthy'
    }

    It 'honors the failed-recovery cooldown' {
        $state.failedRecoveryUntilUtc = $now.AddMinutes(5).ToString('o')
        $observation = New-TestObservation -DesktopPresent $false -AppServerPresent $false
        $decision = Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'FailedRecoveryCooldown'
    }

    It 'limits automatic recovery attempts to three per hour' {
        $state.automaticRecoveryHistoryUtc = @(
            $now.AddMinutes(-10).ToString('o'),
            $now.AddMinutes(-20).ToString('o'),
            $now.AddMinutes(-30).ToString('o')
        )
        $observation = New-TestObservation -DesktopPresent $false -AppServerPresent $false
        $decision = Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'AutomaticRecoveryRateLimit'
    }
}

Describe 'Codex rollout lifecycle parsing' {
    BeforeEach {
        $config = Get-WatchdogConfig
        $now = [DateTimeOffset]::Parse('2026-07-23T12:00:00Z')
    }

    It 'recognizes the observed task-started-only freeze after three minutes' {
        $id = '10000000-0000-0000-0000-000000000001'
        $path = Write-RolloutFixture -ThreadId $id -Events @(
            New-FixtureEvent -Timestamp $now.AddMinutes(-4) -TopType 'event_msg' -PayloadType 'task_started'
        )
        $thread = Get-RolloutObservation -Path $path -Now $now
        $thread = Set-ThreadHealthStatus -Thread $thread -Config $config -Now $now
        $thread.Status | Should Be 'PreDispatchFreeze'
        $thread.LastEventType | Should Be 'event_msg/task_started'
    }

    It 'treats normal dispatch metadata as healthy progress' {
        $id = '10000000-0000-0000-0000-000000000002'
        $path = Write-RolloutFixture -ThreadId $id -Events @(
            New-FixtureEvent -Timestamp $now.AddMinutes(-2) -TopType 'event_msg' -PayloadType 'task_started'
            New-FixtureEvent -Timestamp $now.AddMinutes(-2).AddSeconds(1) -TopType 'turn_context'
            New-FixtureEvent -Timestamp $now.AddMinutes(-1) -TopType 'event_msg' -PayloadType 'agent_reasoning'
        )
        $thread = Get-RolloutObservation -Path $path -Now $now
        $thread = Set-ThreadHealthStatus -Thread $thread -Config $config -Now $now
        $thread.Status | Should Be 'Healthy'
    }

    It 'protects a long-running outstanding tool call' {
        $id = '10000000-0000-0000-0000-000000000003'
        $path = Write-RolloutFixture -ThreadId $id -Events @(
            New-FixtureEvent -Timestamp $now.AddMinutes(-100) -TopType 'event_msg' -PayloadType 'task_started'
            New-FixtureEvent -Timestamp $now.AddMinutes(-99) -TopType 'turn_context'
            New-FixtureEvent -Timestamp $now.AddMinutes(-90) -TopType 'response_item' -PayloadType 'function_call' -CallId 'call-1'
        )
        $thread = Get-RolloutObservation -Path $path -Now $now
        $thread = Set-ThreadHealthStatus -Thread $thread -Config $config -Now $now
        $thread.OutstandingTool | Should Be $true
        $thread.Status | Should Be 'ToolRunning'
    }

    It 'stops tracking a completed task as active' {
        $id = '10000000-0000-0000-0000-000000000004'
        $path = Write-RolloutFixture -ThreadId $id -Events @(
            New-FixtureEvent -Timestamp $now.AddMinutes(-5) -TopType 'event_msg' -PayloadType 'task_started'
            New-FixtureEvent -Timestamp $now.AddMinutes(-4) -TopType 'event_msg' -PayloadType 'agent_message'
            New-FixtureEvent -Timestamp $now.AddMinutes(-3) -TopType 'event_msg' -PayloadType 'task_complete'
        )
        $thread = Get-RolloutObservation -Path $path -Now $now
        ($null -eq $thread) | Should Be $true
    }
}

Describe 'Codex package process matching' {
    It 'uses the desktop application ID when the package manifest has multiple applications' {
        Mock Get-AppxPackage {
            [pscustomobject]@{
                Version = [version]'26.915.4065.0'
                PackageFullName = 'OpenAI.Codex_26.915.4065.0_x64__example'
                PackageFamilyName = 'OpenAI.Codex_example'
                InstallLocation = 'C:\Program Files\WindowsApps\OpenAI.Codex_26.915.4065.0_x64__example'
            }
        }
        Mock Get-AppxPackageManifest {
            [pscustomobject]@{ Package = [pscustomobject]@{
                Applications = [pscustomobject]@{ Application = @(
                    [pscustomobject]@{ Id = 'App'; Executable = 'app/ChatGPT.exe' }
                    [pscustomobject]@{ Id = 'CodexCoreCommandRunner'; Executable = 'app/resources/codex-command-runner.exe' }
                ) }
            } }
        }

        $package = Get-CodexPackageInfo -Config (Get-WatchdogConfig)
        $package.Aumid | Should Be 'OpenAI.Codex_example!App'
    }

    It 'follows the current package path after a Codex update and ignores the old package' {
        $package = [ordered]@{
            Found = $true
            DesktopExecutable = 'C:\Program Files\WindowsApps\OpenAI.Codex_2.0\app\ChatGPT.exe'
            AppServerExecutable = 'C:\Program Files\WindowsApps\OpenAI.Codex_2.0\app\resources\codex.exe'
            AppServerBinRoot = 'C:\Users\Tester\AppData\Local\OpenAI\Codex\bin'
        }
        $processes = @(
            [pscustomobject]@{ ProcessId = 10; ParentProcessId = 1; Name = 'ChatGPT.exe'; ExecutablePath = 'C:\Program Files\WindowsApps\OpenAI.Codex_1.0\app\ChatGPT.exe'; CommandLine = 'old'; CreationDate = [DateTime]::UtcNow.AddHours(-2) }
            [pscustomobject]@{ ProcessId = 20; ParentProcessId = 1; Name = 'ChatGPT.exe'; ExecutablePath = $package.DesktopExecutable; CommandLine = 'new'; CreationDate = [DateTime]::UtcNow.AddHours(-1) }
            [pscustomobject]@{ ProcessId = 21; ParentProcessId = 20; Name = 'codex.exe'; ExecutablePath = $package.AppServerExecutable; CommandLine = 'codex.exe app-server --analytics-default-enabled'; CreationDate = [DateTime]::UtcNow.AddHours(-1) }
        )
        $observation = Get-CodexProcessObservation -Package $package -Processes $processes
        $observation.DesktopPresent | Should Be $true
        $observation.AppServerPresent | Should Be $true
        ($observation.RootProcessIds -contains 20) | Should Be $true
        ($observation.AllPackageProcessIds -contains 10) | Should Be $false
    }

    It 'does not trust a version-shaped path without selected metadata or an exact persisted override' {
        $package = [ordered]@{
            Found = $true
            DesktopExecutable = 'C:\Program Files\WindowsApps\OpenAI.Codex_2.0\app\ChatGPT.exe'
            AppServerExecutable = 'C:\Program Files\WindowsApps\OpenAI.Codex_2.0\app\resources\codex.exe'
            AppServerBinRoot = 'C:\Users\Tester\AppData\Local\OpenAI\Codex\bin'
        }
        $processes = @(
            [pscustomobject]@{ ProcessId = 20; ParentProcessId = 1; Name = 'ChatGPT.exe'; ExecutablePath = $package.DesktopExecutable; CommandLine = 'desktop'; CreationDate = [DateTime]::UtcNow.AddMinutes(-2) }
            [pscustomobject]@{ ProcessId = 21; ParentProcessId = 20; Name = 'codex.exe'; ExecutablePath = 'C:\Users\Tester\AppData\Local\OpenAI\Codex\bin\d0097be4feba73d0\codex.exe'; CommandLine = 'codex.exe -c features.code_mode_host=true app-server --analytics-default-enabled'; CreationDate = [DateTime]::UtcNow.AddMinutes(-1) }
            [pscustomobject]@{ ProcessId = 22; ParentProcessId = 20; Name = 'codex.exe'; ExecutablePath = 'C:\Tools\codex.exe'; CommandLine = 'codex.exe app-server'; CreationDate = [DateTime]::UtcNow.AddMinutes(-1) }
            [pscustomobject]@{ ProcessId = 23; ParentProcessId = 999; Name = 'codex.exe'; ExecutablePath = 'C:\Users\Tester\AppData\Local\OpenAI\Codex\bin\other-version\codex.exe'; CommandLine = 'codex.exe app-server'; CreationDate = [DateTime]::UtcNow.AddMinutes(-1) }
            [pscustomobject]@{ ProcessId = 24; ParentProcessId = 20; Name = 'codex.exe'; ExecutablePath = 'C:\Users\Tester\AppData\Local\OpenAI\Codex\bin\other-version\codex.exe'; CommandLine = 'codex.exe exec task'; CreationDate = [DateTime]::UtcNow.AddMinutes(-1) }
        )

        $observation = Get-CodexProcessObservation -Package $package -Processes $processes

        $observation.AppServerPresent | Should Be $false
        $observation.AppServerStatus | Should Be 'Unknown'
        @($observation.UnknownAppServerProcessIds) | Should Be @(21,22)
        foreach ($unrelatedId in @(21, 22, 23, 24)) {
            ($observation.AllPackageProcessIds -contains $unrelatedId) | Should Be $false
        }
    }
}

Describe 'Hidden scheduled-task launcher' {
    It 'uses the GUI script host to start PowerShell with no visible window' {
        $config = Get-WatchdogConfig
        (Test-Path -LiteralPath $config.LauncherPath -PathType Leaf) | Should Be $true
        $launcher = Get-Content -LiteralPath $config.LauncherPath -Raw
        ($launcher -match 'shell\.Run\(command, 0, True\)') | Should Be $true
    }
}

Describe 'Configured core recognition and safe uncertainty' {
    BeforeEach {
        $config=Get-WatchdogConfig
        $now=[DateTimeOffset]::Parse('2026-10-18T09:30:00Z')
        $state=New-WatchdogState
        $fixture=Join-Path $TestDrive ('ядро с пробелами '+[guid]::NewGuid())
        $core=Join-Path $fixture 'current\codex.exe'
        $oldCore=Join-Path $fixture 'old\codex.exe'
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $core),(Split-Path -Parent $oldCore) -Force
        Set-Content -LiteralPath $core,$oldCore -Value 'executable fixture; never executed'
        $package=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
            AppServerExecutable='C:\WindowsApps\OpenAI.Codex_fixture\app\resources\codex.exe'
            AppServerBinRoot='C:\Users\Fixture\AppData\Local\OpenAI\Codex\bin'
            AppServerOverride=(Get-CodexAppServerOverride -EnvironmentValues @{User=$core;Machine='';Process=$oldCore})
        }
        $main=[pscustomobject]@{ProcessId=20;ParentProcessId=1;Name='ChatGPT.exe';ExecutablePath=$package.DesktopExecutable;CommandLine='desktop';CreationDate=$now.AddMinutes(-20)}
        $server=[pscustomobject]@{ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$core;CommandLine='codex.exe -c features.code_mode_host=true app-server --analytics-default-enabled';CreationDate=$now.AddMinutes(-19)}
    }

    It 'prefers fresh persisted User and Machine values to a stale inherited environment' {
        $package.AppServerOverride.Executable | Should Be ([IO.Path]::GetFullPath($core))
        $package.AppServerOverride.Source | Should Be 'User'
        $machine=Get-CodexAppServerOverride -EnvironmentValues @{User='';Machine=$core;Process=$oldCore}
        $machine.Executable | Should Be ([IO.Path]::GetFullPath($core))
        $machine.Source | Should Be 'Machine'
        $process=Get-CodexAppServerOverride -EnvironmentValues @{User='';Machine='';Process=$oldCore}
        $process.Executable | Should Be ''
        $process.Source | Should Be 'None'
    }

    It 'rejects invalid selected overrides without silently using an older core' {
        foreach($invalid in @('codex.exe',(Join-Path $fixture 'missing\codex.exe'),(Join-Path $fixture 'other.exe'))){
            $resolved=Get-CodexAppServerOverride -EnvironmentValues @{User=$invalid;Machine=$core;Process=$oldCore}
            $resolved.Executable | Should Be ''
            $resolved.Source | Should Be 'User'
            [bool]$resolved.Error | Should Be $true
        }
        $empty=Get-CodexAppServerOverride -EnvironmentValues @{}
        $empty.Source | Should Be 'None'
        $empty.Executable | Should Be ''
    }

    It 'recognizes only the exact configured file with the installed main ancestry and server role' {
        $recognized=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $recognized.AppServerPresent | Should Be $true
        $recognized.AppServerStatus | Should Be 'Recognized'
        @($recognized.AppServerProcessIds) | Should Be @(21)
        ($recognized.AllPackageProcessIds -contains 21) | Should Be $true
        $observation=New-TestObservation
        $observation.TimestampUtc=$now.ToString('o');$observation.Process=$recognized;$observation.Package=$package
        $public=ConvertTo-PublicResult -Observation $observation -Decision (New-WatchdogDecision -Action None -Reason HealthyIdle)
        $public.appServerStatus | Should Be 'Recognized'
        ($public.unknownAppServerProcessIds -is [array]) | Should Be $true
        @($public.unknownAppServerProcessIds).Count | Should Be 0
        $server.ParentProcessId=999
        $foreignParent=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $foreignParent.AppServerStatus | Should Be 'Missing'
        $foreignParent.AppServerPresent | Should Be $false
        @($foreignParent.UnknownAppServerProcessIds).Count | Should Be 0
        $server.ParentProcessId=20;$server.CommandLine='codex.exe exec task'
        (Get-CodexProcessObservation -Package $package -Processes @($main,$server)).AppServerStatus | Should Be 'Missing'
        $server.CommandLine='codex.exe app-server';$main.ExecutablePath='C:\Other\ChatGPT.exe'
        $foreignMain=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $foreignMain.DesktopPresent | Should Be $false
        $foreignMain.AppServerPresent | Should Be $false
    }

    It 'keeps stock and the exact configured legacy path recognized without accepting arbitrary versions' {
        $server.ExecutablePath=$core
        $legacy=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $legacy.AppServerPresent | Should Be $true
        $legacy.AppServerStatus | Should Be 'Recognized'

        $stockPackage=[ordered]@{
            Found=$true;Version=$package.Version;DesktopExecutable=$package.DesktopExecutable
            AppServerExecutable=$package.AppServerExecutable;AppServerBinRoot=$package.AppServerBinRoot
            AppServerOverride=[ordered]@{Executable='';Source='None';Error=$null;Managed=$false;HashVerified=$true;Sha256=''}
        }
        $server.ExecutablePath=$package.AppServerExecutable
        $stock=Get-CodexProcessObservation -Package $stockPackage -Processes @($main,$server)
        $stock.AppServerPresent | Should Be $true
        $stock.SelectedCorePresent | Should Be $true
        $stock.CoreSelection.Path | Should Be $package.AppServerExecutable

        $server.ExecutablePath=$package.AppServerExecutable
        $selectedOverride=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $selectedOverride.AppServerStatus | Should Be 'Unknown'
        $selectedOverride.SelectedCorePresent | Should Be $false

        $server.ExecutablePath=Join-Path $package.AppServerBinRoot 'future-build\codex.exe'
        $unconfigured=Get-CodexProcessObservation -Package $stockPackage -Processes @($main,$server)
        $unconfigured.AppServerStatus | Should Be 'Unknown'
    }

    It 'pauses automatic recovery when an override changes while its old direct server is still alive' {
        $server.ExecutablePath=$oldCore
        $unknown=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $unknown.AppServerPresent | Should Be $false
        $unknown.AppServerStatus | Should Be 'Unknown'
        @($unknown.UnknownAppServerProcessIds) | Should Be @(21)
        @($unknown.UnknownAppServerExecutables) | Should Be @($oldCore)
        ($unknown.AllPackageProcessIds -contains 21) | Should Be $false
        $observation=New-TestObservation -RemoteRepeatedFailure $true
        $observation.Process=$unknown
        $observation.Package=$package
        $state.appServerMissingSinceUtc=$now.AddHours(-1).ToString('o');$state.appServerMissingChecks=25
        $decision=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Manual'
        $decision.Reason | Should Be 'UnrecognizedAppServer'
        $state.appServerMissingChecks | Should Be 0
        ($null -eq $state.appServerMissingSinceUtc) | Should Be $true
        $validation=Get-TriggerValidationReport -Decision $decision -Observation $observation -State $state -Config $config -Now $now
        $validation.checks[0].name | Should Be 'AppServerExecutableRecognized'
    }

    It 'protects an unreadable direct server but does not recognize unknown nested CLI servers' {
        $server.ExecutablePath=$null
        (Get-CodexProcessObservation -Package $package -Processes @($main,$server)).AppServerStatus | Should Be 'Unknown'
        $server.ExecutablePath=$oldCore;$server.CommandLine=''
        $unreadableRole=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $unreadableRole.AppServerStatus | Should Be 'Unknown'
        $tool=[pscustomobject]@{ProcessId=30;ParentProcessId=20;Name='codex.exe';ExecutablePath=$core;CommandLine='codex.exe exec tool'}
        $server.CommandLine='codex.exe app-server';$server.ParentProcessId=30
        $nested=Get-CodexProcessObservation -Package $package -Processes @($main,$tool,$server)
        $nested.AppServerStatus | Should Be 'Missing'
        @($nested.UnknownAppServerProcessIds).Count | Should Be 0
        $server.ParentProcessId=20;$server.ExecutablePath=$core
        $unknownAlongsideKnown=Get-CodexProcessObservation -Package $package -Processes @($main,$server,([pscustomobject]@{
            ProcessId=22;ParentProcessId=20;Name='codex.exe';ExecutablePath=$oldCore;CommandLine='codex.exe app-server';CreationDate=$now.AddMinutes(-18)
        }))
        $unknownAlongsideKnown.AppServerPresent | Should Be $true
        $unknownAlongsideKnown.AppServerStatus | Should Be 'Unknown'
        $validation=Get-RecoveryValidationReport -BeforePackage $package -AfterPackage $package -Process $unknownAlongsideKnown -Integrity ([ordered]@{State='ok';Logs='ok'}) -Enrollment ([ordered]@{Status='Enabled';EnabledCount=1})
        @($validation.checks|Where-Object { $_.name -eq 'AppServerExecutableRecognized' -and $_.status -eq 'failed' }).Count | Should Be 1
    }

    It 'never closes or stops any process when a direct unknown server is alive' {
        $server.ExecutablePath=$oldCore
        $script:unknownObservation=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $script:stopGuardPackage=$package
        Mock Get-CodexProcessObservation { $script:unknownObservation } -ParameterFilter { [object]::ReferenceEquals($Package,$script:stopGuardPackage) }
        Mock Get-Process { throw 'Process lookup/close must not be reached.' }
        Mock Stop-Process { throw 'No process may be stopped.' }
        $failure=$null
        try{Stop-CodexPackageProcesses -Package $package -Config $config}catch{$failure=$_}
        $failure.Exception.Message | Should Be 'An unrecognized live Codex app-server was found; refusing to close or stop the application.'
        Assert-MockCalled Get-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }

    It 'retains the observation window and recovery decision for a genuinely missing server' {
        $observation=New-TestObservation -AppServerPresent $false
        $observation.Process=Get-CodexProcessObservation -Package $package -Processes @($main)
        $observation.Process.AppServerStatus | Should Be 'Missing'
        $initial=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $initial.Reason | Should Be 'AppServerMissingObservationWindow'
        $later=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now.AddMinutes(6)
        $later.Reason | Should Be 'AppServerMissingObservationWindow'
        $confirmed=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now.AddMinutes(7)
        $confirmed.Action | Should Be 'Restart'
        $confirmed.Reason | Should Be 'AppServerMissing'
    }
}

Describe 'Cached stock core identity' {
    BeforeEach {
        $fixture=New-StockCacheFixture -Root (Join-Path $TestDrive ('stock cache '+[guid]::NewGuid()))
        $package=$fixture.Package
        $now=[DateTimeOffset]::Parse('2026-10-26T12:00:00Z')
        $main=[pscustomobject]@{
            ProcessId=20;ParentProcessId=1;Name='ChatGPT.exe';ExecutablePath=$package.DesktopExecutable
            CommandLine='desktop';CreationDate=$now.AddMinutes(-2)
        }
        $server=[pscustomobject]@{
            ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$fixture.Cached
            CommandLine='codex.exe app-server --analytics-default-enabled';CreationDate=$now.AddMinutes(-1)
        }
    }

    It 'accepts only the bundled core or a fixed-depth non-reparse cache copy matching its size and hash' {
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $package.AppServerExecutable) | Should Be $true
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $fixture.Cached) | Should Be $true

        $shortHashPath=Join-Path $package.AppServerBinRoot '1234567890ABCDE\codex.exe'
        $nestedPath=Join-Path $package.AppServerBinRoot 'nested\2993767bd1dfb009\codex.exe'
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $shortHashPath),(Split-Path -Parent $nestedPath) -Force
        [IO.File]::WriteAllText($shortHashPath,'fixture package stock core; never executed',[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($nestedPath,'fixture package stock core; never executed',[Text.UTF8Encoding]::new($false))
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $shortHashPath) | Should Be $false
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $nestedPath) | Should Be $false

        [IO.File]::WriteAllText($fixture.Cached,'tampered',[Text.UTF8Encoding]::new($false))
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $fixture.Cached) | Should Be $false
    }

    It 'rejects a cache path with a reparse point and an app-server older than its Desktop parent' {
        $script:reparseStockPath=$fixture.Cached
        Mock Test-CodexPathHasReparsePoint { $true } -ParameterFilter { $Path -ieq $script:reparseStockPath }
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $fixture.Cached) | Should Be $false

        $script:reparseStockPath=$package.AppServerExecutable
        Mock Test-CodexPathHasReparsePoint { [bool]($Path -ieq $script:reparseStockPath) }
        (Test-CodexStockAppServerExecutablePath -Package $package -ExecutablePath $fixture.Cached) | Should Be $false

        $server.CreationDate=$main.CreationDate.AddTicks(-1)
        $olderChild=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $olderChild.AppServerStatus | Should Be 'Unknown'
        $olderChild.SelectedCorePresent | Should Be $false
    }

    It 'recognizes the cached stock core only as a timestamp-bound previous process during a custom handover' {
        $stockObservation=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $state=New-WatchdogState
        $healthy=[ordered]@{
            Package=$package;Process=$stockObservation;Integrity=[ordered]@{Healthy=$true}
            Enrollment=[ordered]@{Status='Enabled'};Remote=[ordered]@{ManualCondition=$false}
        }
        (Set-LastHealthyCoreFromObservation -State $state -Observation $healthy -Now $now) | Should Be $true

        $custom=New-ManagedCoreFixture -Root (Join-Path $TestDrive ('selected custom '+[guid]::NewGuid())) -Version 'future-custom'
        $customPackage=[ordered]@{
            Found=$true;Version=$package.Version;DesktopExecutable=$package.DesktopExecutable
            AppServerExecutable=$package.AppServerExecutable;AppServerBinRoot=$package.AppServerBinRoot
            AppServerOverride=[ordered]@{
                Executable=$custom.Path;Source='User';Error=$null;Managed=$true;HashVerified=$true
                MetadataValidated=$true;Sha256=$custom.Hash;Version=$custom.Version
            }
        }

        $withoutSnapshot=Get-CodexProcessObservation -Package $customPackage -Processes @($main,$server)
        $withoutSnapshot.AppServerStatus | Should Be 'Unknown'
        $withoutSnapshot.SelectedCorePresent | Should Be $false

        $handover=Get-CodexProcessObservation -Package $customPackage -Processes @($main,$server) -TrustedPreviousCore $state.lastHealthyCore
        $handover.AppServerStatus | Should Be 'Recognized'
        $handover.TrustedPreviousCorePresent | Should Be $true
        $handover.SelectedCorePresent | Should Be $false
        $handover.CoreSwitchPending | Should Be $true

    }

    It 'requires cached stock app servers to be direct Desktop children when selected or trusted previous' {
        $stockObservation=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $state=New-WatchdogState
        $healthy=[ordered]@{
            Package=$package;Process=$stockObservation;Integrity=[ordered]@{Healthy=$true}
            Enrollment=[ordered]@{Status='Enabled'};Remote=[ordered]@{ManualCondition=$false}
        }
        (Set-LastHealthyCoreFromObservation -State $state -Observation $healthy -Now $now) | Should Be $true

        $nestedParent=[pscustomobject]@{
            ProcessId=22;ParentProcessId=20;Name='codex.exe';ExecutablePath=(Join-Path $package.AppServerBinRoot 'tool\codex.exe')
            CommandLine='codex.exe cli-tool';CreationDate=$now.AddSeconds(10)
        }
        $server.ParentProcessId=22
        $nestedSelected=Get-CodexProcessObservation -Package $package -Processes @($main,$nestedParent,$server)
        $nestedSelected.SelectedCorePresent | Should Be $false
        $nestedSelected.AppServerStatus | Should Be 'Missing'

        $custom=New-ManagedCoreFixture -Root (Join-Path $TestDrive ('nested custom '+[guid]::NewGuid())) -Version 'future-nested'
        $customPackage=[ordered]@{
            Found=$true;Version=$package.Version;DesktopExecutable=$package.DesktopExecutable
            AppServerExecutable=$package.AppServerExecutable;AppServerBinRoot=$package.AppServerBinRoot
            AppServerOverride=[ordered]@{
                Executable=$custom.Path;Source='User';Error=$null;Managed=$true;HashVerified=$true
                MetadataValidated=$true;Sha256=$custom.Hash;Version=$custom.Version
            }
        }
        $nestedPrevious=Get-CodexProcessObservation -Package $customPackage -Processes @($main,$nestedParent,$server) `
            -TrustedPreviousCore $state.lastHealthyCore
        $nestedPrevious.TrustedPreviousCorePresent | Should Be $false
        $nestedPrevious.AppServerStatus | Should Be 'Missing'
    }

    It 'keeps the canonical stock selection and readiness while the Desktop runs its verified cache copy' {
        $selected=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $selected.AppServerStatus | Should Be 'Recognized'
        $selected.SelectedCorePresent | Should Be $true
        $selected.CoreSelection.Kind | Should Be 'Stock'
        $selected.CoreSelection.Path | Should Be $package.AppServerExecutable
        $selected.AppServerProcessIdentities[0].executablePath | Should Be $fixture.Cached

        $state=New-WatchdogState
        $healthy=[ordered]@{
            Package=$package;Process=$selected;Integrity=[ordered]@{Healthy=$true}
            Enrollment=[ordered]@{Status='Enabled'};Remote=[ordered]@{ManualCondition=$false}
        }
        (Set-LastHealthyCoreFromObservation -State $state -Observation $healthy -Now $now) | Should Be $true
        $state.lastHealthyCore.core.path | Should Be $package.AppServerExecutable
        $state.lastHealthyCore.process.executablePath | Should Be $fixture.Cached

    }

    It 'uses canonical stock selection for readiness and rejects cached stock as selected custom readiness' {
        $stockSelection=Get-CodexDesiredCoreIdentity -Package $package
        $stockObservation=Get-CodexProcessObservation -Package $package -Processes @($main,$server)
        $state=New-WatchdogState
        $healthy=[ordered]@{
            Package=$package;Process=$stockObservation;Integrity=[ordered]@{Healthy=$true}
            Enrollment=[ordered]@{Status='Enabled'};Remote=[ordered]@{ManualCondition=$false}
        }
        (Set-LastHealthyCoreFromObservation -State $state -Observation $healthy -Now $now) | Should Be $true

        $custom=New-ManagedCoreFixture -Root (Join-Path $TestDrive ('readiness custom '+[guid]::NewGuid())) -Version 'future-readiness'
        $customPackage=[ordered]@{
            Found=$true;Version=$package.Version;DesktopExecutable=$package.DesktopExecutable
            AppServerExecutable=$package.AppServerExecutable;AppServerBinRoot=$package.AppServerBinRoot
            AppServerOverride=[ordered]@{
                Executable=$custom.Path;Source='User';Error=$null;Managed=$true;HashVerified=$true
                MetadataValidated=$true;Sha256=$custom.Hash;Version=$custom.Version
            }
        }
        $customSelection=Get-CodexDesiredCoreIdentity -Package $customPackage
        $handover=Get-CodexProcessObservation -Package $customPackage -Processes @($main,$server) -TrustedPreviousCore $state.lastHealthyCore
        $handover.AppServerStatus | Should Be 'Recognized'
        $handover.SelectedCorePresent | Should Be $false

        $script:readinessPackage=$package
        $script:readinessObservation=$stockObservation
        Mock Start-Sleep {}
        Mock Get-CodexPackageInfo { $script:readinessPackage }
        Mock Get-CodexProcessObservation { $script:readinessObservation }
        $stockReady=Wait-CodexHealthyProcesses -Config (Get-WatchdogConfig) -InitialPackage $package `
            -TimeoutSeconds 0 -ExpectedCore $stockSelection
        $stockReady.Ready | Should Be $true

        $script:readinessPackage=$customPackage
        $script:readinessObservation=$handover
        $customReady=Wait-CodexHealthyProcesses -Config (Get-WatchdogConfig) -InitialPackage $customPackage `
            -TimeoutSeconds 0 -ExpectedCore $customSelection -TrustedPreviousCore $state.lastHealthyCore
        $customReady.Ready | Should Be $false
    }
}

Describe 'Desktop initialization handshake verification' {
    BeforeEach {
        $script:handshakeLogsRoot=Join-Path $TestDrive ('desktop-log-fixture '+[guid]::NewGuid())
        $null=New-Item -ItemType Directory -Path $script:handshakeLogsRoot -Force
        $script:handshakeRootStart=[DateTimeOffset]::Parse('2026-10-26T18:31:20.0000000Z')
        $script:handshakeTimestamp=$script:handshakeRootStart.AddSeconds(5)
        $script:handshakeProcessId=74123
        $script:handshakeRootPath=Join-Path $TestDrive 'synthetic-app\ChatGPT.exe'
        $script:handshakeRootIdentity=[ordered]@{
            processId=$script:handshakeProcessId;startedUtc=$script:handshakeRootStart.ToString('o')
            executablePath=$script:handshakeRootPath
        }
        $script:handshakeLogsConfig=Get-WatchdogConfig
        $script:handshakeLogsConfig.DesktopLogsRoot=$script:handshakeLogsRoot
        $script:handshakeEventLine='{0} [AppServerConnection] initialize_handshake_result outcome=success transportKind=stdio' -f $script:handshakeTimestamp.ToString('o')
    }

    It 'finds a current PID handshake in bounded file-head and file-tail slices' {
        $path=Write-TestDesktopHandshakeFile -LogsRoot $script:handshakeLogsRoot -FileProcessId $script:handshakeProcessId `
            -Timestamp $script:handshakeTimestamp -Line $script:handshakeEventLine -Payload ('x'*700000)
        $head=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $head.AllRequiredProcessesVerified | Should Be $true
        $head.VerifiedProcessIds | Should Be @($script:handshakeProcessId)
        $head.Status | Should Be 'Verified'
        ($head|ConvertTo-Json -Compress) | Should Not Match 'initialize_handshake_result|xxxx'

        [IO.File]::WriteAllText($path,('x'*700000)+[Environment]::NewLine+$script:handshakeEventLine+[Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        $tail=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $tail.AllRequiredProcessesVerified | Should Be $true
    }

    It 'rejects old, wrong-PID, websocket, failed and embedded handshake text' {
        $wrongPidPath=Write-TestDesktopHandshakeFile -LogsRoot $script:handshakeLogsRoot `
            -FileProcessId ($script:handshakeProcessId+1) -Timestamp $script:handshakeTimestamp -Line $script:handshakeEventLine
        $wrongPid=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $wrongPid.AllRequiredProcessesVerified | Should Be $false
        $wrongPid.Status | Should Be 'NoPidLogs'

        $path=Write-TestDesktopHandshakeFile -LogsRoot $script:handshakeLogsRoot -FileProcessId $script:handshakeProcessId `
            -Timestamp $script:handshakeRootStart.AddSeconds(-1) `
            -Line ('{0} [AppServerConnection] initialize_handshake_result outcome=success transportKind=stdio' -f $script:handshakeRootStart.AddSeconds(-1).ToString('o'))
        $old=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $old.AllRequiredProcessesVerified | Should Be $false

        [IO.File]::WriteAllText($path,('{0} [AppServerConnection] initialize_handshake_result outcome=success transportKind=websocket' -f $script:handshakeTimestamp.ToString('o')),[Text.UTF8Encoding]::new($false))
        $websocket=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $websocket.AllRequiredProcessesVerified | Should Be $false

        [IO.File]::WriteAllText($path,('{0} [AppServerConnection] initialize_handshake_result outcome=error transportKind=stdio' -f $script:handshakeTimestamp.ToString('o')),[Text.UTF8Encoding]::new($false))
        $failed=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $failed.AllRequiredProcessesVerified | Should Be $false

        [IO.File]::WriteAllText($path,('{0} [OtherLogger] payload contains [AppServerConnection] initialize_handshake_result outcome=success transportKind=stdio' -f $script:handshakeTimestamp.ToString('o')),[Text.UTF8Encoding]::new($false))
        $embedded=Get-CodexDesktopHandshakeObservation -Config $script:handshakeLogsConfig `
            -RootProcessIdentities @($script:handshakeRootIdentity) -RequiredProcessIds @($script:handshakeProcessId)
        $embedded.AllRequiredProcessesVerified | Should Be $false
    }
}

Describe 'Desktop handshake readiness gate' {
    BeforeEach {
        $script:handshakeWaitLogs=Join-Path $TestDrive ('wait-handshake-logs '+[guid]::NewGuid())
        $null=New-Item -ItemType Directory -Path $script:handshakeWaitLogs -Force
        $script:handshakeWaitConfig=Get-WatchdogConfig
        $script:handshakeWaitConfig.DesktopLogsRoot=$script:handshakeWaitLogs
        $script:handshakeWaitStart=[DateTimeOffset]::UtcNow.AddMinutes(-2)
        $script:handshakeWaitPid=84231
        $script:handshakeWaitPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=(Join-Path $TestDrive 'wait-app\ChatGPT.exe')
            AppServerExecutable=(Join-Path $TestDrive 'wait-app\resources\codex.exe');AppServerOverride=$null
        }
        $script:handshakeWaitExpected=Get-CodexDesiredCoreIdentity -Package $script:handshakeWaitPackage
        $script:handshakeWaitRootIdentity=[ordered]@{
            processId=$script:handshakeWaitPid;startedUtc=$script:handshakeWaitStart.ToString('o')
            executablePath=$script:handshakeWaitPackage.DesktopExecutable
        }
        $script:handshakeWaitProcess=[ordered]@{
            CoreSelection=$script:handshakeWaitExpected;DesktopPresent=$true;SelectedCorePresent=$true
            TrustedPreviousCorePresent=$false;AppServerStatus='Recognized'
            RootProcessIdentities=@($script:handshakeWaitRootIdentity)
            AppServerProcessIdentities=@([ordered]@{classification='Stock';desktopProcessId=$script:handshakeWaitPid})
        }
        Mock Start-Sleep {}
        Mock Get-CodexPackageInfo { $script:handshakeWaitPackage }
        Mock Get-CodexProcessObservation { $script:handshakeWaitProcess }
    }

    It 'keeps ordinary readiness unchanged but blocks selected-core readiness without a current handshake' {
        $ordinary=Wait-CodexHealthyProcesses -Config $script:handshakeWaitConfig -InitialPackage $script:handshakeWaitPackage `
            -TimeoutSeconds 0 -ExpectedCore $script:handshakeWaitExpected
        $ordinary.Ready | Should Be $true
        $ordinary.DesktopHandshake | Should Be $null

        $protected=Wait-CodexHealthyProcesses -Config $script:handshakeWaitConfig -InitialPackage $script:handshakeWaitPackage `
            -TimeoutSeconds 0 -ExpectedCore $script:handshakeWaitExpected -RequireDesktopHandshake
        $protected.Ready | Should Be $false
        $protected.DesktopHandshake.AllRequiredProcessesVerified | Should Be $false
        $protected.DesktopHandshake.Status | Should Be 'NoPidLogs'

        $stamp=$script:handshakeWaitStart.AddSeconds(10)
        $line='{0} [AppServerConnection] initialize_handshake_result outcome=success transportKind=stdio' -f $stamp.ToString('o')
        $null=Write-TestDesktopHandshakeFile -LogsRoot $script:handshakeWaitLogs -FileProcessId $script:handshakeWaitPid `
            -Timestamp $stamp -Line $line
        $verified=Wait-CodexHealthyProcesses -Config $script:handshakeWaitConfig -InitialPackage $script:handshakeWaitPackage `
            -TimeoutSeconds 0 -ExpectedCore $script:handshakeWaitExpected -RequireDesktopHandshake
        $verified.Ready | Should Be $true
        $verified.DesktopHandshake.AllRequiredProcessesVerified | Should Be $true
    }
}

Describe 'Managed core switching and rollback gates' {
    BeforeEach {
        $config=Get-WatchdogConfig
        $now=[DateTimeOffset]::Parse('2026-10-26T10:00:00Z')
        $state=New-WatchdogState
        $root=Join-Path $TestDrive ('portable runtime '+[guid]::NewGuid())
        $old=New-ManagedCoreFixture -Root (Join-Path $root 'old') -Version '1.0.1'
        $new=New-ManagedCoreFixture -Root (Join-Path $root 'new') -Version 'future-build-2029.7' -RootManifest
        $stock='C:\WindowsApps\OpenAI.Codex_fixture\app\resources\codex.exe'
        $desktop='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
        $newPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=[ordered]@{Executable=$new.Path;Source='User';Error=$null;Managed=$true;MetadataValidated=$true;HashVerified=$true;Sha256=$new.Hash;Version=$new.Version;MetadataPath=$new.ManifestPath}
        }
        $previous=New-ManagedCoreProcessFixture -Now $now -DesktopPath $desktop -CorePath $old.Path
        $state.lastHealthyCore=[ordered]@{
            selector=[ordered]@{source='User';path=$old.Path}
            core=[ordered]@{kind='Managed';path=$old.Path;sha256=$old.Hash;version=$old.Version}
            process=[ordered]@{pid=21;startUtc=$previous.ServerStartUtc;desktopPid=20;desktopStartUtc=$previous.DesktopStartUtc}
            healthyAtUtc=$now.AddMinutes(-2).ToString('o')
        }
        $oldProcessSet=Get-CodexProcessObservation -Package $newPackage -Processes @($previous.Desktop,$previous.Server) -TrustedPreviousCore $state.lastHealthyCore
        $observation=New-TestObservation
        $observation.Package=$newPackage
        $observation.Process=$oldProcessSet
    }

    It 'validates a future runtime version through its root manifest without a version allowlist' {
        $resolved=Get-CodexAppServerOverride -EnvironmentValues @{User=$new.Path;Machine=''}
        $resolved.Error | Should Be $null
        $resolved.Managed | Should Be $true
        $resolved.MetadataValidated | Should Be $true
        $resolved.HashVerified | Should Be $true
        $resolved.Version | Should Be 'future-build-2029.7'
        $resolved.Sha256 | Should Be $new.Hash
    }

    It 'uses the archived manifest for the old core after a same-root legacy upgrade and rejects tampered archives' {
        $upgrade=New-LegacyUpgradeFixture -Root (Join-Path $TestDrive ('legacy compactfix '+[guid]::NewGuid()))
        $oldSelected=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        $newSelected=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.New.Path;Machine=''}
        $oldSelected.Error | Should Be $null
        $oldSelected.Managed | Should Be $true
        $oldSelected.HashVerified | Should Be $true
        $oldSelected.Sha256 | Should Be $upgrade.Old.Hash
        $newSelected.Error | Should Be $null

        $desktop='C:\WindowsApps\OpenAI.Codex_fixture\app\ChatGPT.exe'
        $stock='C:\WindowsApps\OpenAI.Codex_fixture\app\resources\codex.exe'
        $handoverPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=$newSelected
        }
        $runningOld=New-ManagedCoreProcessFixture -Now $now -DesktopPath $desktop -CorePath $upgrade.Old.Path
        $handoverState=New-WatchdogState
        $handoverState.lastHealthyCore=[ordered]@{
            selector=[ordered]@{source='User';path=$upgrade.Old.Path}
            core=[ordered]@{kind='Managed';path=$upgrade.Old.Path;sha256=$upgrade.Old.Hash;version=$upgrade.Old.Version}
            process=[ordered]@{pid=21;startUtc=$runningOld.ServerStartUtc;desktopPid=20;desktopStartUtc=$runningOld.DesktopStartUtc}
            healthyAtUtc=$now.AddMinutes(-1).ToString('o')
        }
        $handover=Get-CodexProcessObservation -Package $handoverPackage -Processes @($runningOld.Desktop,$runningOld.Server) -TrustedPreviousCore $handoverState.lastHealthyCore
        $handover.TrustedPreviousCorePresent | Should Be $true
        $handover.CoreSwitchPending | Should Be $true
        $handover.AppServerProcessIdentities[0].classification | Should Be 'TrustedPrevious'
        $publicObservation=New-TestObservation
        $publicObservation.TimestampUtc=$now.ToString('o')
        $publicObservation.Package=$handoverPackage
        $publicObservation.Process=$handover
        $publicObservation.Threads=@()
        $public=ConvertTo-PublicResult -Observation $publicObservation -Decision (New-WatchdogDecision -Action None -Reason CoreSelectionChanged)
        $public.core.selection.path | Should Be $upgrade.New.Path
        $public.core.selection.sha256 | Should Be $upgrade.New.Hash
        $public.core.selection.hashVerified | Should Be $true
        $public.core.selectedPresent | Should Be $false
        $public.core.pending | Should Be $true
        $public.core.ready | Should Be $false
        $public.core.active[0].classification | Should Be 'TrustedPrevious'
        $public.core.active[0].processId | Should Be 21
        $public.appServerOverride.Contains('RawValue') | Should Be $false
        $public.appServerOverride.Contains('RegistryKind') | Should Be $false

        # The post-rollback User selection resolves through the archived .1 manifest as well.
        $afterRollback=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        $afterRollback.Error | Should Be $null
        $afterRollback.HashVerified | Should Be $true
        $afterRollback.Sha256 | Should Be $upgrade.Old.Hash

        $archiveText=Get-Content -LiteralPath $upgrade.ArchiveManifest -Raw
        $archive=ConvertFrom-Json -InputObject $archiveText -AsHashtable
        $archive.components[0].sha256='0000000000000000000000000000000000000000000000000000000000000000'
        [IO.File]::WriteAllText($upgrade.ArchiveManifest,($archive|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $tamperedArchive=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        [bool]$tamperedArchive.Error | Should Be $true
        [IO.File]::WriteAllText($upgrade.ArchiveManifest,$archiveText,[Text.UTF8Encoding]::new($false))
        [IO.File]::WriteAllText($upgrade.ArchiveManifest,'{ malformed',[Text.UTF8Encoding]::new($false))
        $malformedArchive=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        [bool]$malformedArchive.Error | Should Be $true
        [IO.File]::WriteAllText($upgrade.ArchiveManifest,$archiveText,[Text.UTF8Encoding]::new($false))

        $currentManifestText=Get-Content -LiteralPath $upgrade.New.ManifestPath -Raw
        $currentManifest=ConvertFrom-Json -InputObject $currentManifestText -AsHashtable
        $currentManifest.components[0].sha256='FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF'
        [IO.File]::WriteAllText($upgrade.New.ManifestPath,($currentManifest|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
        $tamperedCurrent=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        [bool]$tamperedCurrent.Error | Should Be $true
        [IO.File]::WriteAllText($upgrade.New.ManifestPath,$currentManifestText,[Text.UTF8Encoding]::new($false))

        [IO.File]::WriteAllText($upgrade.New.ManifestPath,'{ malformed',[Text.UTF8Encoding]::new($false))
        $malformedCurrent=Get-CodexAppServerOverride -EnvironmentValues @{User=$upgrade.Old.Path;Machine=''}
        [bool]$malformedCurrent.Error | Should Be $true
    }

    It 'rejects a tampered managed core and a versioned runtime with missing metadata' {
        Add-Content -LiteralPath $new.Path -Value 'tampered'
        $tampered=Get-CodexAppServerOverride -EnvironmentValues @{User=$new.Path;Machine=''}
        [bool]$tampered.Error | Should Be $true
        $missingRoot=Join-Path $TestDrive ('missing metadata '+[guid]::NewGuid())
        $missing=Join-Path $missingRoot 'runtime\unlisted-build\bin\codex.exe'
        $null=New-Item -ItemType Directory -Path (Split-Path -Parent $missing) -Force
        Set-Content -LiteralPath $missing -Value 'fixture'
        $unmanifested=Get-CodexAppServerOverride -EnvironmentValues @{User=$missing;Machine=''}
        [bool]$unmanifested.Error | Should Be $true
    }

    It 'recognizes the hash-verified previous core and requests one switch to the selected future core' {
        $observation.Process.CoreSwitchPending | Should Be $true
        $observation.Process.TrustedPreviousCorePresent | Should Be $true
        $observation.Process.AppServerStatus | Should Be 'Recognized'
        $observation.Process.AppServerProcessIdentities[0].classification | Should Be 'TrustedPrevious'
        $decision=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'Restart'
        $decision.Reason | Should Be 'CoreSelectionChanged'
    }

    It 'recognizes a trusted previous core after saved and copied state round trips with subsecond offsets' {
        $config.DataRoot=Join-Path $TestDrive 'timestamp-roundtrip-state'
        $config.StatePath=Join-Path $config.DataRoot 'state.json'
        $config.SnapshotRoot=Join-Path $config.DataRoot 'snapshots'
        $desktopStart=[DateTimeOffset]::Parse('2026-10-26T12:00:00.1234567+03:00')
        $serverStart=[DateTimeOffset]::Parse('2026-10-26T05:00:01.7654321-04:00')
        $state.lastHealthyCore.process.startUtc=$serverStart.ToString('o')
        $state.lastHealthyCore.process.desktopStartUtc=$desktopStart.ToString('o')
        Save-WatchdogState -Config $config -State $state
        $loaded=Read-WatchdogState -Config $config
        $copied=Copy-WatchdogState -State $loaded
        ($loaded.lastHealthyCore.process.startUtc -is [DateTime]) | Should Be $true
        ($loaded.lastHealthyCore.process.desktopStartUtc -is [DateTime]) | Should Be $true

        $desktop=[pscustomobject]@{
            ProcessId=20;ParentProcessId=1;Name='ChatGPT.exe';ExecutablePath=$newPackage.DesktopExecutable
            CommandLine='desktop';CreationDate=$desktopStart
        }
        $server=[pscustomobject]@{
            ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$old.Path
            CommandLine='codex.exe app-server';CreationDate=$serverStart
        }
        foreach($snapshot in @($loaded,$copied)){
            $process=Get-CodexProcessObservation -Package $newPackage -Processes @($desktop,$server) -TrustedPreviousCore $snapshot.lastHealthyCore
            $process.TrustedPreviousCorePresent | Should Be $true
            $process.AppServerStatus | Should Be 'Recognized'
            $process.CoreSwitchPending | Should Be $true
        }
    }

    It 'rejects reused server and Desktop PIDs when their normalized creation times differ' {
        $desktopStart=[DateTimeOffset]::Parse('2026-10-26T12:00:00.1234567+03:00')
        $serverStart=[DateTimeOffset]::Parse('2026-10-26T05:00:01.7654321-04:00')
        $state.lastHealthyCore.process.startUtc=$serverStart.ToString('o')
        $state.lastHealthyCore.process.desktopStartUtc=$desktopStart.ToString('o')
        $desktop=[pscustomobject]@{
            ProcessId=20;ParentProcessId=1;Name='ChatGPT.exe';ExecutablePath=$newPackage.DesktopExecutable
            CommandLine='desktop';CreationDate=$desktopStart
        }
        $reusedServer=[pscustomobject]@{
            ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$old.Path
            CommandLine='codex.exe app-server';CreationDate=$serverStart.AddTicks(1)
        }
        $serverMismatch=Get-CodexProcessObservation -Package $newPackage -Processes @($desktop,$reusedServer) -TrustedPreviousCore $state.lastHealthyCore
        $serverMismatch.TrustedPreviousCorePresent | Should Be $false
        $serverMismatch.AppServerStatus | Should Be 'Unknown'

        $originalServer=[pscustomobject]@{
            ProcessId=21;ParentProcessId=20;Name='codex.exe';ExecutablePath=$old.Path
            CommandLine='codex.exe app-server';CreationDate=$serverStart
        }
        $reusedDesktopState=Copy-WatchdogState -State $state
        $reusedDesktopState.lastHealthyCore.process.desktopStartUtc=$desktopStart.AddTicks(1).ToString('o')
        $desktopMismatch=Get-CodexProcessObservation -Package $newPackage -Processes @($desktop,$originalServer) -TrustedPreviousCore $reusedDesktopState.lastHealthyCore
        $desktopMismatch.TrustedPreviousCorePresent | Should Be $false
        $desktopMismatch.AppServerStatus | Should Be 'Unknown'
    }

    It 'switches when the old server is gone but the selected managed core is not running yet' {
        $missing=Get-CodexProcessObservation -Package $newPackage -Processes @($previous.Desktop) -TrustedPreviousCore $state.lastHealthyCore
        $missing.AppServerStatus | Should Be 'Missing'
        $missing.CoreSwitchPending | Should Be $true
        $observation.Process=$missing
        $decision=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Reason | Should Be 'CoreSelectionChanged'
    }

    It 'accepts an already-running selected core and updates the healthy identity without restarting' {
        $newServer=[pscustomobject]@{
            ProcessId=31;ParentProcessId=20;Name='codex.exe';ExecutablePath=$new.Path
            CommandLine='codex.exe app-server';CreationDate=$now.AddMinutes(-2)
        }
        $selected=Get-CodexProcessObservation -Package $newPackage -Processes @($previous.Desktop,$newServer) -TrustedPreviousCore $state.lastHealthyCore
        $selected.SelectedCorePresent | Should Be $true
        $selected.CoreSwitchPending | Should Be $false
        $observation.Process=$selected
        $decision=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        (Set-LastHealthyCoreFromObservation -State $state -Observation $observation -Now $now) | Should Be $true
        $state.lastHealthyCore.core.path | Should Be $new.Path
    }

    It 'defers a core switch while a healthy task protects the shared Desktop' {
        $task=New-TestThread -ThreadId '60000000-0000-0000-0000-000000000001' -Status 'ToolRunning' -Now $now
        $observation.Threads=@($task)
        $decision=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $decision.Action | Should Be 'None'
        $decision.Reason | Should Be 'HealthyTaskProtectsSharedApp'
    }

    It 'latches a failed handover against repeated missing-server recovery until healthy or selector change' {
        $oldPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=[ordered]@{Executable=$old.Path;Source='User';Error=$null;Managed=$true;HashVerified=$true;Sha256=$old.Hash;Version=$old.Version}
        }
        $oldSelection=Get-CodexDesiredCoreIdentity -Package $oldPackage
        $state.coreSwitchAttempt=[ordered]@{
            status='RollbackAttempted';target=[ordered]@{source='User';path=$new.Path;sha256=$new.Hash}
        }
        $state.appServerMissingSinceUtc=$now.AddMinutes(-20).ToString('o')
        $state.appServerMissingChecks=20
        $observation.Package=$oldPackage
        $observation.Process=[ordered]@{
            DesktopPresent=$true;AppServerPresent=$false;AppServerStatus='Missing';CoreSelection=$oldSelection
            CoreSwitchPending=$false;AllPackageProcessIds=@(20)
        }

        $blocked=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now

        $blocked.Action | Should Be 'Manual'
        $blocked.Reason | Should Be 'CoreSwitchAttemptAlreadyUsed'
        $state.appServerMissingSinceUtc | Should Be $null
        $state.appServerMissingChecks | Should Be 0

        $other=New-ManagedCoreFixture -Root (Join-Path $root 'user-selected-new-core') -Version 'future-user-choice'
        $otherPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=[ordered]@{Executable=$other.Path;Source='User';Error=$null;Managed=$true;HashVerified=$true;Sha256=$other.Hash;Version=$other.Version}
        }
        $observation.Package=$otherPackage
        $observation.Process=[ordered]@{
            DesktopPresent=$true;AppServerPresent=$false;AppServerStatus='Missing'
            CoreSelection=(Get-CodexDesiredCoreIdentity -Package $otherPackage)
            CoreSwitchPending=$true;AllPackageProcessIds=@(20)
        }

        $changed=Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now

        $state.coreSwitchAttempt | Should Be $null
        $changed.Action | Should Be 'Restart'
        $changed.Reason | Should Be 'CoreSelectionChanged'
    }

    It 'clears the failed handover latch after a fresh healthy selected-core observation' {
        $newServer=[pscustomobject]@{
            ProcessId=22;ParentProcessId=20;Name='codex.exe';ExecutablePath=$new.Path
            CommandLine='codex.exe app-server';CreationDate=$now.AddMinutes(-1)
        }
        $selectedProcess=Get-CodexProcessObservation -Package $newPackage -Processes @($previous.Desktop,$newServer) -TrustedPreviousCore $state.lastHealthyCore
        $selectedProcess.CoreSwitchPending | Should Be $false
        $state.coreSwitchAttempt=[ordered]@{status='RollbackAttempted';target=[ordered]@{source='User';path=$new.Path;sha256=$new.Hash}}
        $healthy=[ordered]@{
            Package=$newPackage;Process=$selectedProcess
            Integrity=[ordered]@{Healthy=$true};Enrollment=[ordered]@{Status='Enabled'}
            Remote=[ordered]@{ManualCondition=$false}
        }

        (Set-LastHealthyCoreFromObservation -State $state -Observation $healthy -Now $now) | Should Be $true
        $state.coreSwitchAttempt | Should Be $null
    }

    It 'leaves a matching old server unknown and never looks up or kills it without the saved identity' {
        $script:untrustedOldServer=Get-CodexProcessObservation -Package $newPackage -Processes @($previous.Desktop,$previous.Server)
        $script:untrustedOldServer.AppServerStatus | Should Be 'Unknown'
        Mock Get-CodexProcessObservation { $script:untrustedOldServer } -ParameterFilter { [object]::ReferenceEquals($Package,$script:unknownCorePackage) }
        Mock Get-Process { throw 'An unknown process must not be looked up.' }
        Mock Stop-Process { throw 'An unknown process must not be stopped.' }
        $script:unknownCorePackage=$newPackage
        $failure=$null
        try { Stop-CodexPackageProcesses -Package $newPackage -Config $config } catch { $failure=$_ }
        $failure.Exception.Message | Should Be 'An unrecognized live Codex app-server was found; refusing to close or stop the application.'
        Assert-MockCalled Get-Process -Times 0 -Exactly -Scope It
        Assert-MockCalled Stop-Process -Times 0 -Exactly -Scope It
    }

    It 'does not report readiness when the running server differs from the selected path and hash' {
        $oldPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=[ordered]@{Executable=$old.Path;Source='User';Error=$null;Managed=$true;MetadataValidated=$true;HashVerified=$true;Sha256=$old.Hash;Version=$old.Version;MetadataPath=$old.ManifestPath}
        }
        $script:oldSelection=Get-CodexDesiredCoreIdentity -Package $oldPackage
        $script:expectedCore=Get-CodexDesiredCoreIdentity -Package $newPackage
        Mock Start-Sleep {}
        $script:readinessMismatchPackage=$oldPackage
        Mock Get-CodexPackageInfo { $script:readinessMismatchPackage }
        Mock Get-CodexProcessObservation {
            [ordered]@{CoreSelection=$script:oldSelection;DesktopPresent=$true;SelectedCorePresent=$true;TrustedPreviousCorePresent=$false;AppServerStatus='Recognized'}
        }
        $result=Wait-CodexHealthyProcesses -Config $config -InitialPackage $newPackage -TimeoutSeconds 0 -ExpectedCore $script:expectedCore
        $result.Ready | Should Be $false
    }

    It 'passes the fresh persisted selection to Enhanced and clears a stale process-only override for stock' {
        $plan=[ordered]@{CanLaunch=$true;Mode='Enhanced';LauncherPath='fixture';Executable='pwsh.exe';Arguments='';WorkingDirectory=$TestDrive}
        $prior=[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process')
        try {
            [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH','C:\stale\codex.exe','Process')
            Mock Start-Process {
                $script:observedChildCore=[Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process')
                $script:observedChildCorePresent=[Environment]::GetEnvironmentVariables('Process').Contains('CODEX_CLI_PATH')
                [pscustomobject]@{Id=777}
            }
            Mock Get-CodexAppServerOverride { [ordered]@{Executable=$script:managedNewPath;Source='User';Error=$null} }
            $script:managedNewPath=$new.Path
            $null=Start-CodexDesktop -Package $newPackage -UserHome $config.UserHome -LaunchPlan $plan
            $script:observedChildCore | Should Be $script:managedNewPath
            [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process') | Should Be 'C:\stale\codex.exe'

            Mock Get-CodexAppServerOverride { [ordered]@{Executable='';Source='None';Error=$null} }
            $script:observedChildCore='not-cleared'
            $script:observedChildCorePresent=$true
            $null=Start-CodexDesktop -Package $newPackage -UserHome $config.UserHome -LaunchPlan $plan
            $script:observedChildCorePresent | Should Be $false
            [Environment]::GetEnvironmentVariable('CODEX_CLI_PATH','Process') | Should Be 'C:\stale\codex.exe'
        } finally {
            [Environment]::SetEnvironmentVariable('CODEX_CLI_PATH',$prior,'Process')
        }
    }

    It 'rolls back once to the verified previous selector and refuses a foreign selector change' {
        $attempt=[ordered]@{status='Attempting';target=[ordered]@{source='User';path=$new.Path;sha256=$new.Hash}}
        $plan=Get-CoreSelectionRollbackPlan -Attempt $attempt -LastHealthyCore $state.lastHealthyCore -EnvironmentValues @{User=$new.Path;Machine=''}
        $plan.CanRollback | Should Be $true
        $plan.UserValue | Should Be $old.Path
        $conflict=Get-CoreSelectionRollbackPlan -Attempt $attempt -LastHealthyCore $state.lastHealthyCore -EnvironmentValues @{User='C:\user-selected\codex.exe';Machine=''}
        $conflict.CanRollback | Should Be $false
        $conflict.Reason | Should Be 'SelectedValueChanged'

        $config.DataRoot=Join-Path $TestDrive 'rollback-state'
        $config.StatePath=Join-Path $config.DataRoot 'state.json'
        $config.SnapshotRoot=Join-Path $config.DataRoot 'snapshots'
        $script:rollbackPackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$desktop;AppServerExecutable=$stock
            AppServerOverride=[ordered]@{Executable=$old.Path;Source='User';Error=$null;Managed=$true;MetadataValidated=$true;HashVerified=$true;Sha256=$old.Hash;Version=$old.Version;MetadataPath=$old.ManifestPath}
        }
        $expected=Get-CodexDesiredCoreIdentity -Package $script:rollbackPackage
        $serverIdentity=[ordered]@{classification='Selected';processId=31;startedUtc=$now.ToString('o');executablePath=$old.Path;desktopProcessId=30;desktopStartedUtc=$now.ToString('o')}
        $script:rollbackProcess=[ordered]@{
            CoreSelection=$expected;DesktopPresent=$true;SelectedCorePresent=$true;TrustedPreviousCorePresent=$false
            AppServerStatus='Recognized';AppServerPresent=$true;CoreSwitchPending=$false;AllPackageProcessIds=@(30,31)
            AppServerProcessIdentities=@($serverIdentity)
        }
        $script:rollbackEnvironmentWrites=0
        Mock Get-CodexProcessObservation { [ordered]@{AppServerStatus='Missing';AllPackageProcessIds=@()} }
        Mock Set-PersistedUserCodexSelection { $script:rollbackEnvironmentWrites++ }
        Mock Get-CodexPackageInfo { $script:rollbackPackage }
        Mock Get-CodexDesktopLaunchPlan { [ordered]@{Mode='Enhanced';CanLaunch=$true} }
        Mock Start-CodexDesktop { [ordered]@{Mode='Enhanced'} }
        Mock Wait-CodexHealthyProcesses {
            [ordered]@{
                Ready=$true;Package=$script:rollbackPackage;Process=$script:rollbackProcess
                DesktopHandshake=[ordered]@{Verified=$true;Status='Verified';VerifiedProcessIds=@(30);RequiredProcessIds=@(30);AllRequiredProcessesVerified=$true}
            }
        } -ParameterFilter { $RequireDesktopHandshake }
        Mock Get-CodexDatabasePaths { [ordered]@{State='state';Logs='logs'} }
        Mock Test-CodexDatabaseIntegrity { [ordered]@{Healthy=$true;State='ok';Logs='ok'} }
        Mock Get-RemoteEnrollmentObservation { [ordered]@{Status='Enabled';EnabledCount=1} }
        $rollback=Invoke-CoreSelectionRollback -Config $config -State $state -Attempt $attempt -CurrentPackage $newPackage -TimeoutSeconds 1 -EnvironmentValues @{User=$new.Path;Machine=''}
        $rollback.Successful | Should Be $true
        $rollback.DesktopHandshake.AllRequiredProcessesVerified | Should Be $true
        $script:rollbackEnvironmentWrites | Should Be 1
        Assert-MockCalled Wait-CodexHealthyProcesses -Times 1 -Exactly -Scope It -ParameterFilter { $RequireDesktopHandshake }
        $again=Invoke-CoreSelectionRollback -Config $config -State $state -Attempt $attempt -CurrentPackage $newPackage -TimeoutSeconds 1 -EnvironmentValues @{User=$new.Path;Machine=''}
        $again.Reason | Should Be 'RollbackAlreadyAttempted'
        $script:rollbackEnvironmentWrites | Should Be 1
    }
}

Describe 'User selector registry writes' {
    It 'deletes a null selector and preserves an intentionally empty string as a value' {
        $deleteKey=New-RegistryKeyRecorder
        Set-PersistedUserCodexSelection -Value $null -RegistryKey $deleteKey
        @($deleteKey.Calls.Deleted) | Should Be @('CODEX_CLI_PATH')
        @($deleteKey.Calls.Set).Count | Should Be 0
        $deleteKey.Calls.Disposed | Should Be $false

        $emptyKey=New-RegistryKeyRecorder
        Set-PersistedUserCodexSelection -Value '' -RegistryKind 'ExpandString' -RegistryKey $emptyKey
        @($emptyKey.Calls.Deleted).Count | Should Be 0
        @($emptyKey.Calls.Set).Count | Should Be 1
        $emptyKey.Calls.Set[0].Name | Should Be 'CODEX_CLI_PATH'
        $emptyKey.Calls.Set[0].Value | Should Be ''
        $emptyKey.Calls.Set[0].Kind | Should Be 'ExpandString'
        $emptyKey.Calls.Disposed | Should Be $false
    }
}

Describe 'Stable Watchdog install target' {
    It 'copies only changed source files and builds the task action against the stable copy' {
        $config=Get-WatchdogConfig
        $config.InstallRoot=Join-Path $TestDrive ('Programs\CodexWatchdog '+[guid]::NewGuid())
        $sourceScript=$config.ScriptPath
        $sourceLauncher=$config.LauncherPath
        $config.SourceScriptPath=$sourceScript
        $config.SourceLauncherPath=$sourceLauncher
        $first=Install-WatchdogStableScripts -Config $config
        $first.ScriptPath | Should Be (Join-Path $config.InstallRoot 'CodexWatchdog.ps1')
        (Get-FileHash -LiteralPath $first.ScriptPath).Hash | Should Be (Get-FileHash -LiteralPath $sourceScript).Hash
        (Get-FileHash -LiteralPath $first.LauncherPath).Hash | Should Be (Get-FileHash -LiteralPath $sourceLauncher).Hash
        $scriptTime=(Get-Item -LiteralPath $first.ScriptPath).LastWriteTimeUtc
        $again=Install-WatchdogStableScripts -Config $config
        (Get-Item -LiteralPath $again.ScriptPath).LastWriteTimeUtc | Should Be $scriptTime
        $xml=New-WatchdogScheduledTaskXml -Config $config -PowerShellPath 'C:\Program Files\PowerShell\7\pwsh.exe' -WScriptPath 'C:\Windows\System32\wscript.exe' -Sid 'S-1-5-21-100' -Author 'Fixture'
        $xml | Should Match ([regex]::Escape($first.ScriptPath))
        $xml | Should Match ([regex]::Escape($first.LauncherPath))
        $xml | Should Match '<LogonType>InteractiveToken</LogonType>'
        $xml | Should Match '<RunLevel>LeastPrivilege</RunLevel>'
        $xml | Should Not Match ([regex]::Escape($sourceScript))
    }

    It 'keeps Install WhatIf read-only and previews the stable script path' {
        $script:installWhatIfConfig=Get-WatchdogConfig
        $script:installWhatIfConfig.InstallRoot=Join-Path $TestDrive ('not-created '+[guid]::NewGuid())
        Mock Get-WatchdogConfig { $script:installWhatIfConfig }
        Mock Install-WatchdogScheduledTask { throw 'WhatIf must not install a task.' }
        $result=Invoke-CodexWatchdogMain -RequestedAction Install -AsJson -WhatIfMode | ConvertFrom-Json
        $result.action | Should Be 'WouldInstall'
        $result.script | Should Be (Join-Path $script:installWhatIfConfig.InstallRoot 'CodexWatchdog.ps1')
        (Test-Path -LiteralPath $script:installWhatIfConfig.InstallRoot) | Should Be $false
        Assert-MockCalled Install-WatchdogScheduledTask -Times 0 -Exactly -Scope It
    }
}

function New-EnhancedLauncherFixture {
    param([Parameter(Mandatory)][string]$UserHome)
    $root = Join-Path $UserHome '.agents\skills\better-codex'
    $scripts = Join-Path $root 'scripts'
    $null = New-Item -ItemType Directory -Path $scripts -Force
    Set-Content -LiteralPath (Join-Path $root 'SKILL.md') -Value 'name: better-codex'
    @'
@{ arguments=@($args); script=$PSCommandPath } | ConvertTo-Json -Depth 3 |
    Set-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'invoked.json') -Encoding utf8
'@ | Set-Content -LiteralPath (Join-Path $scripts 'codex-custom.ps1')
    return $root
}

Describe 'Enhanced desktop launch selection' {
    BeforeEach {
        $userHome = Join-Path $TestDrive ('профиль с пробелами ' + [guid]::NewGuid())
        $null = New-Item -ItemType Directory -Path $userHome -Force
        $package = [ordered]@{Found=$true;Aumid='OpenAI.Codex_fixture!App'}
    }

    It 'preserves native activation only when the skill is absent' {
        Mock Invoke-CodexNativeActivation {}
        $plan = Get-CodexDesktopLaunchPlan -Package $package -UserHome $userHome
        $plan.Mode | Should Be 'Native'
        $launch = Start-CodexDesktop -Package $package -UserHome $userHome
        $launch.Mode | Should Be 'Native'
        Assert-MockCalled Invoke-CodexNativeActivation -Times 1 -Exactly -Scope It
    }

    It 'launches the canonical installed skill in a real child without overriding preferences' {
        Mock Invoke-CodexNativeActivation { throw 'Native activation must not bypass an installed skill.' }
        $skillRoot = New-EnhancedLauncherFixture -UserHome $userHome
        $preferences = Join-Path $userHome 'Programs\CodexWidth'
        $null = New-Item -ItemType Directory -Path $preferences -Force
        Set-Content -LiteralPath (Join-Path $preferences 'profile.json') -Value '{"widthRem":137}'
        Set-Content -LiteralPath (Join-Path $preferences 'admin.json') -Value '{"enabled":false}'
        $before = @((Get-FileHash -LiteralPath (Join-Path $preferences 'profile.json')).Hash,(Get-FileHash -LiteralPath (Join-Path $preferences 'admin.json')).Hash)
        $launch = Start-CodexDesktop -Package $package -UserHome $userHome
        $marker = Join-Path $skillRoot 'invoked.json'
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds(60)
        while (-not (Test-Path -LiteralPath $marker) -and [DateTimeOffset]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        (Test-Path -LiteralPath $marker) | Should Be $true
        $record = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $record.script | Should Be (Join-Path $skillRoot 'scripts\codex-custom.ps1')
        @($record.arguments).Count | Should Be 0
        $launch.Mode | Should Be 'Enhanced'
        @((Get-FileHash -LiteralPath (Join-Path $preferences 'profile.json')).Hash,(Get-FileHash -LiteralPath (Join-Path $preferences 'admin.json')).Hash) | Should Be $before
        Assert-MockCalled Invoke-CodexNativeActivation -Times 0 -Exactly -Scope It
    }

    It 'does not fall back when an installed skill is incomplete or launch fails' {
        Mock Invoke-CodexNativeActivation { throw 'Native fallback must not run.' }
        $skillRoot = New-EnhancedLauncherFixture -UserHome $userHome
        Remove-Item -LiteralPath (Join-Path $skillRoot 'scripts\codex-custom.ps1')
        (Get-CodexDesktopLaunchPlan -Package $package -UserHome $userHome).Mode | Should Be 'Unavailable'
        $failure = $null
        try { Start-CodexDesktop -Package $package -UserHome $userHome } catch { $failure = $_ }
        $failure.Exception.Message | Should Be 'The installed better-codex skill is incomplete.'
        $null = New-EnhancedLauncherFixture -UserHome $userHome
        Mock Start-Process { throw 'Fixture launch error' }
        $failure = $null
        try { Start-CodexDesktop -Package $package -UserHome $userHome } catch { $failure = $_ }
        $failure.Exception.Message | Should Be 'Fixture launch error'
        Assert-MockCalled Invoke-CodexNativeActivation -Times 0 -Exactly -Scope It
    }
}

Describe 'Managed Startup launch routing' {
    BeforeEach {
        $config = Get-WatchdogConfig
        $config.StartupDirectory = Join-Path $TestDrive ('Startup с пробелами ' + [guid]::NewGuid())
        $config.UserHome = Join-Path $TestDrive ('fixture user ' + [guid]::NewGuid())
    }

    It 'creates and repairs only its owned real shortcut without launching it' {
        $plan = Set-CodexStartupLauncher -Config $config -CheckOnly
        (Test-Path -LiteralPath $config.StartupDirectory) | Should Be $false
        $link = Set-CodexStartupLauncher -Config $config
        $link.verified | Should Be $true
        $link.arguments.EndsWith('"LaunchOnly"') | Should Be $true
        $link.target | Should Be (Join-Path $env:SystemRoot 'System32\wscript.exe')
        $before = (Get-FileHash -LiteralPath $link.path).Hash
        (Set-CodexStartupLauncher -Config $config).needsChange | Should Be $false
        (Get-FileHash -LiteralPath $link.path).Hash | Should Be $before
        $movedRoot = Join-Path $TestDrive 'moved source'
        $null = New-Item -ItemType Directory -Path $movedRoot
        Copy-Item -LiteralPath $config.ScriptPath,$config.LauncherPath -Destination $movedRoot
        $config.ScriptPath=Join-Path $movedRoot 'CodexWatchdog.ps1';$config.LauncherPath=Join-Path $movedRoot 'CodexWatchdogLauncher.vbs'
        $repaired = Set-CodexStartupLauncher -Config $config
        $repaired.verified | Should Be $true
        $repaired.arguments.Contains($config.ScriptPath) | Should Be $true
    }

    It 'preserves a foreign Startup entry' {
        $null=New-Item -ItemType Directory -Path $config.StartupDirectory -Force
        $path=Join-Path $config.StartupDirectory 'Codex Enhanced.lnk'
        $shell=New-Object -ComObject WScript.Shell
        try{$link=$shell.CreateShortcut($path);$link.TargetPath=Join-Path $env:SystemRoot 'System32\notepad.exe';$link.Description='User shortcut';$link.Save();[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($link)}finally{[void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)}
        $before=(Get-FileHash -LiteralPath $path).Hash
        $failure = $null
        try { Set-CodexStartupLauncher -Config $config } catch { $failure = $_ }
        $failure.Exception.Message | Should Be "Refusing to overwrite an unrelated Startup entry: $path"
        (Get-FileHash -LiteralPath $path).Hash | Should Be $before
    }

    It 'runs the hidden VBS launcher with default Check and explicit LaunchOnly on a fake script' {
        $fakeScript=Join-Path $TestDrive 'fake launch target.ps1'
        @'
param([string]$Action,[switch]$Json)
$Action | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'action.txt')
'@ | Set-Content -LiteralPath $fakeScript
        $pwsh=(Get-Command pwsh.exe -CommandType Application|Select-Object -First 1).Source
        $wscript=Join-Path $env:SystemRoot 'System32\wscript.exe'
        foreach($mode in @('Check','LaunchOnly')){
            $arguments='//B //NoLogo "{0}" "{1}" "{2}"' -f $config.LauncherPath,$pwsh,$fakeScript
            if($mode -eq 'LaunchOnly'){$arguments+=' "LaunchOnly"'}
            $child=Start-Process -FilePath $wscript -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
            $child.ExitCode | Should Be 0
            (Get-Content -LiteralPath (Join-Path $TestDrive 'action.txt') -Raw).Trim() | Should Be $mode
        }
    }

    It 'plans ordinary startup independently of Remote and database recovery gates' {
        $null=New-EnhancedLauncherFixture -UserHome $config.UserHome
        Mock Get-WatchdogConfig { $config }
        Mock Get-CodexPackageInfo { [ordered]@{Found=$true;Aumid='OpenAI.Codex_fixture!App'} }
        Mock Get-CodexProcessObservation { [ordered]@{DesktopPresent=$true} }
        Mock Get-CodexObservation { throw 'Startup must not query Remote/DB recovery health.' }
        Mock Read-WatchdogState { throw 'Startup must not read recovery state.' }
        Mock Start-CodexDesktop { throw 'WhatIf must not launch any application.' }
        $result=Invoke-CodexWatchdogMain -RequestedAction LaunchOnly -AsJson -WhatIfMode | ConvertFrom-Json
        $result.action | Should Be 'WouldLaunch'
        $result.launch.Mode | Should Be 'Enhanced'
        ($result.launch.Arguments -match '-Admin|-Width|-RuntimeDirectory') | Should Be $false
        Assert-MockCalled Start-CodexDesktop -Times 0 -Exactly -Scope It
    }

    It 'keeps native fallback idempotent when the skill is removed and Codex is already running' {
        Mock Get-WatchdogConfig { $config }
        Mock Get-CodexPackageInfo { [ordered]@{Found=$true;Aumid='OpenAI.Codex_fixture!App'} }
        Mock Get-CodexProcessObservation { [ordered]@{DesktopPresent=$true} }
        Mock Get-CodexObservation { throw 'Startup must not query Remote/DB recovery health.' }
        Mock Start-CodexDesktop { throw 'An existing native app must not be activated again.' }
        $result=Invoke-CodexWatchdogMain -RequestedAction LaunchOnly -AsJson | ConvertFrom-Json
        $result.action | Should Be 'None'
        $result.reason | Should Be 'CodexAlreadyRunning'
        $result.launch.Mode | Should Be 'Native'
        Assert-MockCalled Start-CodexDesktop -Times 0 -Exactly -Scope It
    }
}

Describe 'Remote transport and database safety' {
    BeforeEach {
        $config = Get-WatchdogConfig
        $now = [DateTimeOffset]::Parse('2026-07-23T12:00:00Z')
        $logDatabase = Join-Path $TestDrive 'logs_2.sqlite'
        Remove-Item -LiteralPath $logDatabase -Force -ErrorAction SilentlyContinue
        & sqlite3 $logDatabase @'
CREATE TABLE logs (
    ts INTEGER NOT NULL,
    level TEXT NOT NULL,
    target TEXT NOT NULL,
    feedback_log_body TEXT
);
'@
        if ($LASTEXITCODE -ne 0) { throw 'Could not create SQLite test fixture.' }
        $databasePaths = [ordered]@{ State = ''; Logs = $logDatabase }
    }

    It 'ignores authentication-like text outside the dedicated Remote logger' {
        $timestamp = $now.AddMinutes(-1).ToUnixTimeSeconds()
        & sqlite3 $logDatabase "INSERT INTO logs VALUES ($timestamp, 'WARN', 'codex_core::stream_events_utils', 'user text mentions HTTP status 401');"
        $remote = Get-RemoteTransportObservation -Config $config -DatabasePaths $databasePaths -Now $now
        $remote.ManualCondition | Should Be $false
        $remote.RepeatedFailure | Should Be $false
    }

    It 'recognizes repeated Remote failures spanning five minutes' {
        $first = $now.AddSeconds(-370).ToUnixTimeSeconds()
        $second = $now.AddSeconds(-190).ToUnixTimeSeconds()
        $third = $now.AddSeconds(-30).ToUnixTimeSeconds()
        $target = 'codex_app_server_transport::transport::remote_control::websocket'
        & sqlite3 $logDatabase "INSERT INTO logs VALUES ($first, 'WARN', '$target', 'connection failed'); INSERT INTO logs VALUES ($second, 'WARN', '$target', 'connection failed'); INSERT INTO logs VALUES ($third, 'WARN', '$target', 'connection failed');"
        $remote = Get-RemoteTransportObservation -Config $config -DatabasePaths $databasePaths -Now $now
        $remote.RepeatedFailure | Should Be $true
        $remote.FailureCount | Should Be 3
    }

    It 'clears a Remote failure streak after a later successful connection' {
        $first = $now.AddSeconds(-370).ToUnixTimeSeconds()
        $second = $now.AddSeconds(-190).ToUnixTimeSeconds()
        $third = $now.AddSeconds(-30).ToUnixTimeSeconds()
        $success = $now.AddSeconds(-10).ToUnixTimeSeconds()
        $target = 'codex_app_server_transport::transport::remote_control::websocket'
        & sqlite3 $logDatabase "INSERT INTO logs VALUES ($first, 'WARN', '$target', 'connection failed'); INSERT INTO logs VALUES ($second, 'WARN', '$target', 'connection failed'); INSERT INTO logs VALUES ($third, 'WARN', '$target', 'connection failed'); INSERT INTO logs VALUES ($success, 'INFO', '$target', 'connected');"
        $remote = Get-RemoteTransportObservation -Config $config -DatabasePaths $databasePaths -Now $now
        $remote.RepeatedFailure | Should Be $false
        $remote.FailureCount | Should Be 0
    }

    It 'marks corrupt SQLite fixtures as unsafe for automatic recovery' {
        $stateDatabase = Join-Path $TestDrive 'state_5.sqlite'
        Set-Content -LiteralPath $stateDatabase -Value 'not a sqlite database' -Encoding utf8
        $integrity = Test-CodexDatabaseIntegrity -DatabasePaths ([ordered]@{ State = $stateDatabase; Logs = $logDatabase })
        $integrity.Healthy | Should Be $false
        $integrity.State | Should Be 'unavailable'
        $integrity.Logs | Should Be 'ok'
    }
}

Describe 'Watchdog validation diagnostics' {
    BeforeEach {
        $config = Get-WatchdogConfig
        $state = New-WatchdogState
        $now = [DateTimeOffset]::Parse('2026-07-23T12:00:00Z')
    }

    It 'records the exact stale-task threshold and lifecycle evidence' {
        $thread = New-TestThread -ThreadId '20000000-0000-0000-0000-000000000001' -Status 'StaleCandidate' -Now $now -Fingerprint 'same'
        $state.staleCandidates = @([ordered]@{
            threadId = $thread.ThreadId
            fingerprint = 'same'
            observedSinceUtc = $now.AddMinutes(-6).ToString('o')
        })
        $observation = New-TestObservation -Threads @($thread)
        $decision = Get-WatchdogDecision -Observation $observation -State $state -Config $config -Now $now
        $validation = Get-TriggerValidationReport -Decision $decision -Observation $observation -State $state -Config $config -Now $now
        $check = $validation.checks[0]

        $decision.Reason | Should Be 'ConfirmedStaleTask'
        $check.name | Should Be 'LifecycleProgressFresh'
        $check.status | Should Be 'failed'
        $check.threadId | Should Be $thread.ThreadId
        $check.staleThresholdMinutes | Should Be 60
        $check.unchangedConfirmationMinutes | Should Be 5
        $check.lastEventType | Should Be 'event_msg/token_count'
    }

    It 'lists each failed post-recovery validation and a package update' {
        $before = [ordered]@{ Found = $true; Version = '1.0.0' }
        $after = [ordered]@{ Found = $true; Version = '2.0.0' }
        $process = [ordered]@{ DesktopPresent = $true; AppServerPresent = $false }
        $integrity = [ordered]@{ Healthy = $false; State = 'ok'; Logs = 'failed' }
        $enrollment = [ordered]@{ Status = 'Disabled'; EnabledCount = 0 }
        $validation = Get-RecoveryValidationReport -BeforePackage $before -AfterPackage $after -Process $process -Integrity $integrity -Enrollment $enrollment
        $failedNames = @($validation.checks | Where-Object status -eq 'failed' | ForEach-Object name)

        $validation.packageChanged | Should Be $true
        ($failedNames -contains 'AppServerProcessPresent') | Should Be $true
        ($failedNames -contains 'LogsDatabaseIntegrity') | Should Be $true
        ($failedNames -contains 'RemoteEnrollmentEnabled') | Should Be $true
        ($failedNames -contains 'DesktopProcessPresent') | Should Be $false
    }

    It 'persists validation metadata in the redacted JSONL event' {
        $config.DataRoot = Join-Path $TestDrive 'runtime'
        $config.StatePath = Join-Path $config.DataRoot 'state.json'
        $config.EventLogPath = Join-Path $config.DataRoot 'watchdog.jsonl'
        $config.SnapshotRoot = Join-Path $config.DataRoot 'snapshots'
        $validation = [ordered]@{
            phase = 'trigger'
            checks = @((New-ValidationCheck -Name 'DesktopProcessPresent' -Status 'failed' -Expected $true -Observed $false))
        }

        Write-WatchdogEvent -Config $config -Event 'Restart' -Reason 'CodexDesktopAbsent' -Outcome 'started' -Validation $validation
        $record = Get-Content -LiteralPath $config.EventLogPath -Raw | ConvertFrom-Json

        $record.validation.phase | Should Be 'trigger'
        $record.validation.checks[0].name | Should Be 'DesktopProcessPresent'
        $record.validation.checks[0].status | Should Be 'failed'
    }
}

Describe 'Core-switch recovery handshake opt-in' {
    BeforeEach {
        $config=Get-WatchdogConfig
        $now=[DateTimeOffset]::Parse('2026-10-26T10:00:00Z')
        $state=New-WatchdogState
        $script:coreHandshakeRoot=Join-Path $TestDrive ('recovery-handshake '+[guid]::NewGuid())
        $script:coreHandshakeOld=New-ManagedCoreFixture -Root (Join-Path $script:coreHandshakeRoot 'old') -Version 'old-core'
        $script:coreHandshakeNew=New-ManagedCoreFixture -Root (Join-Path $script:coreHandshakeRoot 'new') -Version 'future-core'
        $script:coreHandshakeDesktop='C:\WindowsApps\Codex_fixture\app\ChatGPT.exe'
        $script:coreHandshakeStock='C:\WindowsApps\Codex_fixture\app\resources\codex.exe'
        $script:coreHandshakePackage=[ordered]@{
            Found=$true;Version='fixture';DesktopExecutable=$script:coreHandshakeDesktop;AppServerExecutable=$script:coreHandshakeStock
            AppServerOverride=[ordered]@{
                Executable=$script:coreHandshakeNew.Path;Source='User';RawValue=$script:coreHandshakeNew.Path
                RegistryKind='String';Error=$null;Managed=$true;MetadataValidated=$true;HashVerified=$true
                Sha256=$script:coreHandshakeNew.Hash;Version=$script:coreHandshakeNew.Version
            }
        }
        $script:coreHandshakePrevious=New-ManagedCoreProcessFixture -Now $now `
            -DesktopPath $script:coreHandshakeDesktop -CorePath $script:coreHandshakeOld.Path
        $state.lastHealthyCore=[ordered]@{
            selector=[ordered]@{source='User';path=$script:coreHandshakeOld.Path}
            core=[ordered]@{kind='Managed';path=$script:coreHandshakeOld.Path;sha256=$script:coreHandshakeOld.Hash;version=$script:coreHandshakeOld.Version}
            process=[ordered]@{
                pid=21;startUtc=$script:coreHandshakePrevious.ServerStartUtc
                desktopPid=20;desktopStartUtc=$script:coreHandshakePrevious.DesktopStartUtc
            }
            healthyAtUtc=$now.AddMinutes(-1).ToString('o')
        }
        $script:coreHandshakeSelectedServer=[pscustomobject]@{
            ProcessId=31;ParentProcessId=20;Name='codex.exe';ExecutablePath=$script:coreHandshakeNew.Path
            CommandLine='codex.exe app-server';CreationDate=$now.AddMinutes(-1)
        }
        $script:coreHandshakeSelectedProcess=Get-CodexProcessObservation -Package $script:coreHandshakePackage `
            -Processes @($script:coreHandshakePrevious.Desktop,$script:coreHandshakeSelectedServer) `
            -TrustedPreviousCore $state.lastHealthyCore
        $script:coreHandshakeObservation=New-TestObservation
        $script:coreHandshakeObservation.Package=$script:coreHandshakePackage
        $script:coreHandshakeObservation.Process=Get-CodexProcessObservation -Package $script:coreHandshakePackage `
            -Processes @($script:coreHandshakePrevious.Desktop,$script:coreHandshakePrevious.Server) `
            -TrustedPreviousCore $state.lastHealthyCore
        $config.DataRoot=Join-Path $TestDrive 'core-handshake-state'
        $config.StatePath=Join-Path $config.DataRoot 'state.json'
        $config.SnapshotRoot=Join-Path $config.DataRoot 'snapshots'
        $script:coreHandshakeConfig=$config
        $script:coreHandshakeState=$state
        $script:coreHandshakeNow=$now
    }

    It 'requires the real Wait readiness gate with a successful current Desktop handshake for a core switch' {
        $script:coreHandshakeProof=[ordered]@{
            Verified=$true;Status='Verified';VerifiedProcessIds=@(20);RequiredProcessIds=@(20)
            AllRequiredProcessesVerified=$true;ExaminedFileCount=1;ReadErrorCount=0
        }
        Mock Write-DiagnosticSnapshot {}
        Mock Write-WatchdogEvent {}
        Mock Get-CodexPackageInfo { $script:coreHandshakePackage }
        Mock Get-CodexProcessObservation { $script:coreHandshakeSelectedProcess }
        Mock Get-CodexDesktopLaunchPlan { [ordered]@{Mode='Enhanced';CanLaunch=$true} }
        Mock Stop-CodexPackageProcesses {}
        Mock Start-CodexDesktop { [ordered]@{Mode='Enhanced'} }
        Mock Wait-CodexHealthyProcesses {
            [ordered]@{
                Ready=$true;Package=$script:coreHandshakePackage;Process=$script:coreHandshakeSelectedProcess
                DesktopHandshake=$script:coreHandshakeProof
            }
        } -ParameterFilter { $RequireDesktopHandshake }
        Mock Get-CodexDatabasePaths { [ordered]@{State='state';Logs='logs'} }
        Mock Test-CodexDatabaseIntegrity { [ordered]@{Healthy=$true;State='ok';Logs='ok'} }
        Mock Get-RemoteEnrollmentObservation { [ordered]@{Status='Enabled';EnabledCount=1} }

        $result=Invoke-CodexRecovery -Mode Restart -Config $script:coreHandshakeConfig -State $script:coreHandshakeState `
            -Observation $script:coreHandshakeObservation `
            -Decision (New-WatchdogDecision -Action Restart -Reason 'CoreSelectionChanged') -Now $script:coreHandshakeNow

        $result.Successful | Should Be $true
        $result.Validation.checks | Where-Object name -eq 'DesktopInitializeHandshake' | Select-Object -ExpandProperty status | Should Be 'passed'
        Assert-MockCalled Wait-CodexHealthyProcesses -Times 1 -Exactly -Scope It -ParameterFilter { $RequireDesktopHandshake }
    }
}
