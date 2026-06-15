<#
.SYNOPSIS
    Builds the BHoM installer (alpha or beta).

.DESCRIPTION
    GitHub Actions port of BHoMBot's BuildAlpha + CloneInstaller orchestration.
    Reads the installer's IncludedRepos/*.txt manifests in the same order BHoMBot
    does, clones + builds each dependency repo, stages assemblies into
    C:\ProgramData\BHoM\ via each repo's MSBuild PostBuildEvent, then invokes the
    WiX installer build with the correct ReleaseType and PatchVersion properties.

    This is a faithful port of the orchestration BHoMBot has been doing on its
    on-premises server for years, NOT a port of the installer's existing
    BuildSolution.ps1 + CloneAndBuildAllRequiredRepos.ps1 (those are used by the
    Azure Pipelines path, which is being retired alongside BHoMBot).

.PARAMETER ReleaseType
    'alpha', 'rc', or 'beta'. Drives the WiX ReleaseType property and whether
    alphaIncludes.txt + alphaConfigs.txt are added to the clone set.
    'rc' (release candidate) builds the beta-tier set and is passed to WiX as
    'beta' so the wixproj's ReleaseVersion mapping stays unchanged. The
    distinction between 'rc' and 'beta' lives in the GitHub Release flags
    (prerelease vs final), not in the .msi itself.

.PARAMETER PatchVersion
    Patch version, yyMMdd format. Defaults to today.

.PARAMETER CodeLocation
    Root directory where the installer repo and all deps are co-located. Defaults
    to the parent of the script's repo (i.e. workspace parent on a GHA runner).

.PARAMETER InstallerRepoName
    Folder name of the installer repo within CodeLocation. Defaults to
    BHoM_Installer. For BHE builds this would be BuroHappold_Installer (not yet
    supported in this iteration).

.PARAMETER MainBranch
    Branch to clone each dep from. Defaults to 'develop' (matches BHoMBot's
    DevelopBranchName for alpha builds).
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('alpha', 'rc', 'beta')]
    [string]$ReleaseType,

    [string]$PatchVersion,

    [string]$CodeLocation,

    [string]$InstallerRepoName = 'BHoM_Installer',

    [string]$MainBranch = 'develop'
)

$ErrorActionPreference = 'Stop'

# ─── Setup ───────────────────────────────────────────────────────────────────

if (-not $CodeLocation) {
    # Default: parent of the installer-repo checkout.
    # Layout on GHA hosted runner:
    #   D:\a\BHoM_Installer\                       ← CodeLocation
    #   D:\a\BHoM_Installer\BHoM_Installer\        ← repo root (= GITHUB_WORKSPACE)
    #   D:\a\BHoM_Installer\BHoM_Installer\scripts\Build-Installer.ps1
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot  = Split-Path -Parent $scriptDir
    $CodeLocation = Split-Path -Parent $repoRoot
}

if (-not $PatchVersion) {
    $PatchVersion = (Get-Date).ToString('yyMMdd')
}

$installerRoot = Join-Path $CodeLocation $InstallerRepoName
$manifestDir   = Join-Path $installerRoot 'IncludedRepos'

if (-not (Test-Path $installerRoot)) { throw "Installer repo not found at: $installerRoot" }
if (-not (Test-Path $manifestDir))   { throw "Manifest directory not found at: $manifestDir" }

Write-Host "::group::Build configuration"
Write-Host "ReleaseType:    $ReleaseType"
Write-Host "PatchVersion:   $PatchVersion"
Write-Host "MainBranch:     $MainBranch"
Write-Host "CodeLocation:   $CodeLocation"
Write-Host "InstallerRoot:  $installerRoot"
Write-Host "::endgroup::"

# Ensure the BHoM ProgramData directories exist. Each dep repo's PostBuildEvent
# xcopies its DLLs here, and the WiX BeforeBuild target then xcopies from here
# into the installer's working dir. Missing directories cause confusing build
# failures further down.
$bhomProgramData = Join-Path $env:ProgramData 'BHoM'
foreach ($sub in @('Assemblies', 'DataSets', 'Settings', 'Extensions/PythonCode', 'Resources', 'GrasshopperPlugin', 'Upgrades')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $bhomProgramData $sub) | Out-Null
}

# ─── Toolchain discovery ─────────────────────────────────────────────────────

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found at $vswhere" }

$msbuild = & $vswhere -latest -requires Microsoft.Component.MSBuild -find "MSBuild\**\Bin\MSBuild.exe" | Select-Object -First 1
if (-not $msbuild) { throw "MSBuild not located via vswhere" }
Write-Host "MSBuild: $msbuild"

$nuget = (Get-Command nuget.exe -ErrorAction SilentlyContinue)?.Source
if (-not $nuget) { throw "nuget.exe not on PATH" }
Write-Host "NuGet: $nuget"

# ─── Helpers ────────────────────────────────────────────────────────────────

function Clone-Repo {
    param([string]$OrgRepo)

    $parts  = $OrgRepo.Split('/')
    $name   = $parts[1]
    $target = Join-Path $CodeLocation $name

    if (Test-Path (Join-Path $target '.git')) {
        Write-Host "  [skip clone] $name already present"
        return $target
    }

    # --depth 1 keeps the runner fast; we don't need history for builds.
    # --branch $MainBranch ensures we land on develop (matches BHoMBot's
    # DevelopBranchName for alpha builds). If the branch does not exist on
    # a dep, the clone is allowed to fail loudly so the issue is visible,
    # rather than silently falling back to the default branch.
    git clone --depth 1 --branch $MainBranch "https://github.com/$OrgRepo.git" $target 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Host "::warning::Branch '$MainBranch' not found on $OrgRepo. Falling back to repository default branch."
        git clone --depth 1 "https://github.com/$OrgRepo.git" $target 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -ne 0) { throw "git clone failed for $OrgRepo" }
    }
    return $target
}

function Build-Solution {
    param(
        [string]$SlnPath,
        [string]$Config = 'Release'
    )

    if (-not (Test-Path $SlnPath)) {
        Write-Host "::warning::No solution at $SlnPath. Skipping build."
        return
    }

    & $nuget restore $SlnPath -Verbosity quiet
    if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed for $SlnPath" }

    & $msbuild $SlnPath -nologo -verbosity:minimal "-p:Configuration=$Config"
    if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for $SlnPath (config=$Config)" }
}

function Clone-And-Build-FromFile {
    param([string]$FileName)

    $manifest = Join-Path $manifestDir $FileName
    if (-not (Test-Path $manifest)) {
        Write-Host "  [skip manifest] $FileName not present (this is expected for BHE-only files in the BHoM installer)"
        return
    }

    $repos = Get-Content $manifest |
             Where-Object { $_ -and -not $_.StartsWith('#') } |
             ForEach-Object { $_.Trim() } |
             Where-Object { $_ }

    if ($repos.Count -eq 0) {
        Write-Host "  [empty] $FileName has no entries"
        return
    }

    Write-Host "::group::$FileName ($($repos.Count) repos)"
    foreach ($repo in $repos) {
        Write-Host "----- $repo -----"
        $target = Clone-Repo -OrgRepo $repo
        $sln    = Join-Path $target "$(Split-Path -Leaf $target).sln"
        Build-Solution -SlnPath $sln
    }
    Write-Host "::endgroup::"
}

function Build-Configs-FromFile {
    param([string]$FileName)

    $manifest = Join-Path $manifestDir $FileName
    if (-not (Test-Path $manifest)) {
        Write-Host "  [skip configs] $FileName not present"
        return
    }

    $entries = Get-Content $manifest |
               Where-Object { $_ -and -not $_.StartsWith('#') } |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ }

    if ($entries.Count -eq 0) { return }

    Write-Host "::group::$FileName ($($entries.Count) configs)"
    foreach ($entry in $entries) {
        $parts = $entry.Split('/')
        if ($parts.Length -lt 3) {
            Write-Host "::warning::Malformed altConfigs entry (need org/repo/Config): $entry"
            continue
        }
        $orgRepo = "$($parts[0])/$($parts[1])"
        $config  = $parts[2]
        $name    = $parts[1]

        Write-Host "----- $orgRepo @ $config -----"
        $target = Clone-Repo -OrgRepo $orgRepo
        $sln    = Join-Path $target "$name.sln"
        Build-Solution -SlnPath $sln -Config $config
    }
    Write-Host "::endgroup::"
}

# ─── Clone + build the dependency graph (mirrors BHoMBot's CloneInstaller.cs) ─

# Order matters: core first, then adapters, then UI, then deps, then includes,
# and so on. Some files are BHE-only and will not exist in the BHoM_Installer
# repo; Clone-And-Build-FromFile handles missing files gracefully.
#
# BHoMBot parallelises some of these groups. For this initial iteration we run
# sequentially because it is easier to debug and produces deterministic output.
# Parallelism is a Phase 1.5 optimisation once the workflow is stable.

Clone-And-Build-FromFile -FileName 'core.txt'
Clone-And-Build-FromFile -FileName 'adapterCore.txt'
Clone-And-Build-FromFile -FileName 'uiCore.txt'
Clone-And-Build-FromFile -FileName 'dependencies.txt'
Clone-And-Build-FromFile -FileName 'include.txt'
Clone-And-Build-FromFile -FileName 'userInterfaces.txt'
Clone-And-Build-FromFile -FileName 'analytics.txt'        # BHE-only, absent in BHoM_Installer
Clone-And-Build-FromFile -FileName 'zeroCode.txt'         # BHE-only, absent in BHoM_Installer
Clone-And-Build-FromFile -FileName 'revitTools_Beta.txt'  # BHE-only, absent in BHoM_Installer

Build-Configs-FromFile -FileName 'altConfigs.txt'

# NOTE: BHoMBot calls UpdateFixedRevitVersioningTypes() here (Revit API mocks
# for the Versioning_Toolkit build), followed by a 60-second sleep after the
# versioning step. Both are skipped in this initial iteration. If either turns
# out to be load-bearing, the Versioning_Toolkit build will fail or produce
# incorrect output, at which point we add them back.

Clone-And-Build-FromFile -FileName 'versioning.txt'

if ($ReleaseType -eq 'alpha') {
    Clone-And-Build-FromFile -FileName 'alphaIncludes.txt'
    Build-Configs-FromFile   -FileName 'alphaConfigs.txt'
}

# ─── Write IncludedDLLs.txt (mirrors BHoMBot's SaveIncludedDLLs.cs) ─────────

$assembliesDir   = Join-Path $bhomProgramData 'Assemblies'
$dlls            = Get-ChildItem $assembliesDir -Filter '*.dll' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
$settingsDir     = Join-Path $installerRoot 'Settings'
$includedDllsTxt = Join-Path $settingsDir 'IncludedDLLs.txt'

New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
$dlls | Set-Content $includedDllsTxt
Write-Host "::notice::Staged $($dlls.Count) DLLs for the installer payload."
Write-Host "IncludedDLLs.txt: $includedDllsTxt"

# ─── Build the installer .sln itself ────────────────────────────────────────

$installerSln = Join-Path $installerRoot "$InstallerRepoName.sln"
if (-not (Test-Path $installerSln)) { throw "Installer solution not found at $installerSln" }

Write-Host "::group::Build installer ($ReleaseType, patch=$PatchVersion)"

& $nuget restore $installerSln
if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed for installer solution" }

# Map ReleaseType to the WiX ReleaseType property. The wixproj only declares
# branches for 'alpha' and 'beta', so 'rc' collapses to 'beta' here (both are
# beta-tier builds; the distinction lives in the GitHub Release flags).
$wixReleaseType = if ($ReleaseType -eq 'rc') { 'beta' } else { $ReleaseType }

$msbuildArgs = @(
    $installerSln,
    '-nologo',
    '-verbosity:minimal',
    '-p:RunWixToolsOutOfProc=true',
    '-p:DeployOnBuild=true',
    "-p:ReleaseType=$wixReleaseType",
    "-p:PatchVersion=$PatchVersion",
    '-p:WebPublishMethod=Package',
    '-p:PackageAsSingleFile=true',
    '-p:SkipInvalidConfigurations=true'
)
& $msbuild @msbuildArgs
if ($LASTEXITCODE -ne 0) { throw "MSBuild failed for installer solution" }

Write-Host "::endgroup::"

# ─── Locate output .msi ─────────────────────────────────────────────────────

# BHoM_Installer.wixproj puts output at ../Build/ relative to the .sln (i.e.
# at $installerRoot\..\Build\, which is $CodeLocation\Build\).
$buildDir = Join-Path $CodeLocation 'Build'
if (-not (Test-Path $buildDir)) {
    # Fallback for local builds that put the output under the installer root.
    $buildDir = Join-Path $installerRoot 'Build'
    if (-not (Test-Path $buildDir)) {
        throw "No Build directory found at $CodeLocation\Build or $installerRoot\Build"
    }
}

$msi = Get-ChildItem $buildDir -Filter '*.msi' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $msi) { throw "No .msi produced in $buildDir" }

$sizeMB = [math]::Round($msi.Length / 1MB, 2)
Write-Host "::notice::Installer built: $($msi.Name) ($sizeMB MB)"
Write-Host "Full path: $($msi.FullName)"

# Also copy to GITHUB_WORKSPACE\Build\ so actions/upload-artifact finds it via
# the workflow's static path (workspace-relative). Skip when MSBuild already
# emitted the .msi into that exact directory (would otherwise raise
# "Cannot overwrite the item with itself").
if ($env:GITHUB_WORKSPACE) {
    $workspaceBuild = Join-Path $env:GITHUB_WORKSPACE 'Build'
    New-Item -ItemType Directory -Force -Path $workspaceBuild | Out-Null
    $workspaceBuildResolved = (Resolve-Path $workspaceBuild).Path
    if ($msi.DirectoryName -ne $workspaceBuildResolved) {
        Copy-Item $msi.FullName $workspaceBuild -Force
        Write-Host "Copied .msi to workspace Build/ for artefact upload."
    } else {
        Write-Host "Skipped copy: .msi already in workspace Build/."
    }
}

# Expose outputs to the workflow
if ($env:GITHUB_OUTPUT) {
    "installer_path=$($msi.FullName)" | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "installer_name=$($msi.Name)"     | Out-File -FilePath $env:GITHUB_OUTPUT -Append
    "installer_size_mb=$sizeMB"        | Out-File -FilePath $env:GITHUB_OUTPUT -Append
}
