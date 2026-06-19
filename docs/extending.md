# Extending BHoM_Installer

`BHoM_Installer` is the canonical open-source installer pipeline for the BHoM
ecosystem. It is designed to be **forked or extended by other organisations**
(e.g. BuroHappold Engineering's private `BuroHappold_Installer`, or any
third-party firm building on BHoM) without requiring changes to the upstream
shared workflows.

## The org isolation principle

BHoM-org shared workflows MUST NOT name BHE-specific (or any other org's)
repos directly. Org-specific repos are surfaced as **inputs with neutral
defaults**; extending orgs override those inputs in their own proxies or
workflow dispatches.

This principle applies to:

- `BHoM_Installer/.github/workflows/build-installer.yml`
- `BHoM_Installer/.github/workflows/versioning-full-history.yml`
- `BuroHappoldEngineeringAdmin/CI_Toolkit/.github/workflows/ci-*.yml`

It is what allows BHoM to remain an open-source-first org with clear
governance while still letting BHE (and other extenders) build on top
without requiring upstream PRs whenever their internal infrastructure
changes.

## Extension points

| Input | Workflow(s) | Default | Use when |
|---|---|---|---|
| `versioning_toolkit_repo` | `ci-versioning.yml`, `versioning-full-history.yml` | `BHoM/Versioning_Toolkit` | Your org has its own Versioning_Toolkit fork |
| `test_toolkit_repo` | `ci-versioning.yml`, `versioning-full-history.yml`, `ci-serialisation.yml` | `BHoM/Test_Toolkit` | Your org has its own Test_Toolkit fork |
| `additional_dataset_repos` | `ci-versioning.yml`, `versioning-full-history.yml` | `''` | Your org has private dataset sources to validate alongside BHoM's |
| `dependency_branch` | `build-installer.yml` | `develop` | Building against a feature branch across deps |

## Worked example: Revit API mocks

`Versioning_Test.dll` reflects over BHoM toolkit assemblies, including
Revit-versioned ones (`Revit_*20XX.dll`). Reflection requires the Revit
API types (`Autodesk.Revit.DB.*`) to be resolvable at load time. Autodesk
licensing on `RevitAPI.dll` prevents BHoM from shipping a mock alongside
the open-source installer, so BHoM-org versioning workflows skip Revit-
typed datasets with an infrastructure-skip warning.

Extending orgs that maintain their own Revit API mock surfaces (e.g. an
internal `RevitAPIMock` repo) wire them in via `additional_dataset_repos`:

```yaml
# In your private proxy's workflow_dispatch or in build-installer.yml
# input defaults for your fork:
inputs:
  additional_dataset_repos: |
    YourOrg/RevitAPIMock
```

The shared workflow then clones that repo, builds its
`.ci/code/Verification.sln`, and the resulting mock DLLs populate
`C:\ProgramData\BHoM\Assemblies` before `VersioningRunner` reflects over
the Revit-versioned types — giving your org full Revit-versioning coverage
without changing anything upstream.

## Anti-pattern: do not add org-specific defaults to shared workflows

Do not:

- Change defaults to `versioning_toolkit_repo: 'YourOrg/Foo'` in the shared
  workflow file
- Hardcode private repo URLs in clone steps
- Add conditional logic that checks for a specific org by name

Each of those couples the shared workflow to an extending org's internal
state and defeats the isolation principle. Use the existing inputs.

If a new extension point is needed (e.g. a different dataset source not
covered by `additional_dataset_repos`), add a new input with a neutral
default and update this document to describe it.
