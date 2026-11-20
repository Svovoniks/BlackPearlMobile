# Flutter links each Windows plugin into windows/flutter/ephemeral/.plugin_symlinks, which needs symlink rights
# (Developer Mode or an elevated shell). Without them, this makes directory junctions instead, which any user can
# create. Flutter accepts a junction that already points at the right folder and leaves it alone. Run it after
# `flutter pub get` whenever the plugin list changes, then build as usual.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$deps = Get-Content (Join-Path $root '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
$dir = Join-Path $root 'windows\flutter\ephemeral\.plugin_symlinks'
New-Item -ItemType Directory -Force $dir | Out-Null
foreach ($plugin in $deps.plugins.windows) {
    $link = Join-Path $dir $plugin.name
    # The dependencies file can hold doubled separators; junction targets come back with single ones.
    $target = ($plugin.path -replace '\\+', '\').TrimEnd('\')
    if (Test-Path $link) {
        $item = Get-Item $link -Force
        if ($item.LinkType -and ($item.Target | Select-Object -First 1) -eq $target) { continue }
        cmd /c rmdir "$link" | Out-Null
    }
    cmd /c mklink /J "$link" "$target" | Out-Null
    Write-Output "$($plugin.name) -> $target"
}
