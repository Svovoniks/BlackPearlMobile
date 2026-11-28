# Pull request, check record and tool helpers shared by ship.ps1, review-pr.ps1 and release-checks.ps1. Dot-source only.
$repository = 'Svovoniks/BlackPearlMobile'
$apiRoot = "https://api.github.com/repos/$repository"
# The name of .github/workflows/build.yml.
$buildWorkflow = 'build'
# Review verdicts are PR comments carrying this marker. Every account here is the same
# owner, so GitHub's own approve state is unavailable (authors cannot approve their PRs).
# Only a marker ending the comment counts, so findings that quote another marker cannot decide the verdict.
$reviewMarkerPattern = '<!-- blackpearl-mobile-review head=([a-f0-9]{40}) verdict=(approve|changes) -->\s*\z'

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Command failed (exit $LASTEXITCODE): $($Arguments -join ' ')" }
}
# Flutter is often not on PATH. In order: -Flutter, $env:FLUTTER, flutter on PATH, then ~/flutter/bin.
function Resolve-Flutter {
    param([string]$Requested = '')
    $candidates = @($Requested, $env:FLUTTER) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) { return (Resolve-Path -LiteralPath $candidate).Path }
        throw "Flutter was not found at $candidate."
    }
    $onPath = Get-Command flutter -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($onPath) { return $onPath.Source }
    $name = if ($IsWindows) { 'flutter.bat' } else { 'flutter' }
    $home_ = Join-Path ([Environment]::GetFolderPath('UserProfile')) "flutter/bin/$name"
    if (Test-Path -LiteralPath $home_) { return (Resolve-Path -LiteralPath $home_).Path }
    throw 'Flutter was not found. Pass -Flutter <path to flutter or flutter.bat>, or set FLUTTER.'
}
# The pubspec version, as name (1.2.3) and build number (the +N, which numbers the APKs' version codes).
function ConvertFrom-PubspecVersion {
    param([string]$Pubspec)
    $match = [regex]::Matches($Pubspec, '(?m)^version:[ \t]*(\d+\.\d+\.\d+)\+(\d+)[ \t]*\r?$')
    if ($match.Count -ne 1) { throw 'pubspec.yaml must have exactly one version: line of the form 1.2.3+N.' }
    return [pscustomobject]@{ Name = $match[0].Groups[1].Value; Build = [int]$match[0].Groups[2].Value }
}
function Get-PubspecVersion {
    param([string]$Root, [string]$Revision)
    return ConvertFrom-PubspecVersion ((Invoke-Native git @('-C', $Root, 'show', "${Revision}:pubspec.yaml")) -join "`n")
}
# Where check copies, review worktrees and fixtures go. On Windows, the user's own temp folder rather than TEMP, which
# some shells point at C:\Windows\Temp: users cannot list that folder, and Gradle's javac, which resolves real paths by
# listing each parent, fails there ("AccessDeniedException ... R.jar").
function Get-ScratchRoot {
    if ($IsWindows -and $env:LOCALAPPDATA) {
        $userTemp = Join-Path $env:LOCALAPPDATA 'Temp'
        if (Test-Path -LiteralPath $userTemp -PathType Container) { return [IO.Path]::GetFullPath($userTemp) }
    }
    return [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
}
# Deletes a file or folder if it can and never throws; returns whether it is gone. It uses .NET rather than Remove-Item,
# which some temp folders refuse ("Access is denied") when the folder above cannot be listed. Read-only files (git's
# objects) are made writable first, without following links out of the folder.
function Remove-Tree {
    param([string]$Path)
    try {
        if ([IO.File]::Exists($Path)) {
            [IO.File]::SetAttributes($Path, [IO.FileAttributes]::Normal)
            [IO.File]::Delete($Path)
        }
        elseif ([IO.Directory]::Exists($Path)) {
            $options = [IO.EnumerationOptions]::new()
            $options.RecurseSubdirectories = $true; $options.IgnoreInaccessible = $true
            $options.AttributesToSkip = [IO.FileAttributes]::ReparsePoint
            foreach ($file in [IO.Directory]::EnumerateFiles($Path, '*', $options)) { [IO.File]::SetAttributes($file, [IO.FileAttributes]::Normal) }
            foreach ($folder in @($Path) + @([IO.Directory]::EnumerateDirectories($Path, '*', $options))) {
                [IO.DirectoryInfo]::new($folder).Attributes = [IO.FileAttributes]::Directory
            }
            [IO.Directory]::Delete($Path, $true)
        }
    }
    catch { }
    return !(Test-Path -LiteralPath $Path)
}
function Get-CheckRecordPath {
    param([string]$Root, [string]$Commit)
    # Shared by every worktree, so -Merge and reviewers can run anywhere and still see what was checked.
    $common = (Invoke-Native git @('-C', $Root, 'rev-parse', '--path-format=absolute', '--git-common-dir')).Trim()
    return Join-Path $common "blackpearl-checks/$Commit.json"
}
function Write-CheckRecord {
    param([string]$Path, [hashtable]$Record)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $partial = "$Path.partial-$([guid]::NewGuid().ToString('N'))"
    $Record | ConvertTo-Json | Set-Content -LiteralPath $partial
    # Replacing the record fails (sharing violation or access denied) while another process reads it, which waiting
    # release checks and -Merge do often.
    for ($attempt = 1; ; $attempt++) {
        try { [IO.File]::Move($partial, $Path, $true); return }
        catch [IO.IOException], [UnauthorizedAccessException] {
            if ($attempt -ge 50) { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue; throw }
            Start-Sleep -Milliseconds 100
        }
    }
}
function Get-CheckState {
    param([string]$Path)
    # Release checks run in the background after a push. Their record says running, passed or failed. A running record
    # whose process is gone was interrupted.
    # A record being replaced can be briefly missing or locked, so a read tries a few times before it believes either.
    # A record that stays unreadable or empty (a crash mid-write) fails after about a second.
    for ($attempt = 1; ; $attempt++) {
        try {
            if (Test-Path -LiteralPath $Path) {
                $record = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json
                # [pscustomobject] would match $null too: it is PSObject.
                if ($null -ne $record -and $record -is [Management.Automation.PSCustomObject]) { break }
                throw "The release check record $Path holds no record. Delete it, then rerun ship.ps1 to check the commit again."
            }
            if ($attempt -ge 3) { return [pscustomobject]@{ State = 'missing' } }
        }
        catch { if ($attempt -ge 10) { throw } }
        Start-Sleep -Milliseconds 100
    }
    if (!$record.PSObject.Properties['State']) { $record | Add-Member State 'passed' }
    if ($record.State -eq 'running') {
        # A process this user cannot open (a service that reused the id) has no start time, so it is not the checks.
        $started = $null
        try { $started = (Get-Process -Id $record.Pid -ErrorAction Stop).StartTime } catch { }
        if (!$started -or $started.ToUniversalTime().Ticks -ne [long]$record.ProcessStart) { $record.State = 'interrupted' }
    }
    return $record
}
# Release checks on one computer take turns, BlackPearl's and BlackPearl Mobile's alike (both ship.ps1 use this file),
# among the runs of one user, whose LOCALAPPDATA holds the lock. Waiting runs are not served in order: whichever looks
# first after a turn ends takes the next one.
# Two runs at once each take about twice as long, and the desktop app's load-sensitive startup gate
# (desktop-main-suite.ps1) fails on all its attempts while another run builds or tests beside it. The turn is an
# exclusive open of the lock file, which the system releases when its process ends, however it ends. The file beside it
# names the run that holds the turn, for the runs that wait.
function Get-ReleaseCheckLockPath {
    $directory = if ($IsWindows -and $env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { [IO.Path]::GetTempPath() }
    return Join-Path $directory 'blackpearl-release-checks.lock'
}
function Get-ReleaseCheckHolder {
    param([string]$Path = (Get-ReleaseCheckLockPath))
    try {
        # Shared every way, so reading never stops the holder writing or removing its claim.
        $stream = [IO.File]::Open("$Path.json", [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        try { $holder = [IO.StreamReader]::new($stream).ReadToEnd() | ConvertFrom-Json } finally { $stream.Dispose() }
        return "$($holder.Run), started $(([datetimeoffset]$holder.Since).ToLocalTime().ToString('HH:mm'))"
    }
    catch { return 'another run' }
}
# Waits until no other release checks run on this computer, and returns the turn for Exit-ReleaseCheckTurn. -OnWait
# gets the run waited for each time that changes. While the turn is held, BLACKPEARL_RELEASE_CHECK_TURN tells
# release-checks.ps1 in a child process that it already has it.
function Enter-ReleaseCheckTurn {
    param([string]$Run, [scriptblock]$OnWait = $null, [string]$Path = (Get-ReleaseCheckLockPath), [double]$TimeoutMinutes = 180, [int]$PollSeconds = 10)
    $deadline = [datetime]::UtcNow.AddMinutes($TimeoutMinutes)
    $waitingFor = $null
    while ($true) {
        $turn = $null
        try { $turn = [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch [IO.IOException] { }
        if ($turn) {
            # Best effort: the turn is already ours, and a waiting run that cannot read the claim says "another run".
            try { [IO.File]::WriteAllText("$Path.json", (@{ Run = $Run; Pid = $PID; Since = [datetime]::UtcNow.ToString('o') } | ConvertTo-Json)) } catch { }
            $held = [pscustomobject]@{ Stream = $turn; Path = $Path; Inherited = $env:BLACKPEARL_RELEASE_CHECK_TURN }
            $env:BLACKPEARL_RELEASE_CHECK_TURN = $Path
            return $held
        }
        $holder = Get-ReleaseCheckHolder $Path
        if ($holder -cne $waitingFor) {
            $waitingFor = $holder
            if ($OnWait) { & $OnWait $holder }
        }
        if ([datetime]::UtcNow -ge $deadline) { throw "The release checks waited $TimeoutMinutes minutes for their turn on this computer, behind $waitingFor." }
        Start-Sleep -Seconds $PollSeconds
    }
}
function Exit-ReleaseCheckTurn {
    param($Turn)
    if (!$Turn) { return }
    $env:BLACKPEARL_RELEASE_CHECK_TURN = $Turn.Inherited
    Remove-Item -LiteralPath "$($Turn.Path).json" -Force -ErrorAction SilentlyContinue
    $Turn.Stream.Dispose()
}
# release-checks.ps1 run by hand, such as a reviewer's, takes a turn too. Not in CI, and not inside a run that holds the
# turn already (ship.ps1 -CheckCommit).
function Enter-ManualReleaseCheckTurn {
    param([string]$Run)
    if ($env:GITHUB_ACTIONS -eq 'true' -or $env:BLACKPEARL_RELEASE_CHECK_TURN) { return $null }
    return Enter-ReleaseCheckTurn $Run { param($holder) Write-Host "Waiting for the release checks of $holder to finish: release checks on this computer take turns." }
}
# A running record's progress: queued behind another computer-wide run, or running.
function Format-CheckProgress {
    param($State)
    if ($State.State -eq 'running' -and $State.PSObject.Properties['WaitingFor'] -and $State.WaitingFor) { return "queued behind $($State.WaitingFor)" }
    return $State.State
}
function Format-CheckEvidence {
    param($State)
    $parts = @()
    if ($State.Log -and (Test-Path -LiteralPath $State.Log)) { $parts += "Log: $($State.Log)." }
    if ($State.Checkout -and (Test-Path -LiteralPath $State.Checkout)) { $parts += "Checked copy kept at $($State.Checkout)." }
    return $(if ($parts.Count) { ($parts -join ' ') + ' ' } else { '' })
}
function Get-PublicJson {
    param([string]$Url)
    # Public verification deliberately does not use GH_TOKEN or a GitHub CLI session.
    Invoke-RestMethod -Uri $Url -Headers @{ 'User-Agent' = 'BlackPearlMobile-release-verification' } -TimeoutSec 60
}
function Get-GitHubToken {
    # The token git already uses for pushes; it is never printed.
    $env:GIT_TERMINAL_PROMPT = '0'; $env:GCM_INTERACTIVE = 'never'
    $fill = "protocol=https`nhost=github.com`n`n" | & git credential fill 2>$null
    $password = @($fill | Where-Object { $_ -like 'password=*' } | Select-Object -First 1)
    if (!$password.Count) { throw 'No GitHub credential is stored for git. Pull requests need the same credential used for pushes.' }
    return $password[0].Substring(9)
}
function Invoke-GitHub {
    param([string]$Path, [string]$Method = 'Get', $Body = $null)
    if (!$script:gitHubToken) { $script:gitHubToken = Get-GitHubToken }
    $request = @{
        Method = $Method; Uri = "$apiRoot$Path"; TimeoutSec = 60
        Headers = @{ 'User-Agent' = 'BlackPearlMobile-pull-requests'; Authorization = "Bearer $script:gitHubToken"; Accept = 'application/vnd.github+json' }
    }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 5; $request.ContentType = 'application/json' }
    # Enumerate JSON arrays so callers can count list responses with @().
    Invoke-RestMethod @request | ForEach-Object { $_ }
}
function Find-BranchPullRequest {
    param([string]$Branch)
    $owner = $repository.Split('/')[0]
    return Invoke-GitHub "/pulls?state=open&base=master&head=${owner}:$([uri]::EscapeDataString($Branch))" | Select-Object -First 1
}
function Get-PullRequestComments {
    param([int]$Number)
    $comments = @(); $page = 1
    do {
        $batch = @(Invoke-GitHub "/issues/$Number/comments?per_page=100&page=$page")
        $comments += $batch; $page++
    } while ($batch.Count -eq 100)
    return $comments
}
function Format-ReviewMarker {
    param([string]$Head, [string]$Verdict)
    return "<!-- blackpearl-mobile-review head=$Head verdict=$Verdict -->"
}
function Get-ReviewVerdict {
    param($Comments)
    # The newest marked comment wins. Public commenters cannot approve or block.
    $latest = $null
    foreach ($comment in @($Comments | Sort-Object { [datetime]$_.created_at }, { [long]$_.id })) {
        if ($comment.author_association -notin 'OWNER', 'MEMBER', 'COLLABORATOR') { continue }
        $match = [regex]::Match([string]$comment.body, $reviewMarkerPattern)
        if ($match.Success) { $latest = @{ Head = $match.Groups[1].Value; Verdict = $match.Groups[2].Value; Url = $comment.html_url } }
    }
    return $latest
}
function Assert-ReviewApproval {
    param($Comments, [string]$Head)
    $verdict = Get-ReviewVerdict $Comments
    if (!$verdict) { throw 'The pull request has no reviewer verdict. Ask a separate reviewer agent to review it with the review-pr skill.' }
    if ($verdict.Head -cne $Head) { throw "The latest review covers $($verdict.Head), but the pull request head is $Head. Request a re-review of the current head." }
    if ($verdict.Verdict -cne 'approve') { throw "The reviewer requested changes ($($verdict.Url)). Fix them, rerun ship.ps1, and request a re-review." }
    return $verdict
}
function Get-HeadCheckState {
    param($Runs, [string]$Head)
    # The newest run of the build workflow for each event must pass on this exact commit.
    $latest = @(@($Runs) | Where-Object { $_ -and $_.head_sha -ceq $Head -and $_.name -ceq $buildWorkflow } |
        Group-Object event | ForEach-Object { $_.Group | Sort-Object id, run_attempt -Descending | Select-Object -First 1 })
    if (!$latest.Count) { return @{ State = 'pending'; Detail = 'Waiting for the build workflow to start' } }
    $failed = @($latest | Where-Object { $_.status -eq 'completed' -and $_.conclusion -ne 'success' })
    if ($failed.Count) { return @{ State = 'failure'; Detail = "Build workflow $($failed[0].conclusion): $($failed[0].html_url)" } }
    $detail = ($latest | ForEach-Object { "$($_.event) $($_.status) $($_.conclusion)".Trim() }) -join ', '
    if (@($latest | Where-Object status -ne 'completed').Count) { return @{ State = 'pending'; Detail = $detail } }
    return @{ State = 'success'; Detail = $detail; Urls = @($latest.html_url) }
}
function Format-PullRequestBody {
    param([string]$Summary, [string]$Note, [string]$Version)
    return "$($Summary.Trim())`n`n### Release note`n`n$($Note.Trim())`n`n<!-- blackpearl-mobile-release version=$Version -->"
}
function Get-PullRequestSummary {
    param([string]$Body)
    return ([regex]::Split([string]$Body, '\r?\n### Release note\r?\n')[0]).Trim()
}
function Get-ReleaseNote {
    param([string]$Body)
    $match = [regex]::Match([string]$Body, '(?s)### Release note\r?\n(.+?)\r?\n<!-- blackpearl-mobile-release version=')
    if (!$match.Success -or !$match.Groups[1].Value.Trim()) { return $null }
    return $match.Groups[1].Value.Trim()
}
