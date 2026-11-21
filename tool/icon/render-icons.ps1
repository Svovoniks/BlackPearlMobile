# Renders the launcher icon from the SVGs in this folder into android/app/src/main/res, using Microsoft Edge in headless mode.
# Run it after changing an SVG: ./tool/icon/render-icons.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$res = Join-Path $here '..\..\android\app\src\main\res' | Resolve-Path
$edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found.' }
$profileDir = Join-Path ([IO.Path]::GetTempPath()) ("icon-render-" + [guid]::NewGuid().ToString('N'))
Add-Type -AssemblyName System.Drawing

function Render([string]$svg, [int]$size, [double]$scale, [string]$out) {
    $uri = ([Uri](Join-Path $here $svg)).AbsoluteUri
    & $edge --headless=new --disable-gpu --hide-scrollbars --no-first-run "--user-data-dir=$profileDir" `
        --default-background-color=00000000 "--force-device-scale-factor=$scale" "--window-size=$size,$size" "--screenshot=$out" $uri 2>$null | Out-Null
    $pixels = [math]::Round($size * $scale)
    $image = [Drawing.Image]::FromFile($out)
    try { if ($image.Width -ne $pixels -or $image.Height -ne $pixels) { throw "$out is $($image.Width)x$($image.Height), not ${pixels}x$pixels" } }
    finally { $image.Dispose() }
}

try {
    foreach ($density in @(@('mdpi', 1), @('hdpi', 1.5), @('xhdpi', 2), @('xxhdpi', 3), @('xxxhdpi', 4))) {
        $dir = Join-Path $res "mipmap-$($density[0])"
        $scale = $density[1]
        foreach ($layer in 'foreground', 'background', 'monochrome') { Render "$layer.svg" 108 $scale (Join-Path $dir "ic_launcher_$layer.png") }
        Render 'legacy.svg' 48 $scale (Join-Path $dir 'ic_launcher.png')
        Write-Host "mipmap-$($density[0]) done"
    }
}
finally { Remove-Item -Recurse -Force $profileDir -ErrorAction SilentlyContinue }
