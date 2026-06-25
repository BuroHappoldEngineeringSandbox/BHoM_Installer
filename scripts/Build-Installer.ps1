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
    'alpha', 'alpha-beta', or 'beta'. Drives the WiX ReleaseType property and
    whether alphaIncludes.txt + alphaConfigs.txt are added to the clone set.
    'alpha-beta' (release candidate) and 'beta' (shipped) both build the beta-tier
    set and are passed to WiX as 'beta' so the wixproj's two-configuration scheme
    (alpha / beta) is preserved. The distinction between 'alpha-beta' and 'beta'
    lives in the GitHub Release flags (prerelease=true vs prerelease=false) and the tag form,
    not in the .msi itself.

.PARAMETER PatchVersion
    Patch version, yyMMdd format. Defaults to today.

.PARAMETER CodeLocation
    Root directory where the installer repo and all deps are co-located. Defaults
    to the parent of the script's repo (i.e. workspace parent on a GHA runner).

.PARAMETER InstallerRepoName
    Folder name of the installer repo within CodeLocation. Defaults to
    BHoM_Installer.

.PARAMETER DependencyBranch
    Branch to try first on each dependency repo clone. Falls back to each
    dep's actual default branch (the GitHub default, whatever that is)
    when the requested branch is not present.
    Defaults to 'develop'. Pass an empty string to skip the try-first step
    entirely and clone each dep at its own default branch.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('alpha', 'alpha-beta', 'beta')]
    [string]$ReleaseType,

    [string]$PatchVersion,

    [string]$CodeLocation,

    [string]$InstallerRepoName = 'BHoM_Installer',

    [string]$DependencyBranch = 'develop'
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
Write-Host "ReleaseType:       $ReleaseType"
Write-Host "PatchVersion:      $PatchVersion"
Write-Host "DependencyBranch:  $DependencyBranch"
Write-Host "CodeLocation:      $CodeLocation"
Write-Host "InstallerRoot:     $installerRoot"
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

    # Two-step clone: try the requested DependencyBranch first; on failure
    # (branch absent on this dep), fall back to that dep's actual GitHub
    # default branch by cloning without --branch. When DependencyBranch is
    # empty, skip the try-first step and go straight to the default-branch
    # clone (workflow passes empty when no specific branch is requested).
    if ($DependencyBranch) {
        git clone --depth 1 --branch $DependencyBranch "https://github.com/$OrgRepo.git" $target 2>&1 | ForEach-Object { Write-Host "  $_" }
        if ($LASTEXITCODE -eq 0) { return $target }
        Write-Host "::warning::Branch '$DependencyBranch' not found on $OrgRepo. Falling back to repository default branch."
    }
    git clone --depth 1 "https://github.com/$OrgRepo.git" $target 2>&1 | ForEach-Object { Write-Host "  $_" }
    if ($LASTEXITCODE -ne 0) { throw "git clone failed for $OrgRepo" }
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

function Build-ManifestFile {
    # Clone-and-build the repos listed in an IncludedRepos manifest. Two line
    # formats supported, selected by the -WithConfig switch:
    #
    #   default (org/repo):          one repo per line, builds the repo's
    #                                <name>.sln at the default 'Release' config.
    #                                Used by core.txt, dependencies.txt, etc.
    #
    #   -WithConfig (org/repo/Cfg):  one repo per line plus an MSBuild config
    #                                suffix. Builds <name>.sln at the named
    #                                config. Used by altConfigs.txt, which
    #                                exists to build alternate WiX-target
    #                                configurations of the same repo
    #                                (e.g. Revit_Toolkit / Release2024).
    #
    # Lines beginning with '#' are ignored. Trims surrounding whitespace.
    # Missing manifest file is a soft skip — surfaces the gap without failing
    # the build, since manifests evolve and a renamed/removed file should not
    # break the dispatch.
    param(
        [string]$FileName,
        [switch]$WithConfig
    )

    $manifest = Join-Path $manifestDir $FileName
    if (-not (Test-Path $manifest)) {
        Write-Host "  [skip manifest] $FileName not present in IncludedRepos/"
        return
    }

    $entries = Get-Content $manifest |
               Where-Object { $_ -and -not $_.StartsWith('#') } |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ }

    if ($entries.Count -eq 0) {
        Write-Host "  [empty] $FileName has no entries"
        return
    }

    $kind = if ($WithConfig) { 'configs' } else { 'repos' }
    Write-Host "::group::$FileName ($($entries.Count) $kind)"
    foreach ($entry in $entries) {
        if ($WithConfig) {
            $parts = $entry.Split('/')
            if ($parts.Length -lt 3) {
                Write-Host "::warning::Malformed $FileName entry (need org/repo/Config): $entry"
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
        else {
            Write-Host "----- $entry -----"
            $target = Clone-Repo -OrgRepo $entry
            $sln    = Join-Path $target "$(Split-Path -Leaf $target).sln"
            Build-Solution -SlnPath $sln
        }
    }
    Write-Host "::endgroup::"
}

# ─── Clone + build the dependency graph (mirrors BHoMBot's CloneInstaller.cs) ─

# Order matters: core first, then adapters, then UI, then deps, then includes,
# and so on. Missing manifests are soft-skipped by Build-ManifestFile.
#
# Sequential by design. BHoMBot parallelised some manifest groups to fit its
# single-machine nightly window with multiple competing timers; ephemeral
# cloud runners have no such constraint. Linear builds give traceable logs,
# deterministic failure modes, and no race-on-DLL-output risk. Parallelism
# remains available as an optimisation if wall-clock ever becomes a real
# bottleneck, but is not currently warranted.

$manifests = @(
    @{ File = 'core.txt' }
    @{ File = 'adapterCore.txt' }
    @{ File = 'uiCore.txt' }
    @{ File = 'dependencies.txt' }
    @{ File = 'include.txt' }
    @{ File = 'userInterfaces.txt' }

    @{ File = 'altConfigs.txt'; WithConfig = $true }

    # NOTE: BHoMBot calls UpdateFixedRevitVersioningTypes() here (Revit API mocks
    # for the Versioning_Toolkit build), followed by a 60-second sleep after the
    # versioning step. Both are skipped in this initial iteration. If either turns
    # out to be load-bearing, the Versioning_Toolkit build will fail or produce
    # incorrect output, at which point we add them back.

    @{ File = 'versioning.txt' }
)

foreach ($entry in $manifests) {
    $splat = @{ FileName = $entry.File }
    if ($entry.WithConfig) { $splat.WithConfig = $true }
    Build-ManifestFile @splat
}

if ($ReleaseType -eq 'alpha') {
    Build-ManifestFile -FileName 'alphaIncludes.txt'
    Build-ManifestFile -FileName 'alphaConfigs.txt' -WithConfig
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

# ─── Write IncludedDatasets.txt (mirrors BHoMBot's SaveIncludedDatasets.cs) ─

$datasetsDir         = Join-Path $bhomProgramData 'Datasets'
$includedDatasetsTxt = Join-Path $settingsDir 'IncludedDatasets.txt'

$datasets = Get-ChildItem $datasetsDir -Recurse -Filter '*.json' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $_.FullName.Replace("$datasetsDir\", '').Replace('.json', '')
            }

$datasets | Set-Content $includedDatasetsTxt
Write-Host "::notice::Recorded $($datasets.Count) datasets in IncludedDatasets.txt"
Write-Host "IncludedDatasets.txt: $includedDatasetsTxt"

# ─── Build the installer .sln itself ────────────────────────────────────────

$installerSln = Join-Path $installerRoot "$InstallerRepoName.sln"
if (-not (Test-Path $installerSln)) { throw "Installer solution not found at $installerSln" }

Write-Host "::group::Build installer ($ReleaseType, patch=$PatchVersion)"

& $nuget restore $installerSln
if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed for installer solution" }

# Map ReleaseType to the WiX ReleaseType property. The wixproj only declares
# Configurations for 'alpha' and 'beta', so 'alpha-beta' collapses to 'beta'
# here (release-candidate builds use the beta-tier set; the distinction
# between alpha-beta and beta lives in the GitHub Release flags and the tag
# form rather than the .msi).
$wixReleaseType = switch ($ReleaseType) {
    'alpha-beta' { 'beta' }
    default      { $ReleaseType }
}

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
