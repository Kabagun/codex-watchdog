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

    It 'recognizes only the descended app-server in the versioned local runtime path' {
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

        $observation.AppServerPresent | Should Be $true
        @($observation.AppServerProcessIds) | Should Be @(21)
        ($observation.AllPackageProcessIds -contains 21) | Should Be $true
        foreach ($unrelatedId in @(22, 23, 24)) {
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
