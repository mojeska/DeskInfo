<#
.SYNOPSIS
    Draws system information in the top-right corner of the desktop wallpaper and applies it.

.DESCRIPTION
    Runs in the signed-in user's session, like BGInfo. It reads the user's current wallpaper
    (or uses a solid color), draws an info panel on it at the primary screen's resolution,
    saves the result to %LOCALAPPDATA%\DeskInfo\wallpaper.png and sets it as the wallpaper.

    The original wallpaper is copied to %LOCALAPPDATA%\DeskInfo the first time, so repeat runs
    don't stack panels on top of each other. -Restore puts the original back.

    Works in Windows PowerShell 5.1 (built into Windows) and PowerShell 7 on Windows.

.EXAMPLE
    .\DeskInfo.ps1
    Builds and applies the wallpaper for the current user.

.EXAMPLE
    .\DeskInfo.ps1 -NoApply -OutputPath C:\Temp\preview.png
    Builds the image only, to preview it.

.EXAMPLE
    .\DeskInfo.ps1 -Restore
    Puts the user's original wallpaper back.
#>
[CmdletBinding(DefaultParameterSetName = 'Build')]
param(
    [Parameter(ParameterSetName = 'Build')]
    [string]$OutputPath,

    [Parameter(ParameterSetName = 'Build')]
    [string]$FontName = 'Segoe UI',

    # Font size in points for the info lines. The computer name is drawn larger.
    [Parameter(ParameterSetName = 'Build')]
    [single]$FontSize = 11,

    # Used when the user has no wallpaper (solid color desktop).
    [Parameter(ParameterSetName = 'Build')]
    [string]$BackgroundColor = '#1F3A5F',

    # Distance in pixels from the top and right edges of the usable desktop area.
    [Parameter(ParameterSetName = 'Build')]
    [int]$Margin = 24,

    # Panel opacity, 0 (invisible) to 255 (solid black).
    [Parameter(ParameterSetName = 'Build')]
    [ValidateRange(0, 255)]
    [int]$PanelOpacity = 150,

    # Build the image but don't set it as the wallpaper.
    [Parameter(ParameterSetName = 'Build')]
    [switch]$NoApply,

    [Parameter(ParameterSetName = 'Restore', Mandatory)]
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$stateDir   = Join-Path $env:LOCALAPPDATA 'DeskInfo'
$stateKey   = 'HKCU:\Software\DeskInfo'
$desktopKey = 'HKCU:\Control Panel\Desktop'
$logPath    = Join-Path $stateDir 'last-run.log'
if (-not $OutputPath) { $OutputPath = Join-Path $stateDir 'wallpaper.png' }

New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

Add-Type -AssemblyName System.Drawing, System.Windows.Forms
if (-not ('DeskInfoNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class DeskInfoNative {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SystemParametersInfo(int uiAction, int uiParam, string pvParam, int fWinIni);
}
'@
}

function Set-Wallpaper {
    param([string]$Path, [string]$Style = '10', [string]$Tile = '0')
    # WallpaperStyle 10 = Fill. Our image is already screen-sized, so Fill doesn't change it.
    Set-ItemProperty -Path $desktopKey -Name WallpaperStyle -Value $Style
    Set-ItemProperty -Path $desktopKey -Name TileWallpaper -Value $Tile
    # SPI_SETDESKWALLPAPER = 0x14; SPIF_UPDATEINIFILE | SPIF_SENDCHANGE = 3
    if (-not [DeskInfoNative]::SystemParametersInfo(0x14, 0, $Path, 3)) {
        throw "SystemParametersInfo failed (error $([Runtime.InteropServices.Marshal]::GetLastWin32Error()))."
    }
}

function Get-OriginalWallpaper {
    # Returns the path of our saved copy of the user's own wallpaper, or $null for a solid color.
    # If the current wallpaper isn't ours, the user changed it, so take a fresh copy.
    $desktop = Get-ItemProperty -Path $desktopKey
    $current = $desktop.Wallpaper
    if (-not (Test-Path $stateKey)) { New-Item -Path $stateKey -Force | Out-Null }

    if ($current -ne $OutputPath) {
        Get-ChildItem -Path $stateDir -Filter 'original.*' -ErrorAction SilentlyContinue | Remove-Item -Force
        $copy = ''
        if ($current -and (Test-Path -LiteralPath $current)) {
            # Copy it: Windows overwrites TranscodedWallpaper when we set ours.
            $ext = [IO.Path]::GetExtension($current)
            if (-not $ext) { $ext = '.img' }
            $copy = Join-Path $stateDir "original$ext"
            Copy-Item -LiteralPath $current -Destination $copy -Force
        }
        Set-ItemProperty -Path $stateKey -Name OriginalCopy -Value $copy
        Set-ItemProperty -Path $stateKey -Name OriginalPath -Value ([string]$current)
        Set-ItemProperty -Path $stateKey -Name OriginalStyle -Value ([string]$desktop.WallpaperStyle)
        Set-ItemProperty -Path $stateKey -Name OriginalTile -Value ([string]$desktop.TileWallpaper)
    }

    $saved = (Get-ItemProperty -Path $stateKey -Name OriginalCopy -ErrorAction SilentlyContinue).OriginalCopy
    if ($saved -and (Test-Path -LiteralPath $saved)) { return $saved }
    return $null
}

function Get-DeskInfoData {
    $os  = Get-CimInstance Win32_OperatingSystem
    $cs  = Get-CimInstance Win32_ComputerSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cv  = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

    $release = $cv.DisplayVersion
    if (-not $release) { $release = $cv.ReleaseId }
    $osName = $os.Caption -replace '^Microsoft\s+', ''
    # Windows 11 still reports "Windows 10" in some registry values; WMI's Caption is reliable.
    $version = "$osName $release".Trim()
    $build = "$($cv.CurrentBuildNumber).$($cv.UBR)"

    $nics = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = TRUE')
    $ipLines = foreach ($nic in $nics) {
        foreach ($ip in $nic.IPAddress) {
            if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -notlike '169.254.*') { $ip }
        }
    }
    $gateways = $nics | ForEach-Object { $_.DefaultIPGateway } | Where-Object { $_ -match '^\d+\.' } | Select-Object -Unique
    $dns      = $nics | ForEach-Object { $_.DNSServerSearchOrder } | Where-Object { $_ } | Select-Object -Unique

    $domain = if ($cs.PartOfDomain) { $cs.Domain } else { "Workgroup: $($cs.Workgroup)" }

    $disks = Get-CimInstance Win32_LogicalDisk -Filter 'DriveType = 3' | ForEach-Object {
        if ($_.Size) {
            '{0}  {1:N0} GB free of {2:N0} GB' -f $_.DeviceID, ($_.FreeSpace / 1GB), ($_.Size / 1GB)
        }
    }

    # Server roles, from DomainRole and installed services (readable without admin rights).
    $roles = @()
    if ($cs.DomainRole -ge 4) { $roles += 'Domain controller' }
    $services = @(Get-Service -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
    $roleMap = [ordered]@{
        'VeeamBackupSvc' = 'Veeam B&R server'
        'DNS'            = 'DNS'
        'DHCPServer'     = 'DHCP'
        'CertSvc'        = 'Certificate authority'
        'W3SVC'          = 'IIS'
        'vmms'           = 'Hyper-V'
        'MSSQLSERVER'    = 'SQL Server'
    }
    foreach ($svc in $roleMap.Keys) { if ($services -contains $svc) { $roles += $roleMap[$svc] } }
    if ($services -like 'MSSQL$*' -and $roles -notcontains 'SQL Server') { $roles += 'SQL Server' }
    if ($services -contains 'VeeamTransportSvc' -and $roles -notcontains 'Veeam B&R server') { $roles += 'Veeam proxy/repository' }
    if (-not $roles) { $roles = @(if ($os.ProductType -eq 1) { 'Workstation' } else { 'Member server' }) }

    # Newest installed update. Get-HotFix lists cumulative updates; InstalledOn can be blank.
    $lastPatch = Get-HotFix -ErrorAction SilentlyContinue |
        Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
    $patch = if ($lastPatch) { '{0} ({1})' -f $lastPatch.InstalledOn.ToString('yyyy-MM-dd'), $lastPatch.HotFixID } else { 'Unknown' }

    # Pending reboot. A leading "!" draws the value in the warning color.
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'servicing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update' }
    $active  = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ActiveComputerName' -ErrorAction SilentlyContinue).ComputerName
    $pending = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -ErrorAction SilentlyContinue).ComputerName
    if ($active -and $pending -and $active -ne $pending) { $reasons += 'rename' }
    $reboot = if ($reasons) { '!Yes (' + ($reasons -join ', ') + ')' } else { 'No' }

    $up = (Get-Date) - $os.LastBootUpTime
    $uptime = '{0}d {1}h {2}m' -f $up.Days, $up.Hours, $up.Minutes

    $cpuName = ($cpu.Name -replace '\(R\)|\(TM\)|CPU\s+', '' -replace '\s+', ' ').Trim()
    $cores = ($cs.NumberOfLogicalProcessors)

    # Label = value (string or array of strings). Edit or reorder freely.
    [ordered]@{
        'User'      = "$env:USERDOMAIN\$env:USERNAME"
        'Domain'    = $domain
        'Role'      = @($roles)
        'OS'        = $version
        'Build'     = $build
        'Installed' = $os.InstallDate.ToString('yyyy-MM-dd')
        'Last patch' = $patch
        'Reboot'    = $reboot
        'IP'        = @($ipLines)
        'Gateway'   = @($gateways)
        'DNS'       = @($dns)
        'CPU'       = "$cpuName ($cores logical)"
        'Memory'    = '{0:N1} GB' -f ($cs.TotalPhysicalMemory / 1GB)
        'Disks'     = @($disks)
        'Boot time' = $os.LastBootUpTime.ToString('yyyy-MM-dd HH:mm')
        'Uptime'    = $uptime
    }
}

function New-RoundedRectPath {
    param([single]$X, [single]$Y, [single]$W, [single]$H, [single]$R)
    $d = $R * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $W - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $W - $d, $Y + $H - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $H - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $path
}

function New-DeskInfoImage {
    param([string]$Source)

    [void][DeskInfoNative]::SetProcessDPIAware()   # real pixels, not DPI-scaled ones
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $bounds = $screen.Bounds
    $work   = $screen.WorkingArea                  # excludes the taskbar, wherever it is
    $W = $bounds.Width
    $H = $bounds.Height

    # Scale text and spacing with the display's DPI (e.g. 150% scaling = 144 DPI).
    $screenG = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $dpiScale = $screenG.DpiX / 96 } finally { $screenG.Dispose() }
    $size   = [single]($FontSize * $dpiScale)
    $margin = [int]($Margin * $dpiScale)

    $bmp = New-Object System.Drawing.Bitmap $W, $H
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $fonts = @()
    try {
        $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit

        # Background: the user's wallpaper scaled to fill the screen, or a solid color.
        $g.Clear([System.Drawing.ColorTranslator]::FromHtml($BackgroundColor))
        if ($Source) {
            try {
                $img = [System.Drawing.Image]::FromFile($Source)
                try {
                    $scale = [Math]::Max($W / $img.Width, $H / $img.Height)
                    $dw = [single]($img.Width * $scale)
                    $dh = [single]($img.Height * $scale)
                    $g.DrawImage($img, [single](($W - $dw) / 2), [single](($H - $dh) / 2), $dw, $dh)
                } finally { $img.Dispose() }
            } catch {
                Write-Warning "Couldn't read wallpaper '$Source': $($_.Exception.Message). Using a solid color."
            }
        }

        # Text
        $data = Get-DeskInfoData
        $titleFont = New-Object System.Drawing.Font($FontName, [single]($size * 1.9), [System.Drawing.FontStyle]::Bold)
        $labelFont = New-Object System.Drawing.Font($FontName, $size, [System.Drawing.FontStyle]::Bold)
        $valueFont = New-Object System.Drawing.Font($FontName, $size, [System.Drawing.FontStyle]::Regular)
        $stampFont = New-Object System.Drawing.Font($FontName, [single]($size * 0.8), [System.Drawing.FontStyle]::Regular)
        $fonts = @($titleFont, $labelFont, $valueFont, $stampFont)
        $fmt = [System.Drawing.StringFormat]::GenericTypographic
        $fmt.FormatFlags = $fmt.FormatFlags -bor [System.Drawing.StringFormatFlags]::MeasureTrailingSpaces

        $title = $env:COMPUTERNAME
        $rows = foreach ($key in $data.Keys) {
            $values = @($data[$key]) | Where-Object { $_ }
            if (-not $values) { $values = @('-') }
            $first = $true
            foreach ($v in $values) {
                $text = [string]$v
                $warn = $text.StartsWith('!')
                if ($warn) { $text = $text.Substring(1) }
                [pscustomobject]@{ Label = $(if ($first) { $key } else { '' }); Value = $text; Warn = $warn }
                $first = $false
            }
        }

        $lineH  = [Math]::Ceiling($valueFont.GetHeight($g) * 1.25)
        $titleH = [Math]::Ceiling($titleFont.GetHeight($g) * 1.15)
        $labelW = ($rows | ForEach-Object { $g.MeasureString($_.Label, $labelFont, 2000, $fmt).Width } | Measure-Object -Maximum).Maximum
        $valueW = ($rows | ForEach-Object { $g.MeasureString($_.Value, $valueFont, 2000, $fmt).Width } | Measure-Object -Maximum).Maximum
        $titleW = $g.MeasureString($title, $titleFont, 4000, $fmt).Width

        $stamp  = 'Updated ' + (Get-Date).ToString('yyyy-MM-dd HH:mm')
        $stampW = $g.MeasureString($stamp, $stampFont, 2000, $fmt).Width
        $stampH = [Math]::Ceiling($stampFont.GetHeight($g) * 1.4)

        $pad = [Math]::Ceiling($size * 1.6)
        $gap = [Math]::Ceiling($size * 1.4)
        $panelW = [Math]::Ceiling([Math]::Max($labelW + $gap + $valueW, $titleW)) + $pad * 2
        $panelH = $titleH + [Math]::Ceiling($lineH * 0.4) + $lineH * @($rows).Count + $stampH + $pad * 2

        # Top-right of the usable area (taskbar excluded), in image coordinates.
        $x = ($work.Right - $bounds.Left) - $margin - $panelW
        $y = ($work.Top - $bounds.Top) + $margin

        $panelBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($PanelOpacity, 0, 0, 0))
        $titleBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $labelBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 150, 200, 255))
        $valueBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 235, 235, 235))
        $warnBrush  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 255, 190, 80))
        $rect = New-RoundedRectPath -X $x -Y $y -W $panelW -H $panelH -R ([Math]::Ceiling($size))
        try {
            $g.FillPath($panelBrush, $rect)
            $cy = [single]($y + $pad)
            $g.DrawString($title, $titleFont, $titleBrush, [single]($x + $pad), $cy, $fmt)
            $cy += $titleH + [Math]::Ceiling($lineH * 0.4)
            foreach ($row in $rows) {
                $g.DrawString($row.Label, $labelFont, $labelBrush, [single]($x + $pad), [single]$cy, $fmt)
                $brush = if ($row.Warn) { $warnBrush } else { $valueBrush }
                $g.DrawString($row.Value, $valueFont, $brush, [single]($x + $pad + $labelW + $gap), [single]$cy, $fmt)
                $cy += $lineH
            }
            $g.DrawString($stamp, $stampFont, $labelBrush, [single]($x + $panelW - $pad - $stampW), [single]($cy + $stampH * 0.3), $fmt)
        } finally {
            $rect.Dispose(); $panelBrush.Dispose(); $titleBrush.Dispose(); $labelBrush.Dispose(); $valueBrush.Dispose(); $warnBrush.Dispose()
        }

        $outDir = Split-Path -Parent $OutputPath
        if ($outDir) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
        $bmp.Save($OutputPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $fonts | ForEach-Object { $_.Dispose() }
        $g.Dispose()
        $bmp.Dispose()
    }
}

try {
    if ($Restore) {
        $state = Get-ItemProperty -Path $stateKey -ErrorAction SilentlyContinue
        if (-not $state) { Write-Verbose 'Nothing to restore.'; return }
        $path = if ($state.OriginalCopy -and (Test-Path -LiteralPath $state.OriginalCopy)) {
            # Put the copy somewhere stable, since uninstall may clear our folder later.
            $keep = Join-Path $env:APPDATA ('DeskInfo-original' + [IO.Path]::GetExtension($state.OriginalCopy))
            Copy-Item -LiteralPath $state.OriginalCopy -Destination $keep -Force
            $keep
        } else { '' }
        $style = if ($state.OriginalStyle) { $state.OriginalStyle } else { '10' }
        $tile  = if ($state.OriginalTile)  { $state.OriginalTile }  else { '0' }
        Set-Wallpaper -Path $path -Style $style -Tile $tile
        Remove-Item -Path $stateKey -Recurse -Force
        Remove-Item -Path $stateDir -Recurse -Force -ErrorAction SilentlyContinue
        return
    }

    $source = Get-OriginalWallpaper
    New-DeskInfoImage -Source $source
    if (-not $NoApply) { Set-Wallpaper -Path $OutputPath }
    "$(Get-Date -Format s) OK $OutputPath" | Set-Content -Path $logPath
} catch {
    # Usually runs hidden from a scheduled task, so leave a trail.
    "$(Get-Date -Format s) ERROR $($_.Exception.Message)`r`n$($_.ScriptStackTrace)" | Set-Content -Path $logPath -ErrorAction SilentlyContinue
    throw
}
