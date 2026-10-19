BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\kit\core\Kit.Core.psd1') -Force

    $script:isoScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\builder\iso\New-BaselineIso.ps1'))
    $script:installerScript = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\kit\Install-DriverBaseline.ps1'))
    $script:expectedCommand = 'cmd.exe /c powershell.exe -NoProfile -ExecutionPolicy Bypass -File %SystemDrive%\Kit\Install-DriverBaseline.ps1 -PackagePath %SystemDrive%\Kit\package -LogPath %SystemDrive%\Kit\firstboot.log'

    function Read-ScriptAst {
        param([Parameter(Mandatory)][string]$Path)
        $tokens = $null
        $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    }

    $script:isoAst = Read-ScriptAst -Path $script:isoScript
    $script:installerAst = Read-ScriptAst -Path $script:installerScript

    # The ISO script needs admin and a real ISO, so it is never run. Its two helper functions are defined here
    # from their own source text and tested alone; neither may read a script-scope variable.
    foreach ($functionName in 'Add-FirstBootRun', 'Read-PackageManifest') {
        $definition = $script:isoAst.Find({
                param($node)
                $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
            }, $true)
        $definition | Should -Not -BeNullOrEmpty -Because "$functionName must be defined in builder/iso/New-BaselineIso.ps1"
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    # Report every -Name token after the installer path that the installer's param block cannot bind, and every
    # mandatory installer parameter the command does not supply.
    function Get-CommandBindingProblem {
        param([Parameter(Mandatory)][string]$Command)
        $tokens = @($Command -split '\s+' | Where-Object { $_ })
        $scriptIndex = -1
        for ($i = 0; $i -lt $tokens.Count; $i++) {
            if ($tokens[$i] -like '*Install-DriverBaseline.ps1') { $scriptIndex = $i }
        }
        if ($scriptIndex -lt 0) { return @('Install-DriverBaseline.ps1 is not in the command') }

        $known = @{}
        $mandatory = @()
        foreach ($parameter in $script:installerAst.ParamBlock.Parameters) {
            $name = $parameter.Name.VariablePath.UserPath
            $known[$name] = $name
            foreach ($attribute in $parameter.Attributes) {
                if ($attribute.TypeName.Name -eq 'Alias') {
                    foreach ($alias in $attribute.PositionalArguments) { $known[$alias.Value] = $name }
                }
                if ($attribute.TypeName.Name -eq 'Parameter') {
                    foreach ($argument in $attribute.NamedArguments) {
                        if ($argument.ArgumentName -eq 'Mandatory' -and ($argument.ExpressionOmitted -or $argument.Argument.Extent.Text -eq '$true')) {
                            $mandatory += $name
                        }
                    }
                }
            }
        }
        foreach ($common in 'Verbose', 'Debug', 'ErrorAction', 'WarningAction', 'InformationAction', 'ErrorVariable', 'WarningVariable',
            'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'WhatIf', 'Confirm') {
            $known[$common] = $common
        }

        $supplied = @()
        $problems = @()
        foreach ($token in $tokens[($scriptIndex + 1)..($tokens.Count - 1)]) {
            if ($token -match '^-([A-Za-z]+):?$') {
                $given = $Matches[1]
                if ($known.ContainsKey($given)) { $supplied += $known[$given] } else { $problems += $given }
            }
        }
        foreach ($name in $mandatory) {
            if ($name -notin $supplied) { $problems += $name }
        }
        @($problems)
    }

    function Get-FileRelativeList {
        param([Parameter(Mandatory)][string]$Root)
        $rootFull = (Resolve-Path -LiteralPath $Root).Path.TrimEnd('\')
        @(Get-ChildItem -LiteralPath $Root -Recurse -File | ForEach-Object { $_.FullName.Substring($rootFull.Length + 1) })
    }
}

Describe 'First-boot staging' {
    BeforeAll {
        $script:kit = Join-Path $TestDrive 'kit'
        foreach ($relative in 'Run.cmd', 'Install-DriverBaseline.ps1', 'core\a.ps1', 'config.example.psd1', 'config.local.psd1', 'results\serial.txt') {
            $file = Join-Path $script:kit $relative
            $null = New-Item -Path (Split-Path -Path $file -Parent) -ItemType Directory -Force
            Set-Content -LiteralPath $file -Value 'x'
        }
        $script:package = Join-Path $TestDrive 'package'
        foreach ($relative in 'manifest.json', 'Drivers\d.inf', 'Firmware\sp000001\f.exe') {
            $file = Join-Path $script:package $relative
            $null = New-Item -Path (Split-Path -Path $file -Parent) -ItemType Directory -Force
            Set-Content -LiteralPath $file -Value 'x'
        }
    }

    Context 'a clean image' {
        BeforeAll {
            $script:image = Join-Path $TestDrive 'image-clean'
            $null = New-Item -Path $script:image -ItemType Directory
            Add-FirstBootRun -ImageRoot $script:image -PackagePath $script:package -KitRoot $script:kit
            $script:staged = @(Get-FileRelativeList -Root $script:image)
        }
        It 'stages the publishable kit files under Kit' {
            $script:staged | Should -Contain 'Kit\Run.cmd'
            $script:staged | Should -Contain 'Kit\Install-DriverBaseline.ps1'
            $script:staged | Should -Contain 'Kit\core\a.ps1'
            $script:staged | Should -Contain 'Kit\config.example.psd1'
        }
        It 'stages the package manifest and Firmware under Kit\package' {
            $script:staged | Should -Contain 'Kit\package\manifest.json'
            $script:staged | Should -Contain 'Kit\package\Firmware\sp000001\f.exe'
        }
        It 'never stages the local settings file or a results folder' {
            @($script:staged | Where-Object { $_ -match '\.local\.psd1$' }) | Should -BeNullOrEmpty
            @($script:staged | Where-Object { $_ -match '(^|\\)results(\\|$)' }) | Should -BeNullOrEmpty
            Get-ChildItem -LiteralPath $script:image -Recurse -Directory | Where-Object Name -EQ 'results' | Should -BeNullOrEmpty
        }
        It 'does not stage the Drivers folder (they are injected offline)' {
            Get-ChildItem -LiteralPath $script:image -Recurse -Directory | Where-Object Name -EQ 'Drivers' | Should -BeNullOrEmpty
            @($script:staged | Where-Object { $_ -match 'd\.inf$' }) | Should -BeNullOrEmpty
        }
        It 'writes the answer file under Windows\Panther' {
            Join-Path $script:image 'Windows\Panther\unattend.xml' | Should -Exist
        }
    }

    Context 'an image that already has an answer file' {
        BeforeAll {
            $script:busyImage = Join-Path $TestDrive 'image-busy'
            $answer = Join-Path $script:busyImage 'Windows\Panther\unattend.xml'
            $null = New-Item -Path (Split-Path -Path $answer -Parent) -ItemType Directory -Force
            Set-Content -LiteralPath $answer -Value '<unattend/>'
        }
        It 'refuses to overwrite it' {
            { Add-FirstBootRun -ImageRoot $script:busyImage -PackagePath $script:package -KitRoot $script:kit } | Should -Throw '*refusing to overwrite*'
        }
        It 'copies nothing before refusing' {
            Join-Path $script:busyImage 'Kit' | Should -Not -Exist
        }
    }
}

Describe 'Answer file binds to the installer' {
    BeforeAll {
        $script:kit = Join-Path $TestDrive 'bind-kit'
        $null = New-Item -Path $script:kit -ItemType Directory
        Set-Content -LiteralPath (Join-Path $script:kit 'Run.cmd') -Value 'x'
        $script:package = Join-Path $TestDrive 'bind-package'
        $null = New-Item -Path $script:package -ItemType Directory
        Set-Content -LiteralPath (Join-Path $script:package 'manifest.json') -Value '{}'
        $script:image = Join-Path $TestDrive 'bind-image'
        $null = New-Item -Path $script:image -ItemType Directory
        Add-FirstBootRun -ImageRoot $script:image -PackagePath $script:package -KitRoot $script:kit
        $answer = [xml](Get-Content -LiteralPath (Join-Path $script:image 'Windows\Panther\unattend.xml') -Raw)
        $script:writtenCommand = [string]$answer.unattend.settings.component.RunSynchronous.RunSynchronousCommand.Path
    }
    It 'runs the documented first-boot command' {
        $script:writtenCommand | Should -BeExactly $script:expectedCommand
    }
    It 'binds every name it passes and supplies every mandatory parameter' {
        @(Get-CommandBindingProblem -Command $script:writtenCommand) | Should -BeNullOrEmpty
    }
    It 'reports a parameter the installer does not have' {
        @(Get-CommandBindingProblem -Command ($script:writtenCommand + ' -Bogus x')) | Should -Contain 'Bogus'
    }
    It 'reports a missing mandatory parameter' {
        $without = $script:writtenCommand.Replace(' -PackagePath %SystemDrive%\Kit\package', '')
        $without | Should -Not -Be $script:writtenCommand
        @(Get-CommandBindingProblem -Command $without) | Should -Contain 'PackagePath'
    }
}

Describe 'Package manifest guard' {
    BeforeAll {
        function Set-TestManifest {
            [CmdletBinding(SupportsShouldProcess)]
            param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Json)
            $folder = Join-Path $TestDrive $Name
            if (-not $PSCmdlet.ShouldProcess($folder, 'Write a test manifest')) { return }
            $null = New-Item -Path $folder -ItemType Directory -Force
            Set-Content -LiteralPath (Join-Path $folder 'manifest.json') -Value $Json
            $folder
        }
    }
    It 'returns Vendor and ModelId for a schema 2 manifest' {
        $folder = Set-TestManifest -Name 'm-ok' -Json '{ "SchemaVersion": 2, "Vendor": "Fixture", "ModelId": "m1" }'
        $manifest = Read-PackageManifest -PackagePath $folder
        $manifest.Vendor | Should -Be 'Fixture'
        $manifest.ModelId | Should -Be 'm1'
    }
    It 'refuses a schema 1 manifest and names Build.cmd' {
        $folder = Set-TestManifest -Name 'm-old' -Json '{ "SchemaVersion": 1, "Vendor": "Fixture", "ModelId": "m1" }'
        { Read-PackageManifest -PackagePath $folder } | Should -Throw '*Rebuild it with Build.cmd*'
    }
    It 'refuses a manifest with no schema version and names Build.cmd' {
        $folder = Set-TestManifest -Name 'm-none' -Json '{ "Vendor": "Fixture", "ModelId": "m1" }'
        { Read-PackageManifest -PackagePath $folder } | Should -Throw '*Rebuild it with Build.cmd*'
    }
}

Describe 'New-BaselineIso is vendor-neutral' {
    It 'names no vendor command' {
        $commands = $script:isoAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true) |
            ForEach-Object { $_.GetCommandName() } | Where-Object { $_ -match '-HP|HPCMSL' }
        @($commands) | Should -BeNullOrEmpty
    }
    It 'holds no vendor string constant' {
        $strings = $script:isoAst.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -or
                $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
            }, $true) | Where-Object { $_.Value -ceq 'HP' -or $_.Value -like '*HP_Staging*' -or $_.Value -like '*HP\Baseline*' }
        @($strings) | Should -BeNullOrEmpty
    }
    It 'requires -PackagePath' {
        $parameter = $script:isoAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PackagePath' }
        $parameter | Should -Not -BeNullOrEmpty
        $mandatory = @($parameter.Attributes | Where-Object { $_.TypeName.Name -eq 'Parameter' } |
                ForEach-Object { $_.NamedArguments } | Where-Object { $_.ArgumentName -eq 'Mandatory' })
        $mandatory | Should -Not -BeNullOrEmpty
        $parameter.DefaultValue | Should -BeNullOrEmpty
    }
    It 'defaults -WorkRoot under the staging folder next to the repo' {
        $parameter = $script:isoAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'WorkRoot' }
        $parameter.DefaultValue.Extent.Text | Should -BeLike '*$PSScriptRoot*'
        $parameter.DefaultValue.Extent.Text | Should -BeLike '*staging\_isobuild*'
    }
    It 'imports the common module by relative path and stages through the publish list' {
        $text = Get-Content -LiteralPath $script:isoScript -Raw
        $text | Should -Match ([regex]::Escape('kit\core\Kit.Core.psd1'))
        $text | Should -Match ([regex]::Escape('Get-KitPublishFile -Root'))
        $text | Should -Match ([regex]::Escape('-OfflineImagePath $dir'))
    }
}
