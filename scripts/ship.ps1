#Requires -Version 7.0
# Ships an app update through a reviewed pull request; see UPDATES.md.
#   ship.ps1 -Message ... -BodyFile ...   push the branch, open or update its pull request, and start the release checks
#   ship.ps1 -Status                      show the pull request's release checks, CI and review verdict
#   ship.ps1 -Merge                       merge the approved, checked pull request, tag it, and verify the release
#                                         (waits at most -WaitMinutes per run, then exits 3 and names the command to run next)
#   ship.ps1 -NoRelease [-Merge]          the same for a change the user does not want released: no version bump, tag, or release
#   ship.ps1 -VerifyOnly -Version x.y.z   finish verifying an already pushed tag
#   ship.ps1 -CheckCommit <sha>           run the release checks on a commit and record the result (started by ship.ps1)
[CmdletBinding()]
param(
    [string]$Message = '',
    [string]$BodyFile = '',
    [string]$Title = '',
    [string]$Version = '',
    [string]$Flutter = '',
    [int]$Pr = 0,
    [switch]$Plan,
    [switch]$Merge,
    [switch]$Status,
    [switch]$NoRelease,
    [switch]$VerifyOnly,
    [string]$CheckCommit = '',
    [string]$Branch = '',
    [string]$CheckLog = '',
    [ValidateRange(1, 120)][int]$TimeoutMinutes = 60,
    # How long -Merge and -VerifyOnly wait in one run before they stop and name the command that continues; 0 waits up
    # to -TimeoutMinutes. Agents run these in the foreground for this reason; see "Waiting in the foreground" in UPDATES.md.
    [ValidateRange(0, 120)][int]$WaitMinutes = 7
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'github-pr.ps1')

# Raised when -WaitMinutes runs out while the release is still on its way. It is not a failure: the message names the
# command that carries on, and the script exits with code 3.
class ShipPausedException : System.Exception {
    ShipPausedException([string]$Message) : base($Message) {}
}
function Get-ShipPauseAt {
    param([int]$Minutes, [datetime]$Now = [datetime]::UtcNow)
    if ($Minutes -le 0) { return [datetime]::MaxValue }
    return $Now.AddMinutes($Minutes)
}
function Suspend-ShipWhenDue {
    param([datetime]$PauseAt, [string]$Waiting, [string]$Resume)
    if ([datetime]::UtcNow -lt $PauseAt) { return }
    throw [ShipPausedException]::new("Not finished: $Waiting. Run $Resume in the foreground now to keep waiting. Do not end your turn or report the ship as done until it prints its final result.")
}
function Get-ShipVersion {
    param([string]$Requested, [string]$Latest, [string]$Source)
    foreach ($value in @($Latest, $Source)) {
        if ($value -notmatch '^\d+\.\d+\.\d+$') { throw "Invalid version: $value" }
    }
    $floor = if ([version]$Latest -gt [version]$Source) { [version]$Latest } else { [version]$Source }
    if (!$Requested) { $Requested = "$($floor.Major).$($floor.Minor).$($floor.Build + 1)" }
    if ($Requested -notmatch '^\d+\.\d+\.\d+$' -or [version]$Requested -le $floor) {
        throw "Version '$Requested' must have three numeric components and be higher than $floor."
    }
    return $Requested
}
# The version name and build number a pull request ships. The build number numbers the APKs' version codes, which
# Android requires to rise with every update, so it goes above master's.
function Get-PullRequestVersion {
    param([string]$Requested, [string]$Latest, $MasterVersion, $BranchVersion)
    # A branch already above every release keeps its version across review rounds.
    if (!$Requested -and [version]$BranchVersion.Name -gt [version]$Latest -and [version]$BranchVersion.Name -gt [version]$MasterVersion.Name) {
        $name = $BranchVersion.Name
    }
    else { $name = Get-ShipVersion $Requested $Latest $MasterVersion.Name }
    $build = if ($BranchVersion.Build -gt $MasterVersion.Build) { $BranchVersion.Build } else { $MasterVersion.Build + 1 }
    return [pscustomobject]@{ Name = $name; Build = $build }
}
function Set-PubspecVersion {
    param([string]$Pubspec, $Version)
    $null = ConvertFrom-PubspecVersion $Pubspec # exactly one version line
    return [regex]::Replace($Pubspec, '(?m)^version:[ \t]*\d+\.\d+\.\d+\+\d+', "version: $($Version.Name)+$($Version.Build)")
}
function Assert-ShipPathName {
    param([string]$Path)
    $relative = $Path.Replace('\', '/')
    # Pictures belong to the app only where it keeps them: launcher icons, bundled assets, the Windows icon and the icon
    # sources. Anywhere else they are screenshots or local reports.
    $appImage = $relative -match '^(android/app/src/main/res/|assets/|windows/runner/resources/|tool/icon/)'
    if ($relative -match '^\.\.(?:/|$)' -or [IO.Path]::IsPathRooted($relative) -or
        $relative -match '(^|/)(build|\.dart_tool|\.gradle|\.cxx|\.idea|\.state|node_modules|artifacts|\.tools|logs|credentials)(/|$)' -or
        $relative -match '(?i)(^|/)(\.env[^/]*|key\.properties|local\.properties|google-services\.json|.*\.(jks|keystore|p12|pfx|pem|key|apk|aab|html?|mp4|mkv|webm|sqlite|db|log))$' -or
        ($relative -match '(?i)\.(png|jpe?g|webp|gif)$' -and !$appImage) -or
        $relative -notmatch '^(lib/|test/|android/|windows/|packages/|tool/|assets/|scripts/|\.github/workflows/|\.claude/skills/|[^/]+\.md$|pubspec\.(yaml|lock)$|analysis_options\.yaml$|\.metadata$|\.gitattributes$)') {
        throw "Not a release source path: $Path"
    }
    return $relative
}
function Invoke-ReleaseChecks {
    param([string]$Checkout, [string]$FlutterPath)
    Push-Location $Checkout
    $failure = Join-Path (Get-ScratchRoot) ('bpm-check-failure-' + [guid]::NewGuid().ToString('N') + '.txt')
    # The plugin's native build otherwise goes to a folder per checkout path outside the checkout (about 1 GB;
    # packages/blackpearl_datachannel/android/build.gradle), which a throwaway copy would leave behind. A short path
    # keeps the native build within Windows' 260 characters. It is named after the copy, so Remove-CheckCopy removes it
    # too when this process is killed before its finally runs.
    $staging = Get-NativeStagingPath $Checkout
    $savedStaging = $env:BLACKPEARL_NATIVE_STAGING
    $env:BLACKPEARL_NATIVE_STAGING = $staging
    try {
        # The same list of checks the workflow runs, from the checked commit itself.
        $shell = (Get-Process -Id $PID).Path
        try { Invoke-Native $shell @('-NoProfile', '-File', (Join-Path $Checkout 'scripts/release-checks.ps1'), '-Lane', 'all', '-Flutter', $FlutterPath, '-FailureFile', $failure) }
        catch {
            # Name the failing check rather than the script that ran it.
            if (Test-Path -LiteralPath $failure) { throw (Get-Content -LiteralPath $failure -Raw).Trim() }
            throw
        }
        # Checks must not change tracked files; a lock file that pub get rewrites means pubspec.lock is out of date.
        Invoke-Native git @('diff', '--exit-code')
    }
    finally {
        # Best effort: a cleanup error must not replace the failing check's.
        $null = Remove-Tree $failure
        $env:BLACKPEARL_NATIVE_STAGING = $savedStaging
        if (!(Remove-Tree $staging)) { Write-Warning "Could not remove the native build at $staging." }
        Pop-Location
    }
}
# Where ship.ps1 keeps verification records and local sync backups: the repository's shared git directory, which
# outlives agent worktrees and is never committed.
function Get-ShipRecordRoot {
    param([string]$Root)
    $common = (Invoke-Native git @('-C', $Root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).Trim()
    return Join-Path $common 'blackpearl-ship'
}
# Whether a path is a folder this script makes: bpm-ship-<id> or bpm-dc-<id> directly in the scratch folder.
function Test-ScratchFolder {
    param([string]$Path, [string]$Prefix)
    $full = [IO.Path]::GetFullPath($Path)
    return (Split-Path -Leaf $full) -match "^$Prefix-[a-f0-9]{12}$" -and
        [IO.Path]::GetFullPath((Split-Path -Parent $full)).TrimEnd('\', '/') -ieq (Get-ScratchRoot).TrimEnd('\', '/')
}
# The native build folder of a check copy bpm-ship-<id>: bpm-dc-<id> beside it. Any other checkout gets a new one.
function Get-NativeStagingPath {
    param([string]$Checkout)
    $id = if ((Split-Path -Leaf $Checkout) -match '^bpm-ship-([a-f0-9]{12})$') { $Matches[1] } else { [guid]::NewGuid().ToString('N').Substring(0, 12) }
    return Join-Path (Get-ScratchRoot) "bpm-dc-$id"
}
# Removes a copy of a commit made for release checks, and its native build. Git deletes what it can and forgets the
# worktree even when a file is still in use; the rest goes once nothing holds it. Returns whether both are gone.
function Remove-CheckCopy {
    param([string]$Root, [string]$Path)
    if (Test-Path -LiteralPath $Path) { & git -C $Root worktree remove --force $Path 2>$null }
    if ((Test-Path -LiteralPath $Path) -and (Test-ScratchFolder $Path 'bpm-ship')) { $null = Remove-Tree $Path }
    & git -C $Root worktree prune 2>$null
    $staging = $null
    if (Test-ScratchFolder $Path 'bpm-ship') {
        $staging = Get-NativeStagingPath $Path
        if (Test-ScratchFolder $staging 'bpm-dc') { $null = Remove-Tree $staging } else { $staging = $null }
    }
    return !(Test-Path -LiteralPath $Path) -and !($staging -and (Test-Path -LiteralPath $staging))
}
# A run that was interrupted or failed keeps its copy of the commit for investigation until the commit is checked again
# or a newer commit of the branch replaces it. The record names the copy until it is gone.
function Remove-StaleCheckCopy {
    param([string]$Root, [string]$RecordPath)
    $state = Get-CheckState $RecordPath
    if ($state.State -in 'missing', 'running' -or !$state.PSObject.Properties['Checkout'] -or !$state.Checkout) { return }
    if (!(Remove-CheckCopy $Root $state.Checkout)) { return }
    $record = @{}; $state.PSObject.Properties | ForEach-Object { $record[$_.Name] = $_.Value }
    $record.Remove('Checkout')
    Write-CheckRecord $RecordPath $record
}
# Runs the release checks on a clean copy of the commit and records running, then passed or failed, for -Merge and
# reviewers. It runs in its own process (ship.ps1 -CheckCommit), whose id the record keeps: in the background after a
# push, or in the foreground when -Merge finds the background run interrupted.
function Invoke-CheckRun {
    param([string]$Root, [string]$Commit, [string]$FlutterPath, [string]$Branch = '', [string]$Log = '')
    $recordPath = Get-CheckRecordPath $Root $Commit
    Remove-StaleCheckCopy $Root $recordPath
    # A clean copy, so untracked files in the worktree cannot affect the result. The name is short because the native
    # build's paths must stay under 260 characters on Windows (packages/blackpearl_datachannel/src/CMakeLists.txt).
    $checkout = Join-Path (Get-ScratchRoot) ('bpm-ship-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $record = @{
        Commit = $Commit; Branch = $Branch; State = 'running'; Started = [datetime]::UtcNow.ToString('o'); Log = $Log; Checkout = $checkout
        Pid = $PID; ProcessStart = (Get-Process -Id $PID).StartTime.ToUniversalTime().Ticks
    }
    Write-CheckRecord $recordPath $record
    try {
        Invoke-Native git @('-C', $Root, 'worktree', 'add', '--detach', $checkout, $Commit)
        Invoke-ReleaseChecks $checkout $FlutterPath
        $record.State = 'passed'; $record.Checked = [datetime]::UtcNow.ToString('o')
        # A copy still held open stays named in the record, which the next check of the branch removes it by.
        if (Remove-CheckCopy $Root $checkout) { $record.Remove('Checkout') }
        Write-CheckRecord $recordPath $record
        Write-Host "Release checks passed on $Commit."
    }
    catch {
        $record.State = 'failed'; $record.Error = "$_"; $record.Checked = [datetime]::UtcNow.ToString('o')
        if (!(Test-Path -LiteralPath $checkout)) { $record.Remove('Checkout') }
        Write-CheckRecord $recordPath $record
        throw
    }
}
# A newer push of the same branch makes checks of its older commits pointless; stop them so they do not slow the new run.
function Stop-SupersededChecks {
    param([string]$Root, [string]$Branch, [string]$Commit)
    $directory = Split-Path -Parent (Get-CheckRecordPath $Root $Commit)
    if (!(Test-Path -LiteralPath $directory)) { return }
    foreach ($file in Get-ChildItem -LiteralPath $directory -Filter '*.json') {
        $state = Get-CheckState $file.FullName
        if ($state.Branch -cne $Branch -or $state.Commit -ceq $Commit) { continue }
        if ($state.State -ne 'running') {
            # The newer commit replaces this one, so it will not be checked again: drop the copy an interrupted or
            # failed run left behind.
            Remove-StaleCheckCopy $Root $file.FullName
            continue
        }
        try { [Diagnostics.Process]::GetProcessById([int]$state.Pid).Kill($true) } catch { }
        $null = Get-Process -Id $state.Pid -ErrorAction SilentlyContinue | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
        $record = @{}; $state.PSObject.Properties | ForEach-Object { $record[$_.Name] = $_.Value }
        $record.State = 'superseded'
        if ($state.Checkout -and (Remove-CheckCopy $Root $state.Checkout)) { $record.Remove('Checkout') }
        Write-CheckRecord $file.FullName $record
        Write-Host "Stopped the release checks of $($state.Commit), which $Commit replaces."
    }
}
function Start-BackgroundChecks {
    param([string]$Root, [string]$Commit, [string]$FlutterPath, [string]$Branch)
    $recordPath = Get-CheckRecordPath $Root $Commit
    $log = [IO.Path]::ChangeExtension($recordPath, '.log')
    New-Item -ItemType Directory -Path (Split-Path -Parent $recordPath) -Force | Out-Null
    Remove-StaleCheckCopy $Root $recordPath
    Remove-Item -LiteralPath $recordPath -Force -ErrorAction SilentlyContinue
    $shell = (Get-Process -Id $PID).Path
    # The branch's copy of this script runs the checks, in a process that outlives this one, with its output and
    # errors in one log, in the order they happen.
    $script = Join-Path $Root 'scripts/ship.ps1'
    $arguments = "-NoProfile -File `"$script`" -CheckCommit $Commit -Branch `"$Branch`" -Flutter `"$FlutterPath`" -CheckLog `"$log`""
    if ($IsWindows) {
        $process = Start-Process -FilePath $env:ComSpec -ArgumentList @('/d', '/s', '/c', "`"`"$shell`" $arguments > `"$log`" 2>&1`"") -WindowStyle Hidden -PassThru -WorkingDirectory $Root
    }
    else {
        $process = Start-Process -FilePath '/bin/sh' -ArgumentList @('-c', "nohup `"$shell`" $arguments > `"$log`" 2>&1") -PassThru -WorkingDirectory $Root
    }
    $deadline = [datetime]::UtcNow.AddSeconds(60)
    while ((Get-CheckState $recordPath).State -eq 'missing') {
        if ($process.HasExited -or [datetime]::UtcNow -ge $deadline) {
            $output = (Get-Content -LiteralPath $log -Tail 20 -ErrorAction SilentlyContinue) -join "`n"
            throw "The background release checks did not start. $output"
        }
        Start-Sleep -Milliseconds 500
    }
    return $log
}
function Get-SyncTree {
    param([string]$Root, [string]$Base, [string]$Master, [string]$Local)
    $merge = @(Invoke-Native git @('-C', $Root, 'merge-tree', '--write-tree', '--no-messages', "--merge-base=$Base", $Master, $Local))
    if (!$merge.Count -or $merge[0] -notmatch '^[a-f0-9]{40,64}$') { throw 'Git did not return a merged tree for local work.' }
    return $merge[0]
}
function Assert-SyncUntracked {
    param([string]$Root, [string]$Head, [string]$Backup, [string[]]$Paths, [string[]]$Selected)
    foreach ($path in $Paths) {
        & git -C $Root cat-file -e "${Head}:$path" 2>$null
        if ($LASTEXITCODE -eq 0 -and $Selected -notcontains $path) {
            $saved = Join-Path (Join-Path $Backup 'untracked') $path
            $savedHash = (Invoke-Native git @('-C', $Root, 'hash-object', "--path=$path", '--', $saved)).Trim()
            $remoteHash = (Invoke-Native git @('-C', $Root, 'rev-parse', "${Head}:$path")).Trim()
            if ($savedHash -cne $remoteHash) { throw "Untracked file conflicts with master: $path" }
        }
    }
}
function Sync-ShippedMaster {
    param([string]$Root, [string]$PublishedCommit, [string]$Destination, [string[]]$Selected = @())
    Invoke-Native git @('-C', $Root, 'fetch', '--no-recurse-submodules', 'origin', 'master') | Out-Null
    $remoteHead = (Invoke-Native git @('-C', $Root, 'rev-parse', 'origin/master')).Trim()
    Invoke-Native git @('-C', $Root, 'merge-base', '--is-ancestor', $PublishedCommit, $remoteHead) | Out-Null
    # A ship command can run in a detached/feature checkout. Update the checkout
    # that actually owns master, without switching or rewriting another branch.
    $masterRoot = $null; $candidate = $null
    foreach ($line in @(Invoke-Native git @('-C', $Root, 'worktree', 'list', '--porcelain'))) {
        if ($line.StartsWith('worktree ')) { $candidate = $line.Substring(9) }
        elseif ($line -ceq 'branch refs/heads/master') { $masterRoot = $candidate }
    }
    if (!$masterRoot) {
        & git -C $Root show-ref --verify --quiet refs/heads/master
        if ($LASTEXITCODE -eq 0) {
            Invoke-Native git @('-C', $Root, 'merge-base', '--is-ancestor', 'master', $remoteHead) | Out-Null
        }
        elseif ($LASTEXITCODE -ne 1) { throw 'Could not inspect local master.' }
        Invoke-Native git @('-C', $Root, 'fetch', '--no-recurse-submodules', 'origin', 'master:master') | Out-Null
        $syncedHead = (Invoke-Native git @('-C', $Root, 'rev-parse', 'master')).Trim()
        Invoke-Native git @('-C', $Root, 'merge-base', '--is-ancestor', $PublishedCommit, $syncedHead) | Out-Null
        return @{ Commit = $syncedHead; Checkout = $null; RecoveryStash = $null }
    }
    $masterRoot = [IO.Path]::GetFullPath($masterRoot)
    $base = (Invoke-Native git @('-C', $masterRoot, 'rev-parse', 'HEAD')).Trim()
    Invoke-Native git @('-C', $masterRoot, 'merge-base', '--is-ancestor', $base, $remoteHead) | Out-Null
    $dirty = @(Invoke-Native git @('-C', $masterRoot, 'status', '--porcelain', '--ignore-submodules=all'))
    $staged = @(Invoke-Native git @('-C', $masterRoot, 'diff', '--cached', '--name-only', '--ignore-submodules=none'))
    $stash = $null; $restored = $false
    $untracked = @(); $backup = Join-Path $Destination 'local-master-sync'
    try {
        if ($dirty.Count -or $staged.Count) {
            New-Item -ItemType Directory -Path $backup -Force | Out-Null
            # Save raw untracked bytes as well as Git's recovery snapshot. This
            # also handles new release files that already exist after the pull.
            $names = (Invoke-Native git @('-C', $masterRoot, 'ls-files', '--others', '--exclude-standard', '-z')) -join "`n"
            $untracked = @($names.Split([char]0, [StringSplitOptions]::RemoveEmptyEntries))
            foreach ($path in $untracked) {
                $source = [IO.Path]::GetFullPath($path, $masterRoot)
                if (!$source.StartsWith($masterRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Untracked path is outside the master checkout.' }
                $item = Get-Item -LiteralPath $source
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Cannot safely snapshot untracked link: $path" }
                $saved = Join-Path (Join-Path $backup 'untracked') $path
                New-Item -ItemType Directory -Path (Split-Path -Parent $saved) -Force | Out-Null
                Copy-Item -LiteralPath $source -Destination $saved
            }
            # The stash list is shared with every worktree and other sessions may push to it at the same moment, so the
            # entry is found by its own unique message rather than taken as stash@{0}.
            $stashMessage = "Before syncing verified release $PublishedCommit ($([guid]::NewGuid().ToString('N')))"
            Invoke-Native git @('-C', $masterRoot, 'stash', 'push', '--include-untracked', '-m', $stashMessage) | Out-Null
            $entry = @(Invoke-Native git @('-C', $masterRoot, 'stash', 'list', '--format=%H %gs')) | Where-Object { $_.EndsWith(": $stashMessage") } | Select-Object -First 1
            if (!$entry) { throw 'Could not find the recovery stash just made.' }
            $stash = $entry.Split(' ')[0]
            $stash | Set-Content -LiteralPath (Join-Path $backup 'recovery-stash.txt')
            # Merge worktree and index independently: unrelated staged edits stay
            # staged, and already-shipped edits disappear instead of reappearing.
            $workTree = Get-SyncTree $masterRoot $base $remoteHead $stash
            $indexTree = Get-SyncTree $masterRoot $base $remoteHead "$stash^2"
            Assert-SyncUntracked $masterRoot $remoteHead $backup $untracked $Selected
        }
        Invoke-Native git @('-C', $masterRoot, 'pull', '--ff-only', '--no-recurse-submodules', 'origin', 'master') | Out-Null
        $syncedHead = (Invoke-Native git @('-C', $masterRoot, 'rev-parse', 'HEAD')).Trim()
        if ($stash) {
            # Account for master advancing again between preflight and the pull.
            if ($syncedHead -cne $remoteHead) {
                $workTree = Get-SyncTree $masterRoot $base $syncedHead $stash
                $indexTree = Get-SyncTree $masterRoot $base $syncedHead "$stash^2"
                Assert-SyncUntracked $masterRoot $syncedHead $backup $untracked $Selected
            }
            Invoke-Native git @('-C', $masterRoot, 'restore', "--source=$workTree", '--staged', '--worktree', '--', '.') | Out-Null
            Invoke-Native git @('-C', $masterRoot, 'read-tree', $indexTree) | Out-Null
            foreach ($path in $untracked) {
                $saved = Join-Path (Join-Path $backup 'untracked') $path
                $target = Join-Path $masterRoot $path
                # For selected new source files, retain any edits made while the
                # release was building as a worktree diff against the new master.
                if (!(Test-Path -LiteralPath $target) -or $Selected -contains $path) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
                    Copy-Item -LiteralPath $saved -Destination $target
                }
            }
            $restored = $true
        }
        Invoke-Native git @('-C', $masterRoot, 'merge-base', '--is-ancestor', $PublishedCommit, 'HEAD') | Out-Null
        return @{ Commit = $syncedHead; Checkout = $masterRoot; RecoveryStash = $stash }
    }
    catch {
        $failure = $_
        # Preflight/network failures before advancing master can restore the exact
        # original index and worktree. Keep the stash even after a successful sync.
        $restoreFailure = ''
        if ($stash -and !$restored -and (Invoke-Native git @('-C', $masterRoot, 'rev-parse', 'HEAD')).Trim() -ceq $base) {
            try { Invoke-Native git @('-C', $masterRoot, 'stash', 'apply', '--index', $stash) | Out-Null }
            catch { $restoreFailure = " Automatic restoration also failed: $_" }
        }
        $recovery = if ($stash) { " Local work is saved in stash $stash and $backup." } else { '' }
        throw "Local master synchronization failed: $failure$recovery$restoreFailure"
    }
}
# The APKs the release workflow attaches, as the app's updater looks for them (lib/update/app_update.dart): the 64-bit
# ARM one under the plain name, the 32-bit one named for its ABI.
function Get-ReleaseApkNames {
    param([string]$ExpectedVersion)
    return @("BlackPearl-v$ExpectedVersion.apk", "BlackPearl-v$ExpectedVersion-armeabi-v7a.apk")
}
function Assert-ReleaseMetadata {
    param($Release, [string]$ExpectedVersion)
    if ($Release.tag_name -cne "v$ExpectedVersion" -or $Release.draft -or $Release.prerelease) {
        throw "The public updater feed does not expose stable v$ExpectedVersion."
    }
    $apks = @()
    foreach ($name in Get-ReleaseApkNames $ExpectedVersion) {
        $asset = @($Release.assets | Where-Object name -CEQ $name)
        if ($asset.Count -ne 1 -or $asset[0].size -le 0 -or $asset[0].digest -cnotmatch '^sha256:[a-f0-9]{64}$' -or
            ($asset[0].PSObject.Properties['state'] -and $asset[0].state -and $asset[0].state -cne 'uploaded')) {
            throw "Missing $name, or its size, SHA-256 digest, or upload."
        }
        if ($asset[0].browser_download_url -cne "https://github.com/$repository/releases/download/v$ExpectedVersion/$name") { throw "Unexpected URL for $name." }
        $apks += $asset[0]
    }
    return $apks
}
function Assert-ApkBytes {
    param([string]$Path, $Asset)
    $hash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ((Get-Item -LiteralPath $Path).Length -ne $Asset.size -or "sha256:$hash" -cne $Asset.digest) {
        throw "$($Asset.name): size or GitHub SHA-256 digest mismatch."
    }
    return $hash
}
function Wait-ReleaseBuild {
    param([string]$ExpectedVersion, [string]$Commit, [datetime]$Deadline, [datetime]$PauseAt = [datetime]::MaxValue, [string]$Resume = '')
    $run = $null
    $lastStatus = ''
    while ([datetime]::UtcNow -lt $Deadline) {
        if (!$run) {
            $runs = Get-PublicJson "$apiRoot/actions/runs?head_sha=$Commit&event=push&per_page=100"
            $run = $runs.workflow_runs | Where-Object {
                $_.head_branch -ceq "v$ExpectedVersion" -and $_.head_sha -ceq $Commit -and $_.name -ceq $buildWorkflow
            } | Sort-Object run_attempt -Descending | Select-Object -First 1
        }
        else { $run = Get-PublicJson "$apiRoot/actions/runs/$($run.id)" }
        $status = if ($run) { "$($run.status) $($run.conclusion)" } else { 'Waiting for tag workflow' }
        if ($status -ne $lastStatus) { Write-Host $status; $lastStatus = $status }
        if ($run.status -eq 'completed') {
            if ($run.conclusion -ne 'success') { throw "Release build failed: $($run.html_url). Fix it before shipping a higher version; do not move the tag." }
            return $run
        }
        Suspend-ShipWhenDue $PauseAt "the v$ExpectedVersion tag build is still running ($status)" $Resume
        Start-Sleep -Seconds 20
    }
    throw "Timed out waiting for the tag build. Recheck with -VerifyOnly -Version $ExpectedVersion."
}
function Test-PublishedRelease {
    param([string]$ExpectedVersion, [string]$Destination, [datetime]$Deadline, [datetime]$PauseAt = [datetime]::MaxValue, [string]$Resume = '')
    $release = $null
    do {
        $release = Get-PublicJson "$apiRoot/releases/latest"
        if ($release.tag_name -ceq "v$ExpectedVersion") { break }
        if ([datetime]::UtcNow -ge $Deadline) { throw "Public latest release is $($release.tag_name), expected v$ExpectedVersion." }
        Suspend-ShipWhenDue $PauseAt "the public latest release is still $($release.tag_name), not v$ExpectedVersion" $Resume
        Start-Sleep -Seconds 15
    } while ($true)
    $apks = Assert-ReleaseMetadata $release $ExpectedVersion
    $verified = @()
    foreach ($apk in $apks) {
        $path = Join-Path $Destination $apk.name
        Write-Host "Downloading $($apk.name) for verification…"
        Invoke-WebRequest -Uri $apk.browser_download_url -OutFile $path -TimeoutSec 600 -MaximumRetryCount 4 -RetryIntervalSec 5
        $verified += "$($apk.name) ($([Math]::Round($apk.size / 1MB, 1)) MB, sha256 $(Assert-ApkBytes $path $apk))"
    }
    $url = "https://github.com/$repository/releases/tag/v$ExpectedVersion"
    $page = Invoke-WebRequest -Uri $url -TimeoutSec 60
    if ($page.StatusCode -ne 200) { throw 'Public release page is unavailable.' }
    $links = Invoke-WebRequest -Uri "https://github.com/$repository/releases/expanded_assets/v$ExpectedVersion" -TimeoutSec 60
    foreach ($apk in $apks) {
        if (!$links.Content.Contains("/releases/download/v$ExpectedVersion/$($apk.name)")) { throw 'Public release page is missing APK links.' }
    }
    return @{ Version = $ExpectedVersion; Release = $url; Apks = $verified }
}


# Dot-sourcing exposes helpers for offline safety checks without starting a release.
if ($MyInvocation.InvocationName -eq '.') { return }
$root = Split-Path -Parent $PSScriptRoot
$paused = $null
Push-Location $root
try {
    if ($CheckCommit) {
        if ($CheckCommit -notmatch '^[a-f0-9]{40}$') { throw '-CheckCommit takes a full commit hash.' }
        Invoke-CheckRun $root $CheckCommit (Resolve-Flutter $Flutter) $Branch $CheckLog
        return
    }
    $remote = Invoke-Native git @('remote', 'get-url', 'origin')
    if ($remote.Trim() -notmatch '^(https://github\.com/|git@github\.com:)Svovoniks/BlackPearlMobile(?:\.git)?$') { throw "origin must be the public $repository repository." }
    Invoke-Native git @('fetch', '--no-recurse-submodules', 'origin', '--tags')
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $pauseAt = Get-ShipPauseAt $WaitMinutes
    if ($VerifyOnly) {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw '-VerifyOnly requires -Version major.minor.patch.' }
        $commit = (Invoke-Native git @('rev-parse', "v$Version^{commit}")).Trim()
    }
    elseif ($Status) {
        if ($Pr) { $pull = Invoke-GitHub "/pulls/$Pr" }
        else {
            $branch = (Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
            $pull = Find-BranchPullRequest $branch
            if (!$pull) { throw "No open pull request for branch $branch. Pass -Pr." }
        }
        $head = $pull.head.sha
        $local = Get-CheckState (Get-CheckRecordPath $root $head)
        $ci = Get-HeadCheckState (Invoke-GitHub "/actions/runs?head_sha=$head&per_page=100").workflow_runs $head
        $verdict = Get-ReviewVerdict (Get-PullRequestComments $pull.number)
        Write-Host "#$($pull.number) $($pull.title)"
        Write-Host "Head: $head"
        Write-Host "Release checks: $($local.State)$(if ($local.State -eq 'running') { " since $(([datetimeoffset]$local.Started).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss zzz'))" })"
        if ($local.State -eq 'failed') {
            Write-Host "  $($local.Error)"
            Write-Host "  $(Format-CheckEvidence $local)"
            if ($local.Log -and (Test-Path -LiteralPath $local.Log)) { Get-Content -LiteralPath $local.Log -Tail 30 | ForEach-Object { Write-Host "  $_" } }
        }
        elseif ($local.State -in 'missing', 'interrupted', 'superseded') { Write-Host '  -Merge starts them in the background, or rerun ship.ps1 to start them.' }
        Write-Host "Workflow: $($ci.State) - $($ci.Detail)"
        Write-Host "Review: $(if (!$verdict) { 'none yet' } elseif ($verdict.Head -cne $head) { "covers an older head $($verdict.Head)" } else { "$($verdict.Verdict) ($($verdict.Url))" })"
        return
    }
    elseif ($Merge) {
        if ($Pr) { $pull = Invoke-GitHub "/pulls/$Pr" }
        else {
            $branch = (Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
            $pull = Find-BranchPullRequest $branch
            if (!$pull) { throw "No open pull request for branch $branch. Pass -Pr." }
        }
        if ($pull.state -ne 'open' -or $pull.draft -or $pull.base.ref -cne 'master' -or $pull.head.repo.full_name -cne $repository) {
            throw "Only an open, non-draft pull request from $repository into master can be shipped."
        }
        $number = $pull.number; $head = $pull.head.sha
        Invoke-Native git @('fetch', '--no-recurse-submodules', 'origin', "pull/$number/head")
        if ((Invoke-Native git @('rev-parse', 'FETCH_HEAD')).Trim() -cne $head) { throw 'The pull request head changed while it was being read. Rerun -Merge.' }
        $localRecord = Get-CheckRecordPath $root $head
        $checkFailureAdvice = 'Fix the failure, rerun ship.ps1, and request a re-review. If it is unrelated to this change, rerun ship.ps1 on the same head instead; the approval still covers it.'
        $local = Get-CheckState $localRecord
        if ($local.State -eq 'failed') { throw "Release checks failed on ${head}: $($local.Error) $(Format-CheckEvidence $local)$checkFailureAdvice" }
        Write-Host "Release checks on ${head}: $($local.State)"
        & git merge-base --is-ancestor origin/master $head
        if ($LASTEXITCODE -ne 0) { throw 'master advanced since this pull request was checked. Merge origin/master into the branch, rerun ship.ps1, and request a re-review.' }
        $approval = Assert-ReviewApproval (Get-PullRequestComments $number) $head
        $headVersion = Get-PubspecVersion $root $head
        $masterVersion = Get-PubspecVersion $root 'origin/master'
        if ($NoRelease) {
            # An unreleased merge must not leave master claiming a version that was never published.
            if ($headVersion.Name -cne $masterVersion.Name -or $headVersion.Build -ne $masterVersion.Build) { throw "The pull request sets version $($headVersion.Name)+$($headVersion.Build). Merge it without -NoRelease, or drop the version change." }
            $mergeTitle = "$($pull.title) (#$number)"
            Write-Host "Merge #$number ($head) without a release, approved in $($approval.Url)"
        }
        else {
            $Version = $headVersion.Name
            $latest = (Get-PublicJson "$apiRoot/releases/latest").tag_name -replace '^v', ''
            if ([version]$Version -le [version]$latest) { throw "The pull request ships $Version, but $latest is already published. Rerun ship.ps1 to raise the version, then request a re-review." }
            if ($headVersion.Build -le $masterVersion.Build) { throw "The pull request's build number $($headVersion.Build) is not above master's $($masterVersion.Build), so phones would refuse the update. Rerun ship.ps1, then request a re-review." }
            & git show-ref --verify --quiet "refs/tags/v$Version"
            if ($LASTEXITCODE -eq 0) { throw "Tag v$Version already exists. Rerun ship.ps1 with a higher -Version, then request a re-review." }
            $note = Get-ReleaseNote $pull.body
            if (!$note) { $note = $pull.title }
            $mergeTitle = "Release ${Version}: $note (#$number)"
            Write-Host "Merge #$number ($head) as BlackPearl Mobile $Version+$($headVersion.Build), approved in $($approval.Url)"
        }
        if ($Plan) { Write-Host 'Preview complete. Nothing was merged, tagged, or released.'; return }
        $mergeResume = "./scripts/ship.ps1 -Merge$(if ($NoRelease) { ' -NoRelease' })$(if ($Pr) { " -Pr $Pr" })$(if ($Flutter) { " -Flutter '$Flutter'" })"
        # Wait for both the workflow and the local release checks on the head. Local checks that never finished, for
        # example because the computer restarted, start again here: in the background when this run has a wait limit, so
        # it can stop and be rerun while they run, otherwise in this run.
        $checks = $null; $localPassed = $false; $lastState = ''; $lastLocal = ''
        while ($true) {
            $local = Get-CheckState $localRecord
            if ($local.State -ne $lastLocal) { Write-Host "Release checks: $($local.State)"; $lastLocal = $local.State }
            if ($local.State -eq 'passed') { $localPassed = $true }
            elseif ($local.State -eq 'failed') { throw "Release checks failed on ${head}: $($local.Error) $(Format-CheckEvidence $local)$checkFailureAdvice" }
            elseif ($local.State -ne 'running' -and $pauseAt -ne [datetime]::MaxValue) {
                Write-Host "Release checks on $head started in the background, log $(Start-BackgroundChecks $root $head (Resolve-Flutter $Flutter) $pull.head.ref)"
                $lastLocal = ''
                continue
            }
            elseif ($local.State -ne 'running') {
                Write-Host "Running the release checks on $head here..."
                # In a process of its own, so stopping it or a newer push of the branch cannot leave the record running.
                & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $root 'scripts/ship.ps1') -CheckCommit $head -Branch $pull.head.ref -Flutter (Resolve-Flutter $Flutter)
                $local = Get-CheckState $localRecord
                if ($local.State -eq 'failed') { throw "Release checks failed on ${head}: $($local.Error) $(Format-CheckEvidence $local)$checkFailureAdvice" }
                if ($local.State -ne 'passed') { throw "Release checks on $head ended without a result ($($local.State)). Rerun -Merge to run them again." }
                $localPassed = $true
            }
            if (!$checks) {
                $state = Get-HeadCheckState (Invoke-GitHub "/actions/runs?head_sha=$head&per_page=100").workflow_runs $head
                if ($state.Detail -ne $lastState) { Write-Host "Pull request checks: $($state.Detail)"; $lastState = $state.Detail }
                if ($state.State -eq 'failure') { throw "$($state.Detail). Fix the failure, or rerun the failed jobs only if the failure is unrelated to this change, then rerun -Merge." }
                if ($state.State -eq 'success') { $checks = $state }
            }
            if ($checks -and $localPassed) { break }
            if ([datetime]::UtcNow -ge $deadline) { throw 'Timed out waiting for the pull request and release checks. Rerun -Merge.' }
            $waiting = @($(if (!$localPassed) { "release checks $($local.State)" }), $(if (!$checks) { "pull request checks $lastState" })) -join ', '
            Suspend-ShipWhenDue $pauseAt "#$number is not merged yet, waiting for $waiting" $mergeResume
            Start-Sleep -Seconds 20
        }
        # Merge only the exact reviewed head, and only while it still contains master.
        Invoke-Native git @('fetch', '--no-recurse-submodules', 'origin', 'master')
        & git merge-base --is-ancestor origin/master $head
        if ($LASTEXITCODE -ne 0) { throw 'master advanced while waiting for checks. Merge origin/master into the branch, rerun ship.ps1, and request a re-review.' }
        # The reviewer may have withdrawn approval while CI ran.
        $approval = Assert-ReviewApproval (Get-PullRequestComments $number) $head
        $merged = Invoke-GitHub "/pulls/$number/merge" -Method Put -Body @{
            merge_method = 'squash'; sha = $head
            commit_title = $mergeTitle
            commit_message = "Reviewed and merged in #$number."
        }
        $commit = $merged.sha
        try {
            Invoke-Native git @('fetch', '--no-recurse-submodules', 'origin', 'master')
            Invoke-Native git @('merge-base', '--is-ancestor', $commit, 'origin/master') | Out-Null
            if ((Invoke-Native git @('rev-parse', "$commit^{tree}")).Trim() -cne (Invoke-Native git @('rev-parse', "$head^{tree}")).Trim()) {
                throw "The merged tree differs from the reviewed head $head, so it was not tagged."
            }
            if (!$NoRelease) {
                Invoke-Native git @('tag', '-a', "v$Version", $commit, '-m', "BlackPearl Mobile ${Version}: $note")
                Invoke-Native git @('push', 'origin', "v$Version")
            }
        }
        catch {
            # Rerunning -Merge cannot help once the pull request is merged.
            $recover = if ($NoRelease) { 'Inspect master.' } else { "If v$Version is not on GitHub and $commit has the reviewed head's tree, tag $commit as v$Version, push the tag, and run -VerifyOnly -Version $Version. Otherwise ship a higher version once master is correct." }
            throw "Pull request #$number is merged as $commit, but finishing failed: $_ $recover"
        }
        try { Invoke-GitHub "/git/refs/heads/$($pull.head.ref)" -Method Delete | Out-Null }
        catch { Write-Warning "Could not delete merged branch $($pull.head.ref): $($_.Exception.Message)" }
        # No later push of the branch will remove a copy its passed checks had to keep.
        try { Remove-StaleCheckCopy $root $localRecord }
        catch { Write-Warning "Could not remove the checked copy of ${head}: $($_.Exception.Message)" }
        if ($NoRelease) {
            $record = Join-Path (Get-ShipRecordRoot $root) ('merge-' + $number + '-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $record -Force | Out-Null
            try { $synced = Sync-ShippedMaster $root $commit $record }
            catch { throw "Pull request #$number is merged as $commit, but local master was not synchronized. $_" }
            Write-Host "Merged #$number without a release: $commit"
            Write-Host "Local master synchronized: $($synced.Commit)"
            return
        }
    }
    else {
        # Open or update the pull request for this worktree's branch.
        $branch = (Invoke-Native git @('rev-parse', '--abbrev-ref', 'HEAD')).Trim()
        if ($branch -in 'HEAD', 'master') { throw 'Ship from a feature branch in your own worktree, not from master or a detached HEAD.' }
        $gitDir = (Invoke-Native git @('rev-parse', '--path-format=absolute', '--git-dir')).Trim()
        $commonDir = (Invoke-Native git @('rev-parse', '--path-format=absolute', '--git-common-dir')).Trim()
        if ($gitDir -eq $commonDir) { throw 'Agents ship from a linked worktree: git worktree add -b <branch> <path> origin/master.' }
        if (@(Invoke-Native git @('status', '--porcelain', '--untracked-files=no')).Count) { throw 'Commit or discard tracked changes first; only committed work is reviewed and shipped.' }
        & git merge-base --is-ancestor origin/master HEAD
        if ($LASTEXITCODE -ne 0) { throw 'The branch does not contain the latest origin/master. Merge it (git merge origin/master), resolve conflicts, and rerun.' }
        $changed = @(Invoke-Native git @('diff', '--name-only', '--no-renames', 'origin/master', 'HEAD'))
        if (!$changed.Count) { throw 'The branch has no changes from origin/master.' }
        # Deleting a file adds no content, so removals skip the path rules.
        @(Invoke-Native git @('diff', '--name-only', '--no-renames', '--diff-filter=d', 'origin/master', 'HEAD')) | ForEach-Object { $null = Assert-ShipPathName $_ }
        $untracked = @(Invoke-Native git @('ls-files', '--others', '--exclude-standard'))
        if ($untracked.Count) { Write-Warning "Untracked files are not shipped: $($untracked -join ', ')" }
        $existing = Find-BranchPullRequest $branch
        if (!$existing -and !$Message -and !$NoRelease) { throw 'Pass -Message with the release note users will read.' }
        if (!$existing -and !$Message -and !$Title) { throw 'Pass -Title for the pull request.' }
        if (!$existing -and !$BodyFile) { throw 'Pass -BodyFile with the pull request description for the reviewer.' }
        $latest = (Get-PublicJson "$apiRoot/releases/latest").tag_name -replace '^v', ''
        $branchVersion = Get-PubspecVersion $root 'HEAD'
        $masterVersion = Get-PubspecVersion $root 'origin/master'
        if ($NoRelease) {
            if ($branchVersion.Name -cne $masterVersion.Name -or $branchVersion.Build -ne $masterVersion.Build) { throw 'A change that is not released keeps the version from master.' }
            $target = $branchVersion
        }
        else {
            $target = Get-PullRequestVersion $Version $latest $masterVersion $branchVersion
            & git show-ref --verify --quiet "refs/tags/v$($target.Name)"
            if ($LASTEXITCODE -eq 0) { throw "Tag v$($target.Name) already exists. Choose a higher version." }
        }
        $Version = $target.Name
        $label = "$($target.Name)+$($target.Build)"
        Write-Host "$(if ($existing) { "Update #$($existing.number)" } else { 'Open a pull request' }) for $branch $(if ($NoRelease) { 'without a release' } else { "as BlackPearl Mobile $label" }) with these files:"
        $changed | ForEach-Object { Write-Host "  $_" }
        if ($Plan) { Write-Host 'Preview complete. No files, commits, branches, or pull requests changed.'; return }
        $flutterPath = Resolve-Flutter $Flutter
        if ($branchVersion.Name -cne $target.Name -or $branchVersion.Build -ne $target.Build) {
            $pubspecPath = Join-Path $root 'pubspec.yaml'
            [IO.File]::WriteAllText($pubspecPath, (Set-PubspecVersion ([IO.File]::ReadAllText($pubspecPath)) $target))
            Invoke-Native git @('commit', '--quiet', '-m', "Set version $label", '--', 'pubspec.yaml')
        }
        $head = (Invoke-Native git @('rev-parse', 'HEAD')).Trim()
        # Push first, so the workflow and the review start at once; the release checks run here meanwhile and -Merge
        # waits for them.
        Invoke-Native git @('push', '--set-upstream', 'origin', "HEAD:refs/heads/$branch")
        $summary = if ($BodyFile) { Get-Content -LiteralPath $BodyFile -Raw } else { Get-PullRequestSummary $existing.body }
        $note = if ($NoRelease) { 'Not released.' } elseif ($Message) { $Message } else { Get-ReleaseNote $existing.body }
        $body = Format-PullRequestBody $summary $note $(if ($NoRelease) { 'none' } else { $Version })
        $prTitle = if ($Title) { $Title } elseif ($existing) { $existing.title } elseif ($Message.Length -le 100) { $Message } else { $Message.Substring(0, 99) + '…' }
        $pull = if ($existing) { Invoke-GitHub "/pulls/$($existing.number)" -Method Patch -Body @{ title = $prTitle; body = $body } }
        else { Invoke-GitHub '/pulls' -Method Post -Body @{ title = $prTitle; head = $branch; base = 'master'; body = $body } }
        Stop-SupersededChecks $root $branch $head
        $local = Get-CheckState (Get-CheckRecordPath $root $head)
        if ($local.State -in 'passed', 'running') { $checksNote = "release checks $($local.State) already" }
        else { $checksNote = "release checks running in the background, log $(Start-BackgroundChecks $root $head $flutterPath $branch)" }
        Write-Host "Pull request: $($pull.html_url)"
        Write-Host "Head: $head ($(if ($NoRelease) { 'not released' } else { "BlackPearl Mobile $label" }); $checksNote)"
        Write-Host "Next: ask a separate reviewer agent now to review #$($pull.number) at $head with the review-pr skill (.claude/skills/review-pr/SKILL.md)."
        Write-Host 'The release checks and the workflow run during the review. ship.ps1 -Status shows them, the review verdict, and any failure.'
        Write-Host "Fix what fails or what the reviewer finds and rerun this script until it approves, then run ship.ps1 -Merge$(if ($NoRelease) { ' -NoRelease' }); it waits for the checks."
        return
    }
    $record = Join-Path (Get-ShipRecordRoot $root) ('ship-' + $Version + '-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $record -Force | Out-Null
    # After a merge only -VerifyOnly can carry on; -Merge refuses the merged pull request.
    $verifyResume = "./scripts/ship.ps1 -VerifyOnly -Version $Version$(if ($Merge) { " (#$number is already merged as $commit and tagged v$Version)" })"
    $run = Wait-ReleaseBuild $Version $commit $deadline $pauseAt $verifyResume
    $result = Test-PublishedRelease $Version $record $deadline $pauseAt $verifyResume
    $result.Actions = $run.html_url
    $result.Commit = $commit
    $result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $record 'verified.json')
    try { $result.LocalMaster = Sync-ShippedMaster $root $commit $record }
    catch { throw "Release v$Version is publicly verified, but local master was not synchronized. $_" }
    $result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $record 'verified.json')
    $outcome = if ($VerifyOnly) { 'Verified existing release' } else { 'Shipped' }
    Write-Host "$outcome BlackPearl Mobile ${Version}: $($result.Release)"
    Write-Host "Actions: $($run.html_url)"
    Write-Host "Verified APKs: $($result.Apks -join '; ')"
    Write-Host "Verification record: $record"
    Write-Host "Local master synchronized: $($result.LocalMaster.Commit)"
}
catch {
    if ($_.Exception -is [ShipPausedException]) { $paused = $_.Exception.Message }
    else {
        if ($Merge -and $Version) { Write-Warning "If v$Version was pushed, recheck with -VerifyOnly -Version $Version. Never move a published tag." }
        throw
    }
}
finally { Pop-Location }
# Exit code 3: still waiting, not failed. The message names the command that continues.
if ($paused) { Write-Host $paused; exit 3 }
