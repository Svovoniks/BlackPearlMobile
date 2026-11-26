#Requires -Version 7.0
# The release checks, in one list shared by ship.ps1 and the build workflow so the two cannot drift apart.
#   release-checks.ps1 -Lane ci    pub get, analyze, tests and the shipping script checks (the workflow's check job)
#   release-checks.ps1 -Lane all   the same, then the release APKs as the tag build makes them, signed with the debug key
#                                  (ship.ps1, on a clean copy of the commit)
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('ci', 'all')][string]$Lane,
    [string]$Flutter = '',
    # Receives the failing check's error, for the record ship.ps1 keeps.
    [string]$FailureFile = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'github-pr.ps1')
$root = Split-Path -Parent $PSScriptRoot

function Invoke-Check {
    param([string]$Name, [string]$Command, [string[]]$Arguments)
    $grouped = $env:GITHUB_ACTIONS -eq 'true'
    if ($grouped) { Write-Host "::group::$Name" }
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        & $Command @Arguments
        if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
    }
    finally { if ($grouped) { Write-Host '::endgroup::' } }
    Write-Host ("{0} passed in {1:N0} s" -f $Name, $watch.Elapsed.TotalSeconds)
}

Push-Location $root
try {
    $flutterPath = Resolve-Flutter $Flutter
    # On Windows, a pub get that writes a new plugin list links the Windows plugins under windows/flutter/ephemeral,
    # which needs permission to create symbolic links (Developer Mode). Without it Flutter stops there, after writing
    # everything else; a second run finds the list unchanged and succeeds without the links. Only a Windows build uses
    # them, and these checks make none.
    $packages = @(& $flutterPath pub get 2>&1 | ForEach-Object { "$_" })
    $packagesExit = $LASTEXITCODE
    $packages | Write-Host
    if ($packagesExit -eq 0) { Write-Host 'Packages passed' }
    elseif ($IsWindows -and ($packages -join "`n") -match 'requires symlink support') {
        Write-Host 'This shell cannot create symbolic links, so the Windows plugins are not linked. Running pub get once more.'
        Invoke-Check 'Packages' $flutterPath @('pub', 'get')
    }
    else { throw "Packages failed with exit code $packagesExit." }
    Invoke-Check 'Analysis' $flutterPath @('analyze')
    Invoke-Check 'Tests' $flutterPath @('test')
    $shell = (Get-Process -Id $PID).Path
    Invoke-Check 'Shipping script checks' $shell @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'ship-checks.ps1'))
    if ($Lane -eq 'all') {
        # The tag build's command (.github/workflows/build.yml) without its secrets: no release key, so Gradle signs with
        # the debug key, and no Sentry token, so nothing is uploaded. It catches what only a release build meets, such as
        # R8 and the native libraries for both ABIs, before the merge rather than at the tag.
        $saved = @{ SENTRY_AUTH_TOKEN = $env:SENTRY_AUTH_TOKEN; BLACKPEARL_REQUIRE_SIGNING = $env:BLACKPEARL_REQUIRE_SIGNING }
        $env:SENTRY_AUTH_TOKEN = $null; $env:BLACKPEARL_REQUIRE_SIGNING = $null
        try {
            Invoke-Check 'Release APKs' $flutterPath @('build', 'apk', '--release', '--split-per-abi', '--target-platform', 'android-arm,android-arm64')
        }
        finally { foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        foreach ($abi in 'arm64-v8a', 'armeabi-v7a') {
            $apk = Join-Path $root "build/app/outputs/flutter-apk/app-$abi-release.apk"
            if (!(Test-Path -LiteralPath $apk) -or (Get-Item -LiteralPath $apk).Length -le 0) { throw "Release APKs: the $abi APK was not built." }
            Write-Host ("{0}: {1:N1} MB" -f (Split-Path -Leaf $apk), ((Get-Item -LiteralPath $apk).Length / 1MB))
        }
    }
}
catch {
    if ($FailureFile) { "$_" | Set-Content -LiteralPath $FailureFile }
    throw
}
finally { Pop-Location }
