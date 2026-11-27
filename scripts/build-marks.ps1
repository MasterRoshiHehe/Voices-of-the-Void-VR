# Build the VOTV marks UEVR plugin and its offline test (MSVC Build Tools + Ninja), run the test.
# Output: build\votv_marks\votv_marks.dll (run-vr.ps1 copies it into the UEVR profile's plugins folder).
param([switch]$NoTest)
$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$src = Join-Path $repo 'src\votv_marks'
$out = Join-Path $repo 'build\votv_marks'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'MSVC Build Tools not found' }
$vcvars = Join-Path $vs 'VC\Auxiliary\Build\vcvars64.bat'
$ninja = (Get-Command ninja -ErrorAction SilentlyContinue).Source
if (-not $ninja) { $ninja = 'E:\Programs\Ninja\ninja.exe' }
New-Item -ItemType Directory -Force $out | Out-Null
$cmd = "`"$vcvars`" >nul && cmake -S `"$src`" -B `"$out`" -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_MAKE_PROGRAM=`"$ninja`" >nul && cmake --build `"$out`""
cmd /c $cmd
if ($LASTEXITCODE -ne 0) { throw "build failed ($LASTEXITCODE)" }
Write-Host "built: $(Join-Path $out 'votv_marks.dll')"
if (-not $NoTest) {
    & (Join-Path $out 'mark_logic_test.exe')
    if ($LASTEXITCODE -ne 0) { throw 'mark_logic_test failed' }
}
