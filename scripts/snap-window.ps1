<#
.SYNOPSIS
  PNG of the game's desktop window (what the flat mirror shows: game image plus UEVR's own menu when
  that menu is open). For quick checks such as "is the UEVR menu open at start", on either runtime.
.EXAMPLE
  .\scripts\snap-window.ps1 -Out logs\<run>\window.png
#>
param([Parameter(Mandatory)] [string]$Out, [string]$ProcessName = 'VotV-Win64-Shipping')
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class SnapWin {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint flags);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
'@
[SnapWin]::SetProcessDPIAware() | Out-Null
$p = Get-Process -Name $ProcessName | Where-Object { $_.MainWindowHandle -ne 0 } | Select-Object -First 1
if (-not $p) { throw "no $ProcessName window" }
$r = New-Object SnapWin+RECT
[SnapWin]::GetWindowRect($p.MainWindowHandle, [ref]$r) | Out-Null
$w = $r.R - $r.L; $h = $r.B - $r.T
$bmp = New-Object System.Drawing.Bitmap $w, $h
$g = [System.Drawing.Graphics]::FromImage($bmp)
$dc = $g.GetHdc()
# 2 = PW_RENDERFULLCONTENT: works for DX swap chains even when the window is covered.
$ok = [SnapWin]::PrintWindow($p.MainWindowHandle, $dc, 2)
$g.ReleaseHdc($dc); $g.Dispose()
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
Write-Host "window ${w}x${h} -> $Out (PrintWindow ok=$ok)"
