#Requires -Version 7.0
# Offline safety checks for ship.ps1 and review-pr.ps1. No pull request, tag or release is created.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ship.ps1')
$testRoot = Join-Path (Get-ScratchRoot) ('bpm-ship-checks-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
# No background gc or maintenance in the fixture repositories, which would hold their files while they are removed.
$env:GIT_CONFIG_COUNT = '2'
$env:GIT_CONFIG_KEY_0 = 'gc.auto'; $env:GIT_CONFIG_VALUE_0 = '0'
$env:GIT_CONFIG_KEY_1 = 'maintenance.auto'; $env:GIT_CONFIG_VALUE_1 = 'false'
$checks = 0
function Expect-Rejected {
    param([scriptblock]$Action, [string]$Name)
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw "FAIL: $Name" }
    $script:checks++; Write-Host "PASS: $Name"
}
function Check {
    param([bool]$Value, [string]$Name)
    if (!$Value) { throw "FAIL: $Name" }
    $script:checks++; Write-Host "PASS: $Name"
}
function V { param([string]$Name, [int]$Build) [pscustomobject]@{ Name = $Name; Build = $Build } }
try {
    Check ((Get-ShipVersion '' '0.12.1' '0.12.1') -eq '0.12.2') 'next patch version is chosen automatically'
    Check ((Get-ShipVersion '' '0.12.2' '0.12.1') -eq '0.12.3') 'public version takes precedence over older source'
    foreach ($version in @('0.12.1', '0.12.0', '0.12.2-beta', '0.12')) {
        Expect-Rejected { Get-ShipVersion $version '0.12.1' '0.12.1' } "unsafe version $version is rejected"
    }
    $next = Get-PullRequestVersion '' '0.12.1' (V '0.12.1' 25) (V '0.12.1' 25)
    Check ($next.Name -eq '0.12.2' -and $next.Build -eq 26) 'a new pull request gets the next patch version and build number'
    $kept = Get-PullRequestVersion '' '0.12.1' (V '0.12.1' 25) (V '0.12.2' 26)
    Check ($kept.Name -eq '0.12.2' -and $kept.Build -eq 26) 'a bumped branch keeps its version across review rounds'
    $overtaken = Get-PullRequestVersion '' '0.12.2' (V '0.12.2' 26) (V '0.12.2' 26)
    Check ($overtaken.Name -eq '0.12.3' -and $overtaken.Build -eq 27) 'a branch overtaken by a release is bumped again'
    $nameOnly = Get-PullRequestVersion '' '0.12.1' (V '0.12.1' 25) (V '0.13.0' 25)
    Check ($nameOnly.Name -eq '0.13.0' -and $nameOnly.Build -eq 26) 'a branch that raised only the name still gets a higher build number'
    $explicit = Get-PullRequestVersion '0.13.0' '0.12.1' (V '0.12.1' 25) (V '0.12.2' 26)
    Check ($explicit.Name -eq '0.13.0' -and $explicit.Build -eq 26) 'an explicit version replaces the branch version'
    Expect-Rejected { Get-PullRequestVersion '0.12.1' '0.12.1' (V '0.12.1' 25) (V '0.12.2' 26) } 'an explicit version must still be higher than every release'
    $pubspec = "name: app`r`n# The release tag must be v<version>.`r`nversion: 0.12.1+25`r`nenvironment:`r`n"
    Check ((ConvertFrom-PubspecVersion $pubspec).Name -eq '0.12.1' -and (ConvertFrom-PubspecVersion $pubspec).Build -eq 25) 'the pubspec version and build number are read'
    $written = Set-PubspecVersion $pubspec (V '0.12.2' 26)
    Check ($written -ceq $pubspec.Replace('0.12.1+25', '0.12.2+26')) 'the version is written in place, keeping line endings'
    Expect-Rejected { ConvertFrom-PubspecVersion "version: 0.12.1`n" } 'a version without a build number is rejected'
    Expect-Rejected { ConvertFrom-PubspecVersion "version: 0.12.1+25`nversion: 0.12.2+26`n" } 'two version lines are rejected'
    $repoPubspec = ConvertFrom-PubspecVersion ([IO.File]::ReadAllText((Join-Path $PSScriptRoot '../pubspec.yaml')))
    Check ($repoPubspec.Build -gt 0) "the repository's pubspec.yaml has a version ship.ps1 can read ($($repoPubspec.Name)+$($repoPubspec.Build))"
    foreach ($path in @('lib/main.dart', 'test/app_test.dart', 'android/app/build.gradle.kts', 'android/app/src/main/res/mipmap-hdpi/ic_launcher.png',
            'assets/fonts/font.ttf', 'windows/runner/resources/app_icon.ico', 'packages/blackpearl_datachannel/src/CMakeLists.txt', 'tool/icon/foreground.svg',
            'tool/standin-pc/index.js', 'scripts/ship.ps1', '.github/workflows/build.yml', '.claude/skills/review-pr/SKILL.md', 'README.md', 'pubspec.yaml',
            'pubspec.lock', 'analysis_options.yaml', '.metadata', '.gitattributes')) {
        Check ((Assert-ShipPathName $path) -eq $path) "release source path $path is accepted"
    }
    foreach ($path in @('../outside.dart', 'build/app/outputs/app.apk', 'android/key.properties', 'android/local.properties', 'android/app/release.jks',
            'upload.keystore', 'android/app/google-services.json', 'lib/.env', 'BlackPearl-v0.12.1.apk', 'REPORT.html', 'screenshot.png', 'lib/ui/screenshot.png',
            'tool/standin-pc/.state/pairing.json', 'tool/standin-pc/node_modules/ws/index.js', '.dart_tool/package_config.json', 'artifacts/record.json',
            'clip.mp4', '.claude/settings.json', '.gitignore', 'notes.txt')) {
        Expect-Rejected { Assert-ShipPathName $path } "excluded path $path cannot enter a pull request"
    }
    $summary = "Fixes seeking.`n`nIntentional: removes the old toggle."
    $body = Format-PullRequestBody $summary 'Seeking is faster' '0.12.2'
    Check ((Get-ReleaseNote $body) -ceq 'Seeking is faster' -and (Get-PullRequestSummary $body) -ceq $summary) 'release note and description survive a pull request body round trip'
    Check ($null -eq (Get-ReleaseNote 'Edited by hand')) 'a body without a release note yields none'
    $headA = 'a' * 40; $headB = 'b' * 40
    function New-ReviewComment { param([string]$Head, [string]$Verdict, [string]$Association = 'OWNER', [int]$Minute = 0)
        [pscustomobject]@{ body = "Findings`n$(Format-ReviewMarker $Head $Verdict)"; author_association = $Association; created_at = [datetime]::new(2026, 1, 1, 0, $Minute, 0); html_url = "https://github.com/fixture/$Minute" } }
    Check ((Assert-ReviewApproval @((New-ReviewComment $headA 'changes' -Minute 1), (New-ReviewComment $headA 'approve' -Minute 2)) $headA).Verdict -eq 'approve') 'an approval of the exact head after earlier findings allows the merge'
    Expect-Rejected { Assert-ReviewApproval @() $headA } 'a pull request without a review cannot merge'
    Expect-Rejected { Assert-ReviewApproval @(New-ReviewComment $headA 'approve') $headB } 'an approval of an older head does not cover new commits'
    Expect-Rejected { Assert-ReviewApproval @((New-ReviewComment $headA 'approve' -Minute 1), (New-ReviewComment $headA 'changes' -Minute 2)) $headA } 'requested changes after an approval block the merge'
    Expect-Rejected { Assert-ReviewApproval @((New-ReviewComment $headA 'changes' -Minute 2), (New-ReviewComment $headA 'approve' -Minute 1)) $headA } 'the newest verdict wins regardless of response order'
    Expect-Rejected { Assert-ReviewApproval @(New-ReviewComment $headA 'approve' 'NONE') $headA } 'a public commenter cannot approve'
    $quoting = New-ReviewComment $headA 'changes' -Minute 3
    $quoting.body = "The parser accepts ``$(Format-ReviewMarker $headA 'approve')`` anywhere.`n$(Format-ReviewMarker $headA 'changes')"
    Expect-Rejected { Assert-ReviewApproval @((New-ReviewComment $headA 'approve' -Minute 1), $quoting) $headA } 'findings quoting an approval marker cannot turn requested changes into an approval'
    $sameSecond = @((New-ReviewComment $headA 'changes'), (New-ReviewComment $headA 'approve'))
    $sameSecond[0] | Add-Member id 20; $sameSecond[1] | Add-Member id 10
    Expect-Rejected { Assert-ReviewApproval $sameSecond $headA } 'comments posted in the same second are ordered by id'
    Expect-Rejected { Assert-ReviewApproval @([pscustomobject]@{ body = "LGTM <!-- blackpearl-mobile-review head=$headA verdict=approved -->"; author_association = 'OWNER'; created_at = [datetime]::UtcNow }) $headA } 'a malformed verdict marker does not approve'
    $desktop = New-ReviewComment $headA 'approve'
    $desktop.body = "Findings`n<!-- blackpearl-review head=$headA verdict=approve -->"
    Expect-Rejected { Assert-ReviewApproval @($desktop) $headA } "the desktop repository's verdict marker does not approve here"
    function New-BuildRun { param([string]$Event, [string]$Status, [string]$Conclusion, [int]$Id = 1, [int]$Attempt = 1, [string]$Head = $headA, [string]$Name = 'build')
        [pscustomobject]@{ id = $Id; run_attempt = $Attempt; event = $Event; status = $Status; conclusion = $Conclusion; head_sha = $Head; name = $Name; html_url = "https://github.com/fixture/run/$Id" } }
    Check ((Get-HeadCheckState @() $headA).State -eq 'pending') 'merging waits for the build workflow to start'
    Check ((Get-HeadCheckState @((New-BuildRun 'push' 'completed' 'success'), (New-BuildRun 'pull_request' 'in_progress' $null -Id 2)) $headA).State -eq 'pending') 'merging waits for every build of the head'
    Check ((Get-HeadCheckState @((New-BuildRun 'pull_request' 'completed' 'success')) $headA).State -eq 'success') 'a passing build of the head allows the merge'
    Check ((Get-HeadCheckState @((New-BuildRun 'push' 'completed' 'success'), (New-BuildRun 'pull_request' 'completed' 'failure' -Id 2)) $headA).State -eq 'failure') 'a failed build of the head blocks the merge'
    Check ((Get-HeadCheckState @((New-BuildRun 'pull_request' 'completed' 'failure'), (New-BuildRun 'pull_request' 'completed' 'success' -Attempt 2)) $headA).State -eq 'success') 'a successful rerun replaces its failed attempt'
    Check ((Get-HeadCheckState @(New-BuildRun 'pull_request' 'completed' 'cancelled') $headA).State -eq 'failure') 'a cancelled build of the head blocks the merge'
    Check ((Get-HeadCheckState @(New-BuildRun 'pull_request' 'completed' 'success' -Head $headB) $headA).State -eq 'pending') 'builds of other commits do not count'
    Check ((Get-HeadCheckState @(New-BuildRun 'pull_request' 'completed' 'success' -Name 'other') $headA).State -eq 'pending') 'other workflows do not count'
    # The workflow ship.ps1 waits for is the one in the repository.
    $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../.github/workflows/build.yml') -Raw
    Check ($workflow -match "(?m)^name:\s*$([regex]::Escape($buildWorkflow))\s*$") "the build workflow is named '$buildWorkflow'"
    Check ($workflow -match 'scripts/release-checks\.ps1 -Lane ci' -and $workflow -notmatch '(?m)^\s*- run: flutter (analyze|test)') 'the workflow runs the release checks from the shared list'

    # Published APKs, as the release workflow names them and the app's updater looks for them.
    $apkPath = Join-Path $testRoot 'BlackPearl-v0.12.2.apk'
    [IO.File]::WriteAllBytes($apkPath, [byte[]](1, 2, 3, 4))
    $hash = (Get-FileHash $apkPath -Algorithm SHA256).Hash.ToLowerInvariant()
    function New-Apk { param([string]$Name, [string]$Digest = "sha256:$hash", [long]$Size = 4)
        [pscustomobject]@{ name = $Name; size = $Size; digest = $Digest; state = 'uploaded'; browser_download_url = "https://github.com/Svovoniks/BlackPearlMobile/releases/download/v0.12.2/$Name" } }
    $arm64 = New-Apk 'BlackPearl-v0.12.2.apk'; $arm32 = New-Apk 'BlackPearl-v0.12.2-armeabi-v7a.apk'
    $release = [pscustomobject]@{ tag_name = 'v0.12.2'; draft = $false; prerelease = $false; assets = @($arm64, $arm32) }
    Check (@(Assert-ReleaseMetadata $release '0.12.2').Count -eq 2) 'a release with both APKs passes'
    $app = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../lib/update/app_update.dart'))
    Check ($app.Contains("r'^BlackPearl-v\d+(?:\.\d+)*(?:-([a-z0-9_-]+))?\.apk$'") -and $app.Contains("plainApkAbi = 'arm64-v8a'")) "the APK names checked are the ones the app's updater looks for"
    Check ((Assert-ApkBytes $apkPath $arm64) -eq $hash) 'a downloaded APK matches its published digest'
    $release.assets = @($arm64)
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'a release missing the 32-bit APK cannot be reported as shipped'
    $release.assets = @($arm64, $arm32)
    $arm32.state = 'starter'
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'an APK still uploading cannot be reported as shipped'
    $arm32.state = 'uploaded'
    $release.draft = $true
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'draft cannot be reported as shipped'
    $release.draft = $false; $release.prerelease = $true
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'prerelease cannot be reported as stable'
    $release.prerelease = $false
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.3' } 'wrong latest version cannot pass verification'
    $arm64.browser_download_url = 'https://example.com/app.apk'
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'APK URL must belong to the expected release'
    $arm64.browser_download_url = 'https://github.com/Svovoniks/BlackPearlMobile/releases/download/v0.12.2/BlackPearl-v0.12.2.apk'
    $arm64.digest = ''
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'missing GitHub digest prevents verification'
    $arm64.digest = "sha256:$hash"
    $arm64.size = 0
    Expect-Rejected { Assert-ReleaseMetadata $release '0.12.2' } 'an empty APK prevents verification'
    $arm64.size = 4
    [IO.File]::WriteAllBytes($apkPath, [byte[]](4, 3, 2, 1))
    Expect-Rejected { Assert-ApkBytes $apkPath $arm64 } 'same-size corrupted APK is rejected'
    [IO.File]::WriteAllBytes($apkPath, [byte[]](1, 2, 3))
    Expect-Rejected { Assert-ApkBytes $apkPath $arm64 } 'truncated APK is rejected'
    function Get-PublicJson {
        param([string]$Url)
        return @{ workflow_runs = @(
            @{id=1;head_branch='master';head_sha='fixture';name='build';status='completed';conclusion='success';run_attempt=1},
            @{id=2;head_branch='v0.12.2';head_sha='other';name='build';status='completed';conclusion='success';run_attempt=1},
            @{id=3;head_branch='v0.12.2';head_sha='fixture';name='build';status='completed';conclusion=$script:mockConclusion;run_attempt=1;html_url='https://github.com/fixture/run'}
        ) }
    }
    $script:mockConclusion = 'success'
    $run = Wait-ReleaseBuild '0.12.2' 'fixture' ([datetime]::UtcNow.AddSeconds(5))
    Check ($run.id -eq 3) 'only the exact tag and commit workflow count as a release build'
    $script:mockConclusion = 'failure'
    Expect-Rejected { Wait-ReleaseBuild '0.12.2' 'fixture' ([datetime]::UtcNow.AddSeconds(5)) } 'failed tag workflow stops shipping'

    # Release checks run in the background after the push; -Merge reads their record.
    $recordPath = Join-Path $testRoot "checks/$headA.json"
    Check ((Get-CheckState $recordPath).State -eq 'missing') 'a commit without a check record is reported as unchecked'
    $self = Get-Process -Id $PID
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = $PID; ProcessStart = $self.StartTime.ToUniversalTime().Ticks }
    Check ((Get-CheckState $recordPath).State -eq 'running') 'checks whose process is alive are running'
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = $PID; ProcessStart = $self.StartTime.ToUniversalTime().Ticks - 1 }
    Check ((Get-CheckState $recordPath).State -eq 'interrupted') 'a reused process id does not count as the running checks'
    # Its start time is read while it runs: on Linux a process that has exited has none.
    $finished = Start-Process -FilePath $self.Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 2') -PassThru
    $finishedStart = $finished.StartTime.ToUniversalTime().Ticks
    $finished.WaitForExit()
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = $finished.Id; ProcessStart = $finishedStart }
    Check ((Get-CheckState $recordPath).State -eq 'interrupted') 'checks whose process ended without a result were interrupted'
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = 4; ProcessStart = 1 }
    Check ((Get-CheckState $recordPath).State -eq 'interrupted') 'a process id reused by a system process does not count as the running checks'
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'failed'; Error = 'fixture failure' }
    Check ((Get-CheckState $recordPath).State -eq 'failed') 'failed checks are reported as failed'
    Check (@(Get-ChildItem -LiteralPath (Split-Path -Parent $recordPath) -Filter '*.partial-*').Count -eq 0) 'check records are replaced whole'
    $copyRepo = Join-Path $testRoot 'check-copy-repo'
    Invoke-Native git @('init', '--quiet', $copyRepo)
    Invoke-Native git @('-C', $copyRepo, '-c', 'user.name=Shipping checks', '-c', 'user.email=checks@example.invalid', 'commit', '--quiet', '--allow-empty', '-m', 'fixture')
    $staleCopy = Join-Path $testRoot 'stale-check-copy'
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $staleCopy, 'HEAD')
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = $PID; ProcessStart = $self.StartTime.ToUniversalTime().Ticks; Checkout = $staleCopy }
    Remove-StaleCheckCopy $copyRepo $recordPath
    Check (Test-Path -LiteralPath $staleCopy) 'the copy of checks still running is kept'
    Write-CheckRecord $recordPath @{ Commit = $headA; State = 'running'; Pid = 4; ProcessStart = 1; Checkout = $staleCopy }
    Remove-StaleCheckCopy $copyRepo $recordPath
    Check (!(Test-Path -LiteralPath $staleCopy) -and @(Invoke-Native git @('-C', $copyRepo, 'worktree', 'list')).Count -eq 1) 'checking a commit again removes the copy an interrupted run left behind'
    # A newer commit of the branch replaces older ones, whose failed or interrupted copies are then removed.
    $copyRecords = Join-Path (Invoke-Native git @('-C', $copyRepo, 'rev-parse', '--path-format=absolute', '--git-common-dir')).Trim() 'blackpearl-checks'
    $otherCopy = Join-Path $testRoot 'other-branch-copy'
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $staleCopy, 'HEAD')
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $otherCopy, 'HEAD')
    Write-CheckRecord (Join-Path $copyRecords "$headA.json") @{ Commit = $headA; Branch = 't3/fixture'; State = 'failed'; Error = 'fixture'; Checkout = $staleCopy }
    Write-CheckRecord (Join-Path $copyRecords "$('c' * 40).json") @{ Commit = 'c' * 40; Branch = 't3/other'; State = 'failed'; Error = 'fixture'; Checkout = $otherCopy }
    Stop-SupersededChecks $copyRepo 't3/fixture' $headB
    $replaced = Get-CheckState (Join-Path $copyRecords "$headA.json")
    Check (!(Test-Path -LiteralPath $staleCopy) -and $replaced.State -eq 'failed' -and !$replaced.PSObject.Properties['Checkout']) 'a newer commit of the branch removes the copy a failed run of an older one kept'
    Check (Test-Path -LiteralPath $otherCopy) 'copies kept for other branches stay'
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $staleCopy, 'HEAD')
    Write-CheckRecord (Join-Path $copyRecords "$headA.json") @{ Commit = $headA; Branch = 't3/fixture'; State = 'running'; Pid = 4; ProcessStart = 1; Checkout = $staleCopy }
    Stop-SupersededChecks $copyRepo 't3/fixture' $headB
    $replaced = Get-CheckState (Join-Path $copyRecords "$headA.json")
    Check (!(Test-Path -LiteralPath $staleCopy) -and $replaced.State -eq 'interrupted' -and !$replaced.PSObject.Properties['Checkout']) 'a newer commit of the branch removes the copy an interrupted run of an older one left'
    # Cleanups are best effort: they never throw, and never hide what failed.
    $treePath = Join-Path $testRoot 'tree/a/b'
    New-Item -ItemType Directory -Path $treePath -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $treePath 'f.txt'), 'x'); [IO.File]::SetAttributes((Join-Path $treePath 'f.txt'), [IO.FileAttributes]::ReadOnly)
    [IO.DirectoryInfo]::new($treePath).Attributes = [IO.FileAttributes]::Directory -bor [IO.FileAttributes]::ReadOnly
    Check ((Remove-Tree (Join-Path $testRoot 'tree')) -and !(Test-Path -LiteralPath (Join-Path $testRoot 'tree'))) 'a folder with read-only files and folders is removed'
    Check (Remove-Tree (Join-Path $testRoot 'never-made')) 'removing what is not there succeeds'
    $heldCopy = Join-Path (Get-ScratchRoot) ('bpm-ship-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $heldCopy, 'HEAD')
    $held = [IO.File]::Open((Join-Path $heldCopy 'held.txt'), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $gone = $true
        $threw = $false
        try { $gone = Remove-CheckCopy $copyRepo $heldCopy } catch { $threw = $true }
        # Only Windows keeps a file that is open from being deleted.
        Check (!$threw -and ($gone -eq !$IsWindows)) 'a check copy with a file still open is reported as kept, not as an error'
    }
    finally { $held.Dispose() }
    Check (Remove-CheckCopy $copyRepo $heldCopy) 'the copy goes once nothing holds it'
    $fakeCheckout = Join-Path $testRoot 'fake-checkout'
    New-Item -ItemType Directory -Path (Join-Path $fakeCheckout 'scripts') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $fakeCheckout 'scripts/release-checks.ps1'),
        ("param([string]`$Lane, [string]`$Flutter, [string]`$FailureFile)`n" +
        "New-Item -ItemType Directory -Path `$env:BLACKPEARL_NATIVE_STAGING -Force | Out-Null`n" +
        "`$env:BLACKPEARL_NATIVE_STAGING | Set-Content -LiteralPath (Join-Path `$PSScriptRoot 'staging.txt')`n" +
        "'native build' | Set-Content -LiteralPath (Join-Path `$env:BLACKPEARL_NATIVE_STAGING 'CMakeCache.txt')`n" +
        "'Tests failed with exit code 1.' | Set-Content -LiteralPath `$FailureFile`nexit 1`n"))
    $message = ''
    $outerStaging = $env:BLACKPEARL_NATIVE_STAGING
    try { Invoke-ReleaseChecks $fakeCheckout 'flutter' } catch { $message = "$_" }
    Check ($message -ceq 'Tests failed with exit code 1.') "a failed release check is recorded by its own error ($message)"
    $usedStaging = (Get-Content -LiteralPath (Join-Path $fakeCheckout 'scripts/staging.txt') -Raw).Trim()
    Check ((Split-Path -Leaf $usedStaging) -match '^bpm-dc-[a-f0-9]{12}$' -and !(Test-Path -LiteralPath $usedStaging) -and $env:BLACKPEARL_NATIVE_STAGING -ceq $outerStaging) 'the native build of a checked copy gets its own folder, which goes with it'
    # Checks killed by a newer push never reach their own cleanup: their copy's native build goes with the copy.
    $killedId = [guid]::NewGuid().ToString('N').Substring(0, 12)
    $killedCopy = Join-Path (Get-ScratchRoot) "bpm-ship-$killedId"
    $killedStaging = Join-Path (Get-ScratchRoot) "bpm-dc-$killedId"
    Check ((Get-NativeStagingPath $killedCopy) -ceq $killedStaging) "a check copy's native build is named after it"
    Invoke-Native git @('-C', $copyRepo, 'worktree', 'add', '--quiet', '--detach', $killedCopy, 'HEAD')
    New-Item -ItemType Directory -Path (Join-Path $killedStaging 'arm64-v8a') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $killedStaging 'arm64-v8a/CMakeCache.txt'), 'native build')
    $running = Start-Process -FilePath $self.Path -ArgumentList @('-NoProfile', '-Command', 'Start-Sleep -Seconds 120') -PassThru
    try {
        Write-CheckRecord (Join-Path $copyRecords "$('d' * 40).json") @{ Commit = 'd' * 40; Branch = 't3/killed'; State = 'running'; Pid = $running.Id; ProcessStart = $running.StartTime.ToUniversalTime().Ticks; Checkout = $killedCopy }
        Stop-SupersededChecks $copyRepo 't3/killed' $headB
        $killed = Get-CheckState (Join-Path $copyRecords "$('d' * 40).json")
        Check ($running.HasExited -and $killed.State -eq 'superseded' -and !(Test-Path -LiteralPath $killedCopy) -and !(Test-Path -LiteralPath $killedStaging) -and !$killed.PSObject.Properties['Checkout']) 'superseded checks that were killed leave neither their copy nor its native build'
    }
    finally { if (!$running.HasExited) { $running.Kill($true) }; $null = Remove-CheckCopy $copyRepo $killedCopy }
    Check (!(Test-ScratchFolder (Join-Path $testRoot 'bpm-dc-0123456789ab') 'bpm-dc') -and !(Test-ScratchFolder (Join-Path (Get-ScratchRoot) 'bpm-dc-other') 'bpm-dc')) 'only folders this script makes are removed'
    # A run with a wait limit stops with a named next command instead of waiting past it, so an agent can wait in the
    # foreground: a thread whose pull request merged can be settled, and its agent stopped, between turns.
    $now = [datetime]::UtcNow
    Check ((Get-ShipPauseAt 0) -eq [datetime]::MaxValue) 'a wait limit of 0 never stops a run early'
    Check ((Get-ShipPauseAt 7 $now) -eq $now.AddMinutes(7)) 'a wait limit stops a run after that many minutes'
    Suspend-ShipWhenDue $now.AddMinutes(5) 'fixture' './scripts/ship.ps1 -Merge'
    Check $true 'a run within its wait limit keeps waiting'
    $pause = $null
    try { Suspend-ShipWhenDue $now.AddSeconds(-1) 'the fixture is still running' './scripts/ship.ps1 -Merge' } catch { $pause = $_.Exception }
    Check ($pause -is [ShipPausedException] -and $pause.Message.Contains('./scripts/ship.ps1 -Merge') -and $pause.Message.Contains('the fixture is still running')) 'a run past its wait limit stops and names what it waits for and the command that continues'
    # One deadline for a whole ship: each stopped run hands it to the next, so -TimeoutMinutes still ends a stuck ship.
    Check ((Get-ShipDeadline '' 60 $now) -eq $now.AddMinutes(60)) 'a first run gets the deadline -TimeoutMinutes sets'
    $carried = Format-ShipResume './scripts/ship.ps1 -Merge' $now.AddMinutes(53) 6
    $until = [regex]::Match($carried, "-Until '([^']+)'").Groups[1].Value
    Check ((Get-ShipDeadline $until 60 $now.AddMinutes(30)) -eq $now.AddMinutes(53) -and $carried.Contains('-WaitMinutes 6')) 'a rerun keeps the deadline and wait limit of the run that stopped'
    Check ($null -ne [System.Management.Automation.Language.Parser]::ParseInput($carried, [ref]$null, [ref]$null) -and $carried.StartsWith('./scripts/ship.ps1 -Merge ')) 'the command a stopped run names can be run as printed'
    foreach ($bad in @('tomorrow', '2026-01-01T00:00:00', '2026-01-01T04:00:00+04:00')) {
        Expect-Rejected { Get-ShipDeadline $bad 60 $now } "-Until $bad is rejected"
    }
    $originalPublicJson = ${function:Get-PublicJson}
    try {
        $script:fixtureRun = [pscustomobject]@{ id = 7; status = 'in_progress'; conclusion = $null; head_branch = 'v0.12.12'; head_sha = 'f' * 40; name = 'build'; run_attempt = 1; html_url = 'https://github.com/fixture/run' }
        $script:fixtureLatest = 'v0.12.11'
        function Get-PublicJson {
            param([string]$Uri)
            if ($Uri -match '/releases/latest$') { return [pscustomobject]@{ tag_name = $script:fixtureLatest } }
            if ($Uri -match '/actions/runs[?]') { return [pscustomobject]@{ workflow_runs = @($script:fixtureRun) } }
            return $script:fixtureRun
        }
        $resume = './scripts/ship.ps1 -VerifyOnly -Version 0.12.12'
        $pause = $null
        try { Wait-ReleaseBuild '0.12.12' ('f' * 40) $now.AddMinutes(60) $now.AddSeconds(-1) $resume | Out-Null } catch { $pause = $_.Exception }
        Check ($pause -is [ShipPausedException] -and $pause.Message.Contains($resume)) 'a tag build still running past the wait limit stops the run and names -VerifyOnly'
        $pause = $null
        try { Wait-ReleaseBuild '0.12.12' $script:fixtureRun.head_sha $now.AddMinutes(60) $now.AddSeconds(-1) $resume '#7 is merged as abc and tagged v0.12.12' | Out-Null } catch { $pause = $_.Exception }
        Check ($pause -is [ShipPausedException] -and $pause.Message.Contains('#7 is merged as abc and tagged v0.12.12, but the v0.12.12 tag build') -and $pause.Message.Contains("Run $resume in the foreground")) 'a stop after the merge says the pull request is merged, outside the command to run'
        $timeout = $null
        try { Wait-ReleaseBuild '0.12.12' ('f' * 40) $now.AddSeconds(-1) $now.AddSeconds(-1) $resume | Out-Null } catch { $timeout = $_.Exception }
        Check ($timeout -and $timeout -isnot [ShipPausedException]) 'a tag build past the overall timeout still fails'
        $script:fixtureRun.status = 'completed'; $script:fixtureRun.conclusion = 'success'
        Check ((Wait-ReleaseBuild '0.12.12' ('f' * 40) $now.AddMinutes(60) $now.AddSeconds(-1) $resume).id -eq 7) 'a finished tag build is used even when the wait limit has passed'
        Check ((Wait-ReleaseBuild '0.12.12' ('f' * 40) $now.AddSeconds(-1) $now.AddSeconds(-1) $resume).id -eq 7) 'a rerun that starts at its carried deadline still finds a finished tag build'
        $script:fixtureRun.conclusion = 'failure'
        $failed = $null
        try { Wait-ReleaseBuild '0.12.12' ('f' * 40) $now.AddMinutes(60) $now.AddSeconds(-1) $resume | Out-Null } catch { $failed = $_.Exception }
        Check ($failed -and $failed -isnot [ShipPausedException] -and $failed.Message -match 'Release build failed') 'a failed tag build fails rather than stopping to wait'
        $pause = $null
        try { Test-PublishedRelease '0.12.12' $testRoot $now.AddMinutes(60) $now.AddSeconds(-1) $resume | Out-Null } catch { $pause = $_.Exception }
        Check ($pause -is [ShipPausedException] -and $pause.Message.Contains('v0.12.11')) 'a release not yet public past the wait limit stops the run'
        $script:fixtureLatest = 'v0.0.1'
        $failed = $null
        try { Test-PublishedRelease '0.12.12' $testRoot $now.AddSeconds(-1) $now.AddSeconds(-1) $resume | Out-Null } catch { $failed = $_.Exception }
        Check ($failed -and $failed -isnot [ShipPausedException]) 'a release still not public at the carried deadline fails instead of waiting again'
    }
    finally { Set-Item -Path function:Get-PublicJson -Value $originalPublicJson }
    # Release checks on one computer take turns.
    $lockPath = Join-Path $testRoot 'release-checks.lock'
    $turn = Enter-ReleaseCheckTurn 'fixture run A' -Path $lockPath -TimeoutMinutes 0
    Check ((Get-ReleaseCheckHolder $lockPath) -like 'fixture run A, started *') 'a run that takes its turn names itself for the runs that wait'
    $waited = [Collections.Generic.List[string]]::new()
    $queued = $null
    try { Enter-ReleaseCheckTurn 'fixture run B' { param($holder) $waited.Add($holder) } -Path $lockPath -TimeoutMinutes 0 | Out-Null } catch { $queued = $_.Exception }
    Check ($queued -and $queued.Message.Contains('fixture run A') -and $waited.Count -eq 1 -and $waited[0].StartsWith('fixture run A')) 'a second run waits while another holds the turn, and names the run it waits for'
    Exit-ReleaseCheckTurn $turn
    Check (!(Test-Path -LiteralPath "$lockPath.json")) 'a run that ends its turn no longer claims it'
    $turn = Enter-ReleaseCheckTurn 'fixture run B' -Path $lockPath -TimeoutMinutes 0
    Exit-ReleaseCheckTurn $turn
    Check $true 'the next run takes the turn once the first ends it'
    # A run killed mid-checks cannot run its cleanup; the system still releases its turn.
    $ready = Join-Path $testRoot 'holder-ready'
    $holderScript = Join-Path $testRoot 'holder.ps1'
    Set-Content -LiteralPath $holderScript -Value ". '$((Join-Path $PSScriptRoot 'github-pr.ps1') -replace "'", "''")'; `$t = Enter-ReleaseCheckTurn 'fixture child' -Path '$($lockPath -replace "'", "''")' -TimeoutMinutes 0; Set-Content -LiteralPath '$($ready -replace "'", "''")' -Value held; Start-Sleep -Seconds 120"
    $hidden = if ($IsWindows) { @{ WindowStyle = 'Hidden' } } else { @{} } # -WindowStyle exists only on Windows
    $child = Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile', '-File', "`"$holderScript`"") -PassThru @hidden
    try {
        $until = [datetime]::UtcNow.AddSeconds(60)
        while (!(Test-Path -LiteralPath $ready) -and !$child.HasExited -and [datetime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 200 }
        $queued = $null
        try { Enter-ReleaseCheckTurn 'fixture run C' -Path $lockPath -TimeoutMinutes 0 | Out-Null } catch { $queued = $_.Exception }
        Check ($queued -and $queued.Message.Contains('fixture child')) 'another process holding the turn makes a run wait'
        $child.Kill($true); $child.WaitForExit()
        $turn = Enter-ReleaseCheckTurn 'fixture run C' -Path $lockPath -TimeoutMinutes 0.5 -PollSeconds 1
        Exit-ReleaseCheckTurn $turn
        Check $true 'a killed run gives up its turn'
    }
    finally { if (!$child.HasExited) { $child.Kill($true) } }
    Check ((Format-CheckProgress ([pscustomobject]@{ State = 'running'; WaitingFor = 'BlackPearl Mobile 1234abcd (fix), started 10:00' })) -ceq 'queued behind BlackPearl Mobile 1234abcd (fix), started 10:00') 'a run waiting for its turn shows as queued behind the run it waits for'
    Check ((Format-CheckProgress ([pscustomobject]@{ State = 'running' })) -ceq 'running' -and (Format-CheckProgress ([pscustomobject]@{ State = 'passed'; WaitingFor = 'x' })) -ceq 'passed') 'other runs show their state'
    . (Join-Path $PSScriptRoot 'ship-sync-checks.ps1') -TestRoot $testRoot
    Write-Host "$checks shipping safety checks passed. No releases were created."
}
finally {
    # This is the exact fresh directory created above, directly in the scratch folder.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ([IO.Path]::GetFullPath((Split-Path -Parent $resolved)).TrimEnd('\', '/') -ieq (Get-ScratchRoot).TrimEnd('\', '/') -and
        (Split-Path -Leaf $resolved) -match '^bpm-ship-checks-[a-f0-9]{32}$') {
        # A virus scanner can hold a fixture file for a moment.
        foreach ($attempt in 1..5) {
            if (Remove-Tree $resolved) { break }
            if ($attempt -eq 5) { Write-Warning "Could not remove $resolved." } else { Start-Sleep -Seconds 1 }
        }
    }
}
