# DeskInfo

[![CI](https://github.com/mojeska/DeskInfo/actions/workflows/ci.yml/badge.svg)](https://github.com/mojeska/DeskInfo/actions/workflows/ci.yml)

A BGInfo-style wallpaper. It draws computer name, server role (DC, Veeam, DNS, DHCP, CA, IIS, Hyper-V, SQL), OS and build, install date, last patch, pending reboot, IPs, gateway, DNS, CPU, memory, disks, boot time and uptime in the top-right corner, and it can be deployed to remote servers over WinRM. Plain PowerShell: no install, no compiled binary.

## Deploy

Install on remote servers (local admin on the targets; WinRM is on by default on Windows Server):

```powershell
.\Deploy-DeskInfo.ps1 -ComputerName SRV01, SRV02
```

Same, but also refresh hourly while users are signed in:

```powershell
.\Deploy-DeskInfo.ps1 -ComputerName SRV01, SRV02 -RefreshMinutes 60
```

Install on this machine (elevated prompt):

```powershell
.\Deploy-DeskInfo.ps1
```

Push a new version of `DeskInfo.ps1` and refresh now. This keeps the existing `-RefreshMinutes` schedule; running the install again without it would remove the schedule:

```powershell
.\Deploy-DeskInfo.ps1 -ComputerName SRV01 -Update
```

Remove it and give signed-in users their old wallpaper back:

```powershell
.\Deploy-DeskInfo.ps1 -ComputerName SRV01 -Uninstall
```

Use different credentials:

```powershell
.\Deploy-DeskInfo.ps1 -ComputerName SRV01 -Credential (Get-Credential)
```

## Run once by hand (no install)

Apply to your own session:

```powershell
.\DeskInfo.ps1
```

Preview only, without changing the wallpaper:

```powershell
.\DeskInfo.ps1 -NoApply -OutputPath C:\Temp\preview.png
```

Put your own wallpaper back:

```powershell
.\DeskInfo.ps1 -Restore
```

Change the look (all optional): `-FontName`, `-FontSize` (default 11), `-PanelOpacity` (0–255, default 150), `-Margin` (pixels), and `-BackgroundColor` (used when the desktop has no wallpaper).

To add, remove or reorder fields, edit the `[ordered]@{ ... }` table at the end of `Get-DeskInfoData` in `DeskInfo.ps1`. Start a value with `!` to draw it in the warning color (used for a pending reboot). To detect more roles, add a service name to `$roleMap`.

## How it works

- `Deploy-DeskInfo.ps1` copies `DeskInfo.ps1` to `C:\ProgramData\DeskInfo`. Admins can write there; Users can only read.
- It registers a scheduled task named **DeskInfo**. The task runs as the local **Users** group, so it runs in each user's own session at sign-in. Wallpaper is per user, which is why it can't simply run as SYSTEM.
- `DeskInfo.ps1` copies the user's current wallpaper to `%LOCALAPPDATA%\DeskInfo`, draws the panel on top at the primary screen's real resolution (DPI-aware, below a top taskbar if there is one), saves `wallpaper.png` and sets it.
- If the user later picks a different wallpaper, the next run uses that one as the new background.
- If a run fails, the error is written to `%LOCALAPPDATA%\DeskInfo\last-run.log`, since the task runs hidden.

## Limits

- The panel is placed for the **primary monitor**. Other monitors get the same image.
- A PowerShell window may flash briefly at sign-in.
- After `-Uninstall`, users who weren't signed in keep the last generated wallpaper until they change it.
- Group Policy wallpaper settings override this.

## Tests

Run the Pester tests (Pester 5+ and PSScriptAnalyzer). CI runs them on a Windows runner on every push:

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```
