# Run by tests/Repo.Tests.ps1 through Test-Kit.ps1 -TestPath. It is not named *.Tests.ps1, so the normal gate never picks it up.
Describe 'git location variables during the test run' {
    It 'clears <Name>' -ForEach @(
        @{ Name = 'GIT_DIR' }
        @{ Name = 'GIT_INDEX_FILE' }
        @{ Name = 'GIT_WORK_TREE' }
        @{ Name = 'GIT_PREFIX' }
    ) {
        [Environment]::GetEnvironmentVariable($Name) | Should -BeNullOrEmpty
    }
}
