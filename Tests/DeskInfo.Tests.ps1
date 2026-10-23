# Quality gates plus real runs on a Windows runner: data collection, image rendering
# in Windows PowerShell 5.1 (what the scheduled task uses), and deploy parameter handling.

BeforeAll {
    $root     = Join-Path $PSScriptRoot '..'
    $deskInfo = Join-Path $root 'DeskInfo.ps1'
    $deploy   = Join-Path $root 'Deploy-DeskInfo.ps1'
}

Describe 'Script help' -ForEach @(
    @{ Name = 'DeskInfo.ps1' }
    @{ Name = 'Deploy-DeskInfo.ps1' }
) {
    BeforeAll { $help = Get-Help (Join-Path $PSScriptRoot "..\$Name") -Full }

    It '<Name> has a synopsis' { $help.Synopsis | Should -Not -BeNullOrEmpty }
    It '<Name> has a description' { $help.Description.Text | Should -Not -BeNullOrEmpty }
    It '<Name> has at least one example' { @($help.Examples.Example).Count | Should -BeGreaterThan 0 }
}

Describe 'PSScriptAnalyzer' {
    It 'reports no warnings or errors' {
        $settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
        $issues = foreach ($script in $deskInfo, $deploy) {
            Invoke-ScriptAnalyzer -Path $script -Severity Warning, Error -Settings $settings
        }
        $issues | ForEach-Object { Write-Host "$($_.ScriptName):$($_.Line) $($_.RuleName) $($_.Message)" }
        $issues | Should -BeNullOrEmpty
    }
}

Describe 'Get-DeskInfoData' -Skip:(-not $IsWindows) {
    BeforeAll {
        . $deskInfo
        $data = Get-DeskInfoData
    }

    It 'returns the expected fields in order' {
        @($data.Keys) | Should -Be @('User', 'Domain', 'Role', 'OS', 'Build', 'Installed', 'Last patch', 'Reboot',
            'IP', 'Gateway', 'DNS', 'CPU', 'Memory', 'Disks', 'Boot time', 'Uptime')
    }
    It 'reports a Windows OS and a numeric build' {
        $data['OS'] | Should -Match 'Windows'
        $data['Build'] | Should -Match '^\d+\.\d+$'
    }
    It 'always reports at least one role' {
        @($data['Role']).Count | Should -BeGreaterThan 0
    }
    It 'reports dates as yyyy-MM-dd' {
        $data['Installed'] | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $data['Boot time'] | Should -Match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$'
    }
    It 'reports pending reboot as No or a flagged Yes' {
        $data['Reboot'] | Should -Match '^(No|!Yes \(.+\))$'
    }
    It 'lists only IPv4 addresses, without link-local ones' {
        foreach ($ip in @($data['IP'])) {
            $ip | Should -Match '^\d+\.\d+\.\d+\.\d+$'
            $ip | Should -Not -BeLike '169.254.*'
        }
    }
    It 'lists at least one fixed disk' {
        @($data['Disks'])[0] | Should -Match '^[A-Z]:  [\d,]+ GB free of [\d,]+ GB$'
    }
}

Describe 'Rendering in Windows PowerShell 5.1' -Skip:(-not $IsWindows) {
    It 'writes a PNG without changing the wallpaper' {
        $out = Join-Path $TestDrive 'preview.png'
        $before = (Get-ItemProperty 'HKCU:\Control Panel\Desktop').Wallpaper

        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $deskInfo -NoApply -OutputPath $out
        $LASTEXITCODE | Should -Be 0
        Test-Path $out | Should -BeTrue

        Add-Type -AssemblyName System.Drawing
        $img = [System.Drawing.Image]::FromFile($out)
        try {
            $img.Width | Should -BeGreaterThan 0
            $img.Height | Should -BeGreaterThan 0
        } finally { $img.Dispose() }

        (Get-ItemProperty 'HKCU:\Control Panel\Desktop').Wallpaper | Should -Be $before
    }
}

Describe 'Deploy-DeskInfo.ps1 parameters' {
    It 'rejects -Update and -Uninstall together' {
        { & $deploy -Update -Uninstall } | Should -Throw '*Parameter set cannot be resolved*'
    }
    It 'rejects -RefreshMinutes with -Update' {
        { & $deploy -RefreshMinutes 60 -Update } | Should -Throw '*Parameter set cannot be resolved*'
    }
    It 'rejects a refresh interval over a day' {
        { & $deploy -RefreshMinutes 2000 } | Should -Throw '*2000*'
    }
}
