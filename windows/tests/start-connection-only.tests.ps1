[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$Root)

$ErrorActionPreference = 'Stop'
# Import definitions only. All process, CDP, theme and config operations below
# are mocks; real state serialization is exercised solely inside our temp root.
. (Join-Path $Root 'scripts\common-windows.ps1')
$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dreamskin-connect-' + [guid]::NewGuid().ToString('N'))
$originalLocalAppData = $env:LOCALAPPDATA
$source = [System.IO.File]::ReadAllText((Join-Path $Root 'scripts\start-dream-skin.ps1'))
$imports = '(?m)^\.\s+\(Join-Path \$PSScriptRoot ''(?:common-windows|theme-windows|localization-windows)\.ps1''\)\r?\n'
if ([regex]::Matches($source, $imports).Count -ne 3) { throw 'Could not isolate startup imports.' }
$source = [regex]::Replace($source, $imports, '')
$source = $source.Replace('$Injector = Join-Path $PSScriptRoot ''injector.mjs''', '$Injector = ''mock-injector.mjs''')
$source = $source.Replace('(Split-Path -Parent $PSScriptRoot)', '''mock-skill-root''')
$source = $source.Replace('(Join-Path $PSScriptRoot ''manager-actions.ps1'')', '''mock-manager-actions.ps1''')
# The presentation hook must stay outside these process/config fixtures.
$source = $source.Replace(
  '$animationScript = Join-Path $PSScriptRoot ''play-startup-animation.mjs''',
  '$animationScript = Join-Path $StateRoot (''fixture-animation-disabled-'' + [guid]::NewGuid().ToString(''N'') + ''.mjs'')'
)
$source = $source.Replace('$ConfigPath = Join-Path $HOME ''.codex\config.toml''', '$ConfigPath = Join-Path $StateRoot ''fixture-config.toml''')
if ($source.Contains('$PSScriptRoot') -or $source.Contains('$HOME')) { throw 'Startup fixture contains an unisolated path.' }
$startBlock = [scriptblock]::Create($source)

# Load only the status function, never the manager script's top-level actions.
$tokens = $null; $parseErrors = $null
$managerAst = [System.Management.Automation.Language.Parser]::ParseFile(
  (Join-Path $Root 'scripts\manager-actions.ps1'), [ref]$tokens, [ref]$parseErrors)
$statusFunction = @($managerAst.FindAll({ param($node)
  $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-ManagerInjectorStatus'
}, $true))
if ($parseErrors.Count -or $statusFunction.Count -ne 1) { throw 'Could not isolate manager status.' }
. ([scriptblock]::Create($statusFunction[0].Extent.Text))

function Assert-FixturePath { param([string]$Path)
  $full = [System.IO.Path]::GetFullPath($Path)
  if (-not $full.StartsWith($fixtureRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Attempted access outside fixture: $Path"
  }
}
function Enter-DreamSkinOperationLock { param([int]$TimeoutMilliseconds); return 'fixture-lock' }
function Exit-DreamSkinOperationLock { param([object]$Mutex); $script:lockExited = $true }
function Resolve-DreamSkinLanguage { param([string]$StateRoot); return 'en-US' }
function Get-DreamSkinNodeRuntime { return [pscustomobject]@{ Path = 'mock-node.exe'; Version = '22.23.1' } }
function Get-DreamSkinRuntimeFingerprint { param([string]$SkillRoot); return 'fixture' }
function Get-DreamSkinCodexInstall {
  return [pscustomobject]@{ Executable = 'C:\fixture\Codex.exe'; PackageRoot = 'C:\fixture';
    PackageFullName = 'OpenAI.Codex_fixture'; PackageFamilyName = 'OpenAI.Codex_fixture'; Version = '1' }
}
function Get-DreamSkinThemePaths { param([string]$StateRoot)
  Assert-FixturePath $StateRoot
  return [pscustomobject]@{ Root = $StateRoot; Active = (Join-Path $StateRoot 'active'); PauseFile = (Join-Path $StateRoot 'paused') }
}
function Ensure-DreamSkinManagedDirectory { param([string]$Path, [string]$Root)
  Assert-FixturePath $Path
  New-Item -ItemType Directory -Path $Path -Force | Out-Null
}
function Initialize-DreamSkinThemeStore { param([string]$SkillRoot, [string]$StateRoot)
  return Get-DreamSkinThemePaths $StateRoot
}
function Test-DreamSkinPaused { param([string]$StateRoot); return $script:paused }
function Set-DreamSkinPaused { param([bool]$Paused, [string]$StateRoot); $script:paused = $Paused }
function Test-DreamSkinPendingAppearanceTransaction { param([string]$BackupPath); Assert-FixturePath $BackupPath; return $false }
function Get-DreamSkinCodexStatePathCandidate { param([object]$State); return $null }
function Get-DreamSkinCodexInstallFromState { param([object]$State); return $null }
function Get-DreamSkinCodexProcesses { param([object]$Codex)
  # Windows PowerShell 5.1 PSCustomObject does not inherit scalar .Count=1
  # unlike CIM process objects; model that property explicitly.
  if ($script:cdpReady) { return [pscustomobject]@{ ProcessId = 900; Count = 1 } }
  return ,@()
}
function Get-DreamSkinVerifiedCdpIdentity { param([int]$Port, [object]$Codex)
  $script:cdpProbeCount++
  if ($script:raceNewSession -and $script:cdpProbeCount -ge 2) { $script:cdpReady = $true }
  if ($script:cdpReady) { return [pscustomobject]@{ BrowserId = 'fixture-browser' } }
  return $null
}
function Get-DreamSkinVerifiedCdpIdentityForAnyRegistered { param([int]$Port); return $null }
function Test-DreamSkinPortAvailable { param([int]$Port); return $true }
function Start-DreamSkinCodexForDebugging { param([object]$Codex, [string[]]$Arguments, [int]$Port, [int[]]$PreserveProcessIds)
  $script:events += 'connect'
  if ($script:failConnect) { throw 'fixture connection failed' }
  $script:cdpReady = $true
  return [pscustomobject]@{ Strategy = 'fixture' }
}
function Stop-DreamSkinCodex { param([object]$Codex, [int[]]$PreserveProcessIds, [switch]$AllowForce)
  $script:events += 'stop'; $script:cdpReady = $false
}
function Start-DreamSkinCodex { param([object]$Codex); $script:events += 'ordinary-start'; return 901 }
function Stop-DreamSkinRecordedInjector { param([object]$State); return $true }
function Get-DreamSkinActiveThemeAppearance { param([string]$ThemeDirectory)
  $script:events += 'read-selected-theme'; return 'dark'
}
function Install-DreamSkinBaseTheme { param([string]$ConfigPath, [string]$BackupPath, [string]$AppearanceTheme, [switch]$PassThruTransaction)
  Assert-FixturePath $ConfigPath; Assert-FixturePath $BackupPath
  if ($script:cdpReady) { throw 'Appearance written while Codex was running' }
  $script:events += "install-$AppearanceTheme"
  if ($script:failAppearance) { throw 'fixture appearance preparation failed' }
  return [pscustomobject]@{ SchemaVersion = 2 }
}
function Complete-DreamSkinAppearanceTransaction { param([string]$BackupPath, [object]$Transaction); $script:events += 'commit' }
function Restore-DreamSkinManagedAppearanceSnapshot { param([string]$ConfigPath, [string]$BackupPath, [object]$Transaction)
  Assert-FixturePath $ConfigPath; Assert-FixturePath $BackupPath
  if ($script:cdpReady) { throw 'Appearance restored while Codex was running' }
  $script:events += 'restore-appearance'
  return [pscustomobject]@{ ConflictedKeys = @(); MarkerStatus = 'restored' }
}
function Invoke-DreamSkinPowerShellScript { param([string]$ScriptPath, [string[]]$ArgumentList)
  if ($ScriptPath -cne 'mock-manager-actions.ps1' -or
    $ArgumentList -notcontains '-DeferLiveApply') { throw 'Unexpected manager invocation' }
  $connection = Read-DreamSkinState -Path (Join-Path $fixtureRoot 'CodexDreamSkin\state.json')
  if (-not $script:cdpReady -or -not $connection.connectionOnly -or $connection.injectorPid) {
    throw 'Video decode did not receive its single connected browser session'
  }
  $script:events += 'decode'
  if ($script:failDecode) {
    return [pscustomobject]@{ ExitCode = 1; Output = @('fixture decode failed') }
  }
  $script:events += 'publish'
  $script:activeTheme = 'selected'
  return [pscustomobject]@{ ExitCode = 0; Output = @('{"applied":true}') }
}
function powershell.exe { throw 'Unexpected native PowerShell operation in isolated startup' }
function ConvertTo-DreamSkinProcessArgument { param([string]$Value); return $Value }
function Get-DreamSkinProcessStartedAt { param([int]$ProcessId); return '2026-09-23T00:00:00.0000000Z' }
function Start-Process { [CmdletBinding()] param([string]$FilePath, [object[]]$ArgumentList, [string]$WindowStyle,
  [switch]$PassThru, [string]$RedirectStandardOutput, [string]$RedirectStandardError)
  if ($PSBoundParameters.ContainsKey('RedirectStandardOutput') -or
    $PSBoundParameters.ContainsKey('RedirectStandardError')) {
    throw 'The watcher must own its log files instead of PowerShell redirecting its streams.'
  }
  foreach ($logFlag in @('--stdout-log', '--stderr-log')) {
    $logIndex = [array]::IndexOf($ArgumentList, $logFlag)
    if (@($ArgumentList | Where-Object { "$_" -ceq $logFlag }).Count -ne 1 -or
      $logIndex + 1 -ge $ArgumentList.Count -or
      [string]::IsNullOrWhiteSpace("$($ArgumentList[$logIndex + 1])")) {
      throw "The watcher did not receive its $logFlag file."
    }
  }
  $script:events += 'injector'
  return [pscustomobject]@{ Id = 4242; HasExited = $false }
}
function Get-Process { [CmdletBinding()] param([int]$Id); throw 'Unexpected real process inspection' }
function Stop-Process { [CmdletBinding()] param([object]$InputObject, [switch]$Force); throw 'Unexpected process stop' }
function Get-CimInstance { [CmdletBinding()] param([string]$ClassName, [string]$Filter); throw 'Unexpected CIM inspection' }
function Invoke-DreamSkinNative { param([string]$FilePath, [object[]]$ArgumentList, [switch]$DiscardStderr)
  if ($ArgumentList -notcontains '--verify') { throw 'Unexpected native operation' }
  $script:events += 'verify'
  return [pscustomobject]@{ ExitCode = 0; Output = @('{"pass":true}') }
}
function Start-Sleep { param([int]$Milliseconds, [int]$Seconds) }
function Write-Host { param([Parameter(ValueFromRemainingArguments = $true)][object[]]$Object)
  $script:messages += ($Object -join ' ')
}
function Reset-Fixture {
  $script:events = @(); $script:messages = @(); $script:lockExited = $false
  $script:cdpReady = $false; $script:failConnect = $false; $script:paused = $true
  $script:failDecode = $false; $script:activeTheme = 'original'
  $script:failAppearance = $false
  $script:raceNewSession = $false; $script:cdpProbeCount = 0
}
function Assert-NoActiveAnnouncement {
  if (@($script:messages | Where-Object { $_ -like 'Codex Dream Skin is active*' }).Count) {
    throw 'Connection preparation falsely announced a running skin.'
  }
}

try {
  $env:LOCALAPPDATA = $fixtureRoot
  $statePath = Join-Path $fixtureRoot 'CodexDreamSkin\state.json'
  Reset-Fixture
  & $startBlock -ConnectOnly
  $connection = Read-DreamSkinState -Path $statePath
  $status = Get-ManagerInjectorStatus -State $connection
  if (($script:events -join ',') -cne 'connect' -or -not $script:paused -or
    -not $script:lockExited -or $connection.schemaVersion -ne 3 -or
    -not $connection.connectionOnly -or $connection.injectorPid -or $status.Running -or $status.Kind -cne 'stopped') {
    throw 'ConnectOnly loaded the old skin, changed appearance/pause, or claimed an injector.'
  }
  Assert-NoActiveAnnouncement

  # Both the check and real startup must reject an unapproved restart, with
  # byte-identical state and no appearance/process operations.
  $connectionBytes = [System.IO.File]::ReadAllBytes($statePath)
  foreach ($check in @($true, $false)) {
    $script:events = @(); $failure = $null
    try { & $startBlock -CheckOnly:$check } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike 'DREAM_SKIN_RESTART_REQUIRED:*' -or
      $script:events.Count -ne 0 -or -not (Test-DreamSkinBytesEqual $connectionBytes ([System.IO.File]::ReadAllBytes($statePath)))) {
      throw "Final startup mutated state or bypassed restart consent (check=$check; error=$failure; events=$($script:events -join ','))."
    }
  }

  $script:events = @()
  & $startBlock -RestartExisting
  $running = Read-DreamSkinState -Path $statePath
  if (($script:events -join ',') -cne 'stop,read-selected-theme,install-dark,connect,injector,verify,commit' -or
    $running.connectionOnly -or $running.injectorPid -ne 4242 -or $script:paused) {
    throw 'Final startup failed to close, configure, reconnect, verify and replace connection-only state.'
  }

  # The reader must reject a mixed connection-only/injector identity and must
  # retain the mandatory injector fields for ordinary schema-3 states.
  foreach ($malformed in @(
    [pscustomobject]@{ connectionOnly = $true; injectorPid = 42 },
    [pscustomobject]@{ connectionOnly = $false; injectorPid = $null }
  )) {
    $candidate = $connection | ConvertTo-Json | ConvertFrom-Json
    $candidate.connectionOnly = $malformed.connectionOnly
    if ($null -ne $malformed.injectorPid) { $candidate | Add-Member -NotePropertyName injectorPid -NotePropertyValue $malformed.injectorPid }
    Write-DreamSkinState -Path $statePath -State $candidate
    $failure = $null
    try { $null = Read-DreamSkinState -Path $statePath } catch { $failure = $_ }
    if ($null -eq $failure) { throw 'State reader accepted a malformed schema-3 identity.' }
  }

  # Failed connection preparation creates no running state and never touches
  # appearance or launches an injector. All launch/rollback methods are mocks.
  Assert-FixturePath $statePath
  Remove-Item -LiteralPath $statePath -Force
  Reset-Fixture
  $script:failConnect = $true
  $failure = $null
  try { & $startBlock -ConnectOnly } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -cne 'fixture connection failed' -or
    (Test-Path -LiteralPath $statePath) -or -not $script:lockExited -or
    ($script:events -join ',') -cne 'connect,stop,ordinary-start') {
    throw 'Failed connection claimed success or failed its isolated rollback.'
  }
  Assert-NoActiveAnnouncement

  # Selected cold video uses one browser from decode through verification.
  # Native appearance must be installed before that first launch, and candidate
  # publication must wait until decode has succeeded in its connection state.
  Reset-Fixture
  $selectedArguments = @('-Action', 'ApplyTheme', '-ImagePath', 'fixture.mp4', '-DeferLiveApply')
  & $startBlock -CheckOnly -RequireFreshSession
  if ($script:events.Count -ne 0 -or (Test-Path -LiteralPath $statePath) -or -not $script:paused) {
    throw 'Fresh cold preflight mutated the closed session or requested a restart.'
  }
  & $startBlock -RequestedThemeAppearance light -ThemeApplyArguments $selectedArguments
  $running = Read-DreamSkinState -Path $statePath
  if (($script:events -join ',') -cne 'install-light,connect,decode,publish,injector,verify,commit' -or
    @($script:events | Where-Object { $_ -ceq 'connect' }).Count -ne 1 -or
    $running.connectionOnly -or $running.injectorPid -ne 4242 -or
    $script:activeTheme -cne 'selected' -or $script:paused -or -not $script:lockExited) {
    throw "Selected cold video did not complete one verified startup: $($script:events -join ',')."
  }

  # A verified existing browser still requires restart consent for selected
  # native appearance; the read-only fresh check and unapproved actual call
  # must preserve the old injector state without any process/config operation.
  $runningBytes = [System.IO.File]::ReadAllBytes($statePath)
  $script:events = @()
  foreach ($check in @($true, $false)) {
    $failure = $null
    try {
      if ($check) { & $startBlock -CheckOnly -RequireFreshSession }
      else { & $startBlock -RequestedThemeAppearance dark -ThemeApplyArguments $selectedArguments }
    } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike 'DREAM_SKIN_RESTART_REQUIRED:*' -or
      $script:events.Count -ne 0 -or -not (Test-DreamSkinBytesEqual $runningBytes ([System.IO.File]::ReadAllBytes($statePath)))) {
      throw 'Selected startup reused or mutated an existing browser without restart consent.'
    }
  }
  & $startBlock -RestartExisting -RequestedThemeAppearance dark -ThemeApplyArguments $selectedArguments
  if (($script:events -join ',') -cne 'stop,install-dark,connect,decode,publish,injector,verify,commit' -or
    @($script:events | Where-Object { $_ -ceq 'connect' }).Count -ne 1) {
    throw 'Authorized selected startup reopened its browser more than once or skipped native appearance.'
  }

  # Decode failure preserves the previous theme, starts no watcher, closes only
  # the new browser and rolls back its appearance before reopening ordinary Codex.
  Assert-FixturePath $statePath
  Remove-Item -LiteralPath $statePath -Force
  Reset-Fixture
  $script:failDecode = $true
  $failure = $null
  try { & $startBlock -RequestedThemeAppearance light -ThemeApplyArguments $selectedArguments } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -cne 'fixture decode failed' -or
    ($script:events -join ',') -cne 'install-light,connect,decode,stop,restore-appearance,ordinary-start' -or
    $script:activeTheme -cne 'original' -or (Test-Path -LiteralPath $statePath) -or
    -not $script:paused -or -not $script:lockExited) {
    throw "Rejected selected video did not preserve its theme and recover appearance: $($script:events -join ','); $failure."
  }
  Assert-NoActiveAnnouncement

  # A selected native appearance cannot be silently skipped. Preparation
  # failure must stop before starting Codex, decoding or publishing its theme.
  Reset-Fixture
  $script:failAppearance = $true
  $failure = $null
  try { & $startBlock -RequestedThemeAppearance light -ThemeApplyArguments $selectedArguments } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -cne 'fixture appearance preparation failed' -or
    ($script:events -join ',') -cne 'install-light' -or (Test-Path -LiteralPath $statePath) -or
    $script:activeTheme -cne 'original' -or -not $script:paused -or -not $script:lockExited) {
    throw 'Selected startup continued after native appearance preparation failed.'
  }
  Assert-NoActiveAnnouncement

  # A Codex process appearing after cold preflight cannot be adopted or closed
  # by selected startup without another restart confirmation.
  Reset-Fixture
  $script:raceNewSession = $true
  $failure = $null
  try { & $startBlock -RequestedThemeAppearance light -ThemeApplyArguments $selectedArguments } catch { $failure = $_ }
  if ($null -eq $failure -or $failure.Exception.Message -notlike 'DREAM_SKIN_RESTART_REQUIRED:*' -or
    $script:events.Count -ne 0 -or -not $script:cdpReady -or (Test-Path -LiteralPath $statePath) -or
    $script:activeTheme -cne 'original' -or -not $script:paused -or -not $script:lockExited) {
    throw 'Selected startup adopted, stopped or changed a browser appearing after its consent check.'
  }
  Assert-NoActiveAnnouncement

  # Selected-theme startup cannot run as a read-only check, connection helper or
  # foreground watcher. These invalid combinations must have zero mutations.
  foreach ($mode in @('CheckOnly', 'ConnectOnly', 'ForegroundInjector')) {
    Reset-Fixture
    $arguments = @{ RequestedThemeAppearance = 'light'; ThemeApplyArguments = $selectedArguments }
    $arguments[$mode] = $true
    $failure = $null
    try { & $startBlock @arguments } catch { $failure = $_ }
    if ($null -eq $failure -or $failure.Exception.Message -notlike 'Selected theme startup cannot*' -or
      $script:events.Count -ne 0 -or (Test-Path -LiteralPath $statePath)) {
      throw "Selected startup accepted or mutated an incompatible mode: $mode."
    }
  }
} finally {
  $env:LOCALAPPDATA = $originalLocalAppData
  $resolvedFixture = [System.IO.Path]::GetFullPath($fixtureRoot)
  $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedFixture) -notlike 'dreamskin-connect-*') { throw 'Unsafe fixture cleanup path.' }
  Remove-Item -LiteralPath $resolvedFixture -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output 'PASS: connection-only consent remains enforced; selected cold video launches once, validates before publication and rolls back decode failure.'
