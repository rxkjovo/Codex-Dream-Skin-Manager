[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$RecoveryScript)

$ErrorActionPreference = 'Stop'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dream-skin-recovery-test-' + [guid]::NewGuid().ToString('N'))
$scripts = Join-Path $testRoot 'windows\scripts'
$stateRoot = Join-Path $testRoot 'local\CodexDreamSkin'
$themeDirectory = Join-Path $stateRoot 'themes\selected'
$imagePath = Join-Path $testRoot 'selected.jpg'
$logPath = Join-Path $testRoot 'operations.log'
$kindPath = Join-Path $testRoot 'status-kind.txt'
$imageName = 'Selected image'
$chineseTag = [string][char]0x4E2D + [char]0x6587 + [char]0x6807 + [char]0x7B7E
$leftQuote = [char]0x2018; $rightQuote = [char]0x2019
$tagsJson = ('["{0}","comma,tag","O''Brien","smart{1}quotes{2}","O{2}Brien","literal $(1 + 1)"]' -f
  $chineseTag, $leftQuote, $rightQuote)

function Write-Utf8([string]$Path, [string]$Content) {
  [System.IO.File]::WriteAllText($Path, $Content, [System.Text.Encoding]::UTF8)
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ("$Expected" -cne "$Actual") { throw "$Message Expected '$Expected', got '$Actual'." }
}

function Assert-True([bool]$Value, [string]$Message) {
  if (-not $Value) { throw $Message }
}

function Write-TestState {
  $state = [ordered]@{
    schemaVersion = 3; platform = 'windows'; port = 9335; injectorPid = $PID
    injectorStartedAt = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    injectorPath = 'C:\fixture\injector.mjs'; nodePath = 'C:\fixture\node.exe'
    codexExe = 'C:\fixture\Codex.exe'; codexPackageRoot = 'C:\fixture'
    codexPackageFullName = 'fixture'; codexPackageFamilyName = 'fixture'; browserId = 'fixture-browser'
  }
  Write-Utf8 (Join-Path $stateRoot 'state.json') (($state | ConvertTo-Json -Depth 5) + "`r`n")
}

function Invoke-Recovery([switch]$UseImage, [switch]$StartOnly, [switch]$RestartExisting) {
  $previousErrorAction = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $arguments = @('-SkillRoot', (Join-Path $testRoot 'windows'))
    if ($StartOnly) { $arguments += '-StartOnly' }
    if ($RestartExisting) { $arguments += '-RestartExisting' }
    if ($UseImage) {
      $arguments += @(
        '-ImagePath', $imagePath, '-Name', $imageName, '-Appearance', 'dark', '-TagsJson', $tagsJson,
        '-PositionX', '0.4', '-PositionY', '-0.3', '-Zoom', '1.5', '-PositionMode', 'free',
        '-FramingEnabled', 'true'
      )
    } else {
      $arguments += @('-ThemeDirectory', $themeDirectory)
    }
    $result = Invoke-DreamSkinPowerShellScript `
      -ScriptPath (Join-Path $scripts 'apply-theme-and-recover.ps1') -ArgumentList $arguments `
      -SwitchParameters @('-StartOnly', '-RestartExisting')
    $output = $result.Output
    $exitCode = $result.ExitCode
  } finally {
    $ErrorActionPreference = $previousErrorAction
  }
  return [pscustomobject]@{ ExitCode = $exitCode; Output = ($output -join [Environment]::NewLine) }
}

try {
  New-Item -ItemType Directory -Force -Path $scripts, $themeDirectory | Out-Null
  Copy-Item -LiteralPath $RecoveryScript -Destination (Join-Path $scripts 'apply-theme-and-recover.ps1')
  Write-Utf8 (Join-Path $themeDirectory 'theme.json') '{"name":"Selected","image":"background.jpg","appearance":"light"}'
  Write-Utf8 (Join-Path $themeDirectory 'background.jpg') 'fixture-image'
  Write-Utf8 $imagePath 'fixture-image'

  Write-Utf8 (Join-Path $scripts 'common-windows.ps1') @'
function Get-DreamSkinThemePaths {
  param([string]$StateRoot)
  [pscustomobject]@{ Root = $StateRoot; State = (Join-Path $StateRoot 'state.json') }
}
function Enter-DreamSkinOperationLock {
  $mutex = [System.Threading.Mutex]::new($false, $env:RECOVERY_TEST_MUTEX)
  $acquired = $false
  try { $acquired = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) { $mutex.Dispose(); throw 'recovery operation lock is already held' }
  return $mutex
}
function Exit-DreamSkinOperationLock {
  param([System.Threading.Mutex]$Mutex)
  try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
}
function Read-DreamSkinState {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) { return $null }
  return (Get-Content -LiteralPath $Path -Raw) | ConvertFrom-Json
}
function Write-DreamSkinState {
  param([string]$Path, [object]$State)
  if ($env:RECOVERY_TEST_FAIL_SANITIZED -eq '1' -and "$($State.injectorStartedAt)" -like '2000-*') {
    throw 'simulated sanitized state write failure'
  }
  [System.IO.File]::WriteAllText($Path, (($State | ConvertTo-Json -Depth 8) + "`r`n"), [System.Text.Encoding]::UTF8)
}
function Archive-DreamSkinStateFile {
  param([string]$Path)
  $archive = Join-Path (Split-Path -Parent $Path) ('state.archived-' + [guid]::NewGuid().ToString('N') + '.json')
  Move-Item -LiteralPath $Path -Destination $archive
  return $archive
}
function Get-DreamSkinCodexInstall { return [pscustomobject]@{ Executable = 'C:\fixture\Codex.exe' } }
function Get-DreamSkinCodexProcesses { param([object]$Codex) return @() }
function Start-DreamSkinCodex {
  param([object]$Codex)
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'fallback'
  return $null
}
'@
  # Exercise the real safe child-call transport, with no imports or process
  # helpers from the runtime. The child paths and media remain inside this root.
  $commonPath = Join-Path (Split-Path -Parent $RecoveryScript) 'common-windows.ps1'
  $tokens = $null; $parseErrors = $null
  $commonAst = [System.Management.Automation.Language.Parser]::ParseFile(
    [System.IO.Path]::GetFullPath($commonPath), [ref]$tokens, [ref]$parseErrors)
  if ($parseErrors.Count) { throw 'Could not parse child-call runtime helpers.' }
  foreach ($functionName in @('Invoke-DreamSkinNative', 'Invoke-DreamSkinPowerShellScript')) {
    $definitions = @($commonAst.FindAll({ param($node)
      $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $functionName
    }, $true))
    if ($definitions.Count -ne 1) { throw "Could not isolate runtime helper: $functionName." }
    . ([scriptblock]::Create($definitions[0].Extent.Text))
    [System.IO.File]::AppendAllText((Join-Path $scripts 'common-windows.ps1'),
      "`r`n" + $definitions[0].Extent.Text + "`r`n", [System.Text.Encoding]::UTF8)
  }
  Write-Utf8 (Join-Path $scripts 'theme-windows.ps1') @'
function Read-DreamSkinTheme {
  param([string]$ThemeDirectory)
  if (-not (Test-Path -LiteralPath (Join-Path $ThemeDirectory 'theme.json'))) { throw 'missing theme' }
  return [pscustomobject]@{ Theme = [pscustomobject]@{ name = 'Selected'; appearance = 'light' }; ImagePath = (Join-Path $ThemeDirectory 'background.jpg') }
}
function Assert-DreamSkinImageFile { param([string]$Path) if (-not (Test-Path -LiteralPath $Path)) { throw 'missing image' } }
function Assert-DreamSkinVideoDecodable {
  param([string]$Path,[string]$StateRoot)
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'decode'
  if (-not (Test-Path -LiteralPath (Join-Path $StateRoot 'connected'))) { throw 'video validation ran before connection' }
  if ((Get-Content -LiteralPath $Path -Raw) -eq 'reject') { throw 'decode failed' }
}
'@
  Write-Utf8 (Join-Path $scripts 'manager-actions.ps1') @'
param([string]$Action,[string]$SkillRoot,[string]$StateRoot,[string]$ThemeDirectory,[string]$ImagePath,
  [string]$Name,[string]$Appearance,[double]$FocusX,[double]$FocusY,
  [double]$PositionX,[double]$PositionY,[double]$Zoom,[string]$PositionMode,[string]$FramingEnabled,
  [string]$SafeArea,[string]$TaskMode,[string]$Accent,[string]$ThemeId,[string]$Category,[string]$TagsJson,
  [double]$BubbleOpacity,[double]$SurfaceOpacity,[switch]$DeferLiveApply)
if ($Action -eq 'Status') {
  [ordered]@{ statusKind = (Get-Content -LiteralPath $env:RECOVERY_TEST_KIND -Raw).Trim() } | ConvertTo-Json
} elseif ($Action -eq 'ApplyTheme') {
  if ([System.IO.Path]::GetExtension($ImagePath) -ieq '.mp4') {
    . (Join-Path $PSScriptRoot 'theme-windows.ps1')
    Assert-DreamSkinVideoDecodable -Path $ImagePath -StateRoot $StateRoot
  }
  if ($ImagePath -and
      ($PositionX -ne 0.4 -or $PositionY -ne -0.3 -or $Zoom -ne 1.5 -or
       $PositionMode -ne 'free' -or $FramingEnabled -ne 'true')) {
    throw 'custom framing arguments were not preserved'
  }
  if ($ImagePath -and $SurfaceOpacity -ne 0.8) { throw 'surface opacity was not preserved' }
  if ($ImagePath) {
    $testRoot = Split-Path -Parent $env:RECOVERY_TEST_LOG
    $expectedTags = [System.IO.File]::ReadAllText((Join-Path $testRoot 'expected-tags.txt'))
    if ($TagsJson -cne $expectedTags) { throw 'literal JSON tags were changed by child argument forwarding' }
    $expectedNameFile = Join-Path $testRoot 'expected-name.txt'
    if ($Name -cne [System.IO.File]::ReadAllText($expectedNameFile)) { throw 'literal theme name was changed or executed by child argument forwarding' }
  }
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'apply'
  [ordered]@{ applied = $true } | ConvertTo-Json
} else { throw "unexpected action: $Action" }
'@
  Write-Utf8 (Join-Path $scripts 'restore-dream-skin.ps1') @'
param([switch]$ForceRestart,[switch]$NoRelaunch)
Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'restore'
Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\state.json') -Force -ErrorAction SilentlyContinue
'@
  Write-Utf8 (Join-Path $scripts 'start-dream-skin.ps1') @'
param([switch]$RestartExisting,[switch]$ConnectOnly,
  [string]$RequestedThemeAppearance = 'auto',[string[]]$ThemeApplyArguments = @())
if ($ConnectOnly) {
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'connect'
  Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\connected') -Value 'ready'
  return
}
Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'start'
if ($ThemeApplyArguments.Count) {
  $expectedAppearance = if ($ThemeApplyArguments -contains '-ThemeDirectory') { 'light' } else { 'dark' }
  if ($RequestedThemeAppearance -cne $expectedAppearance) { throw 'selected native appearance was not forwarded' }
  if ($ThemeApplyArguments -notcontains '-DeferLiveApply') { throw 'selected startup did not defer live application' }
  if ($env:RECOVERY_TEST_EXPECT_RESTART -and
    ([bool]$RestartExisting) -ne ($env:RECOVERY_TEST_EXPECT_RESTART -eq 'true')) {
    throw 'selected startup did not preserve restart consent'
  }
  Set-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'CodexDreamSkin\connected') -Value 'ready'
  $result = Invoke-DreamSkinPowerShellScript `
    -ScriptPath (Join-Path $PSScriptRoot 'manager-actions.ps1') -ArgumentList $ThemeApplyArguments
  if ($result.ExitCode -ne 0) { throw ($result.Output -join [Environment]::NewLine) }
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'watcher'
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'verify'
  Add-Content -LiteralPath $env:RECOVERY_TEST_LOG -Value 'commit'
}
'@

  $previousLocalAppData = $env:LOCALAPPDATA
  $previousLog = $env:RECOVERY_TEST_LOG
  $previousKind = $env:RECOVERY_TEST_KIND
  $previousMutex = $env:RECOVERY_TEST_MUTEX
  $previousFailSanitized = $env:RECOVERY_TEST_FAIL_SANITIZED
  $previousExpectRestart = $env:RECOVERY_TEST_EXPECT_RESTART
  $env:LOCALAPPDATA = Join-Path $testRoot 'local'
  $env:RECOVERY_TEST_LOG = $logPath
  $env:RECOVERY_TEST_KIND = $kindPath
  $env:RECOVERY_TEST_MUTEX = 'Local\DreamSkinRecoveryTest.' + [guid]::NewGuid().ToString('N')
  Write-Utf8 (Join-Path $testRoot 'expected-name.txt') $imageName
  Write-Utf8 (Join-Path $testRoot 'expected-tags.txt') $tagsJson
  Remove-Item Env:RECOVERY_TEST_FAIL_SANITIZED -ErrorAction SilentlyContinue
  Remove-Item Env:RECOVERY_TEST_EXPECT_RESTART -ErrorAction SilentlyContinue
  try {
    Write-TestState
    Write-Utf8 $kindPath 'mismatch'
    $mismatch = Invoke-Recovery
    Assert-Equal 0 $mismatch.ExitCode "Mismatch recovery failed: $($mismatch.Output)"
    Assert-Equal "restore`r`napply`r`nstart" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Mismatch recovery order changed.'
    Assert-True ($null -ne (Get-Process -Id $PID -ErrorAction SilentlyContinue)) 'Mismatch recovery terminated the unrelated PID.'
    Assert-True (@(Get-ChildItem -LiteralPath $stateRoot -Filter 'state.archived-*.json').Count -eq 1) 'Mismatch state was not archived.'
    Write-Host 'PASS: mismatch recovery archives the bad PID association without terminating it'

    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $stateRoot -Filter 'state.archived-*.json' | Remove-Item -Force
    Write-TestState
    Write-Utf8 $kindPath 'mismatch'
    $imageRecovery = Invoke-Recovery -UseImage
    Assert-Equal 0 $imageRecovery.ExitCode "Image recovery with an empty accent failed: $($imageRecovery.Output)"
    Assert-Equal "restore`r`napply`r`nstart" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Image recovery order changed.'
    Write-Host 'PASS: image recovery omits an empty accent argument safely'

    $imagePath = Join-Path $testRoot 'selected.mp4'
    Write-Utf8 $imagePath 'reject'
    Remove-Item -LiteralPath $logPath -Force
    Write-TestState
    $rejectedVideo = Invoke-Recovery -UseImage
    Assert-True ($rejectedVideo.ExitCode -ne 0) 'Undecodable video recovery was accepted.'
    Assert-Equal "restore`r`nstart`r`ndecode`r`nfallback" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Rejected video was published or started an injector.'
    Write-Utf8 $imagePath 'decodable'
    Remove-Item -LiteralPath $logPath -Force
    Write-TestState
    $videoRecovery = Invoke-Recovery -UseImage
    Assert-Equal 0 $videoRecovery.ExitCode "Decodable video recovery failed: $($videoRecovery.Output)"
    Assert-Equal "restore`r`nstart`r`ndecode`r`napply`r`nwatcher`r`nverify`r`ncommit" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Video must validate and publish within a single startup before watcher verification.'
    Assert-True (@(Get-Content -LiteralPath $logPath | Where-Object { $_ -eq 'start' }).Count -eq 1) 'Video recovery started Codex more than once.'

    # Ordinary selected startup delegates to the same single session and must
    # neither restore an existing install nor silently invent restart consent.
    Write-Utf8 $kindPath 'stopped'
    $env:RECOVERY_TEST_EXPECT_RESTART = 'false'
    Remove-Item -LiteralPath $logPath -Force
    $coldVideo = Invoke-Recovery -UseImage -StartOnly
    Assert-Equal 0 $coldVideo.ExitCode 'Cold selected video startup failed.'
    Assert-Equal "start`r`ndecode`r`napply`r`nwatcher`r`nverify`r`ncommit" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Cold video startup restored or reopened a second session.'
    $imageName = '-dash ' + $chineseTag + ' O''Brien O' + $rightQuote + 'Brien ' +
      $leftQuote + 'quotes' + $rightQuote + ' literal $(1 + 1)'
    Write-Utf8 (Join-Path $testRoot 'expected-name.txt') $imageName
    Remove-Item -LiteralPath $logPath -Force
    $literalVideo = Invoke-Recovery -UseImage -StartOnly
    Assert-Equal 0 $literalVideo.ExitCode "Literal direct-video arguments failed: $($literalVideo.Output)"
    Assert-Equal "start`r`ndecode`r`napply`r`nwatcher`r`nverify`r`ncommit" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Literal argument forwarding changed startup behavior.'
    $imageName = 'Selected image'
    Write-Utf8 (Join-Path $testRoot 'expected-name.txt') $imageName
    $env:RECOVERY_TEST_EXPECT_RESTART = 'true'
    Remove-Item -LiteralPath $logPath -Force
    $authorizedVideo = Invoke-Recovery -UseImage -StartOnly -RestartExisting
    Assert-Equal 0 $authorizedVideo.ExitCode 'Authorized selected video restart failed.'
    Assert-Equal "start`r`ndecode`r`napply`r`nwatcher`r`nverify`r`ncommit" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Authorized video restart did not use the unified session.'
    $env:RECOVERY_TEST_EXPECT_RESTART = 'false'
    Write-Utf8 $imagePath 'reject'
    Remove-Item -LiteralPath $logPath -Force
    $coldRejectedVideo = Invoke-Recovery -UseImage -StartOnly
    Assert-True ($coldRejectedVideo.ExitCode -ne 0) 'Rejected cold selected video unexpectedly succeeded.'
    Assert-Equal "start`r`ndecode" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'StartOnly rejection published a theme or duplicated startup fallback.'
    Remove-Item Env:RECOVERY_TEST_EXPECT_RESTART -ErrorAction SilentlyContinue
    $imagePath = Join-Path $testRoot 'selected.jpg'
    Write-Host 'PASS: selected video validates in one startup, forwards restart consent and rejects before publication'

    Remove-Item -LiteralPath $logPath -Force
    Write-Utf8 $kindPath 'stopped'
    $coldSavedTheme = Invoke-Recovery -StartOnly
    Assert-Equal 0 $coldSavedTheme.ExitCode 'Selected saved-theme startup failed.'
    Assert-Equal "start`r`napply`r`nwatcher`r`nverify`r`ncommit" ((Get-Content -LiteralPath $logPath) -join "`r`n") 'Saved-theme startup did not preserve its selected appearance and unified invocation.'

    # A StartOnly request cannot bypass explicit recovery for unsafe process
    # identities, and the rejection must preserve diagnostic state byte-for-byte.
    Remove-Item -LiteralPath $logPath -Force
    Write-TestState
    $beforeUnsafeStartup = [System.IO.File]::ReadAllText((Join-Path $stateRoot 'state.json'))
    foreach ($unsafeKind in @('mismatch', 'uninspectable', 'error')) {
      Write-Utf8 $kindPath $unsafeKind
      $unsafeStartup = Invoke-Recovery -StartOnly -RestartExisting
      Assert-True ($unsafeStartup.ExitCode -ne 0) "StartOnly bypassed $unsafeKind recovery."
      Assert-True (-not (Test-Path -LiteralPath $logPath)) "StartOnly mutated an unsafe $unsafeKind session."
      Assert-Equal $beforeUnsafeStartup ([System.IO.File]::ReadAllText((Join-Path $stateRoot 'state.json'))) 'Unsafe StartOnly changed diagnostic state.'
    }
    Write-Host 'PASS: StartOnly preserves selected appearance and rejects unsafe recovery states without mutation'

    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $stateRoot -Filter 'state.archived-*.json' | Remove-Item -Force
    Write-TestState
    Write-Utf8 $kindPath 'uninspectable'
    $uninspectable = Invoke-Recovery
    Assert-True ($uninspectable.ExitCode -ne 0) 'Uninspectable recovery unexpectedly succeeded while the PID remained alive.'
    $operations = @((Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue))
    Assert-True ($operations -contains 'restore') 'Uninspectable recovery did not close Codex first.'
    Assert-True ($operations -contains 'fallback') 'Uninspectable recovery did not reopen Codex after aborting.'
    Assert-True ($operations -notcontains 'apply') 'Uninspectable recovery changed the theme before proving the old process exited.'
    Assert-True ($operations -notcontains 'start') 'Uninspectable recovery started a second watcher.'
    Assert-True (@($operations | Where-Object { $_ -eq 'fallback' }).Count -eq 1) 'Uninspectable recovery reopened Codex more than once.'
    Assert-True (Test-Path -LiteralPath (Join-Path $stateRoot 'state.json')) 'Uninspectable recovery did not restore diagnostic state.'
    Assert-True ($null -ne (Get-Process -Id $PID -ErrorAction SilentlyContinue)) 'Uninspectable recovery terminated the unknown PID.'
    Write-Host 'PASS: uninspectable recovery aborts safely before applying the theme'

    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $stateRoot -Filter 'state.archived-*.json' | Remove-Item -Force
    Write-TestState
    Write-Utf8 $kindPath 'mismatch'
    $env:RECOVERY_TEST_FAIL_SANITIZED = '1'
    $writeFailure = Invoke-Recovery
    Assert-True ($writeFailure.ExitCode -ne 0) 'Sanitized state write failure unexpectedly succeeded.'
    $restoredAfterWriteFailure = Get-Content -LiteralPath (Join-Path $stateRoot 'state.json') -Raw | ConvertFrom-Json
    Assert-Equal $PID ([int]$restoredAfterWriteFailure.injectorPid) 'Original state was not restored after sanitized write failure.'
    Assert-True (@(Get-Content -LiteralPath $logPath -ErrorAction SilentlyContinue) -contains 'fallback') 'Write failure did not reopen Codex.'
    Remove-Item Env:RECOVERY_TEST_FAIL_SANITIZED -ErrorAction SilentlyContinue
    Write-Host 'PASS: sanitized state write failure restores the original diagnostic state'

    Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $stateRoot -Filter 'state.archived-*.json' | Remove-Item -Force
    Write-TestState
    Write-Utf8 $kindPath 'mismatch'
    $heldMutex = [System.Threading.Mutex]::new($false, $env:RECOVERY_TEST_MUTEX)
    $heldMutex.WaitOne() | Out-Null
    try {
      $blocked = Invoke-Recovery
      Assert-True ($blocked.ExitCode -ne 0) 'Recovery ignored an existing operation lock.'
      Assert-True (-not (Test-Path -LiteralPath $logPath)) 'Recovery performed work while another operation held the lock.'
    } finally {
      $heldMutex.ReleaseMutex()
      $heldMutex.Dispose()
    }
    Write-Host 'PASS: recovery honors the cross-stage operation lock'
  } finally {
    $env:LOCALAPPDATA = $previousLocalAppData
    $env:RECOVERY_TEST_LOG = $previousLog
    $env:RECOVERY_TEST_KIND = $previousKind
    if ($null -eq $previousMutex) { Remove-Item Env:RECOVERY_TEST_MUTEX -ErrorAction SilentlyContinue } else { $env:RECOVERY_TEST_MUTEX = $previousMutex }
    if ($null -eq $previousFailSanitized) { Remove-Item Env:RECOVERY_TEST_FAIL_SANITIZED -ErrorAction SilentlyContinue } else { $env:RECOVERY_TEST_FAIL_SANITIZED = $previousFailSanitized }
    if ($null -eq $previousExpectRestart) { Remove-Item Env:RECOVERY_TEST_EXPECT_RESTART -ErrorAction SilentlyContinue } else { $env:RECOVERY_TEST_EXPECT_RESTART = $previousExpectRestart }
  }
} finally {
  $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
  $tempPrefix = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\') + '\'
  if (-not $resolvedTestRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
    [System.IO.Path]::GetFileName($resolvedTestRoot) -notlike 'dream-skin-recovery-test-*') {
    throw 'Unsafe recovery fixture cleanup path.'
  }
  Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force -ErrorAction SilentlyContinue
}
