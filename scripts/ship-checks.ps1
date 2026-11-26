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
        "param([string]`$Lane, [string]`$Flutter, [string]`$FailureFile)`n'Tests failed with exit code 1.' | Set-Content -LiteralPath `$FailureFile`nexit 1`n")
    $message = ''
    try { Invoke-ReleaseChecks $fakeCheckout 'flutter' } catch { $message = "$_" }
    Check ($message -ceq 'Tests failed with exit code 1.') "a failed release check is recorded by its own error ($message)"
    . (Join-Path $PSScriptRoot 'ship-sync-checks.ps1') -TestRoot $testRoot
    Write-Host "$checks shipping safety checks passed. No releases were created."
}
finally {
    # This is the exact fresh directory created above, beneath the system temp root.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    if ($resolved.StartsWith((Get-ScratchRoot), [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolved) -match '^bpm-ship-checks-[a-f0-9]{32}$') {
        # A virus scanner can hold a fixture file for a moment.
        foreach ($attempt in 1..5) {
            if (Remove-Tree $resolved) { break }
            if ($attempt -eq 5) { Write-Warning "Could not remove $resolved." } else { Start-Sleep -Seconds 1 }
        }
    }
}
