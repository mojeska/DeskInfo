<#
.SYNOPSIS
    Installs DeskInfo on local or remote Windows computers, refreshes it, or removes it.

.DESCRIPTION
    Copies DeskInfo.ps1 to C:\ProgramData\DeskInfo and registers a scheduled task named
    "DeskInfo" that runs it in each user's session at sign-in (and optionally every N minutes).
    It then starts the task, so signed-in users get the new wallpaper right away.

    Remote computers are reached over PowerShell remoting (WinRM), which is on by default on
    Windows Server. Run this as an account that is a local admin on the targets.

.EXAMPLE
    .\Deploy-DeskInfo.ps1
    Installs on this computer (run elevated).

.EXAMPLE
    .\Deploy-DeskInfo.ps1 -ComputerName SRV01, SRV02 -RefreshMinutes 60
    Installs on two servers, refreshing every hour as well as at sign-in.

.EXAMPLE
    .\Deploy-DeskInfo.ps1 -ComputerName SRV01 -Update
    Pushes the current DeskInfo.ps1 and runs it now. Keeps the existing schedule.

.EXAMPLE
    .\Deploy-DeskInfo.ps1 -ComputerName SRV01 -Uninstall
    Restores signed-in users' original wallpaper and removes DeskInfo.
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [pscredential]$Credential,

    # Also refresh every N minutes while users are signed in. 0 = only at sign-in.
    [Parameter(ParameterSetName = 'Install')]
    [ValidateRange(0, 1440)]
    [int]$RefreshMinutes = 0,

    [Parameter(ParameterSetName = 'Update', Mandatory)]
    [switch]$Update,

    [Parameter(ParameterSetName = 'Uninstall', Mandatory)]
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'DeskInfo.ps1'
$scriptText = if ($PSCmdlet.ParameterSetName -ne 'Uninstall') { Get-Content -Path $scriptPath -Raw } else { '' }

$remoteBlock = {
    param([string]$Action, [string]$ScriptText, [int]$RefreshMinutes)
    $ErrorActionPreference = 'Stop'
    $taskName = 'DeskInfo'
    $dir      = Join-Path $env:ProgramData 'DeskInfo'
    $target   = Join-Path $dir 'DeskInfo.ps1'
    $ps       = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $baseArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$target`""

    switch ($Action) {
        'Install' {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            # Admins and SYSTEM can change the folder; Users can only read and run it.
            & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' | Out-Null
            Set-Content -Path $target -Value $ScriptText -Encoding UTF8

            # Runs as whoever is signed in (members of local Users), in their own session.
            $users = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
            $principal = New-ScheduledTaskPrincipal -GroupId $users -RunLevel Limited
            $actionObj = New-ScheduledTaskAction -Execute $ps -Argument $baseArgs
            $triggers  = @(New-ScheduledTaskTrigger -AtLogOn)
            if ($RefreshMinutes -gt 0) {
                $repeat = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes $RefreshMinutes)
                $triggers += $repeat
            }
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -MultipleInstances IgnoreNew
            Register-ScheduledTask -TaskName $taskName -Action $actionObj -Trigger $triggers -Principal $principal `
                -Settings $settings -Description 'Draws system info on the desktop wallpaper.' -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
            'Installed'
        }
        'Update' {
            # Push the current DeskInfo.ps1 and run it. Triggers (and -RefreshMinutes) are left alone.
            if (-not (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue)) {
                throw 'DeskInfo is not installed here. Run Deploy-DeskInfo.ps1 without -Update first.'
            }
            Set-Content -Path $target -Value $ScriptText -Encoding UTF8
            Start-ScheduledTask -TaskName $taskName
            'Updated'
        }
        'Uninstall' {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if ($task) {
                # Run once more with -Restore so signed-in users get their old wallpaper back.
                Set-ScheduledTask -TaskName $taskName -Action (New-ScheduledTaskAction -Execute $ps -Argument "$baseArgs -Restore") | Out-Null
                Start-ScheduledTask -TaskName $taskName
                $deadline = (Get-Date).AddSeconds(30)
                Start-Sleep -Seconds 2
                while ((Get-ScheduledTask -TaskName $taskName).State -eq 'Running' -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Seconds 1
                }
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
            }
            Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
            'Removed'
        }
    }
}

$localNames = @('.', 'localhost', $env:COMPUTERNAME, "$env:COMPUTERNAME.$env:USERDNSDOMAIN")
$local  = @($ComputerName | Where-Object { $_ -in $localNames })
$remote = @($ComputerName | Where-Object { $_ -notin $localNames })
$argList = @($PSCmdlet.ParameterSetName, $scriptText, $RefreshMinutes)

if ($local) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw 'Run PowerShell as administrator to deploy on this computer.' }
    $result = & $remoteBlock @argList
    [pscustomobject]@{ ComputerName = $env:COMPUTERNAME; Result = $result }
}

if ($remote) {
    # One call fans out to all servers in parallel.
    $params = @{ ComputerName = $remote; ScriptBlock = $remoteBlock; ArgumentList = $argList; ErrorAction = 'Continue'; ErrorVariable = 'failed' }
    if ($Credential) { $params.Credential = $Credential }
    Invoke-Command @params | ForEach-Object {
        [pscustomobject]@{ ComputerName = $_.PSComputerName; Result = [string]$_ }
    }
    foreach ($err in $failed) {
        $name = if ($err.OriginInfo) { $err.OriginInfo.PSComputerName } else { $err.TargetObject }
        [pscustomobject]@{ ComputerName = $name; Result = "Failed: $($err.Exception.Message)" }
    }
}
