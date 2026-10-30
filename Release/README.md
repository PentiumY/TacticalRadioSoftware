# Tactical Radio release pipeline

Windows PowerShell 5.1+; Visual Studio 2022, CMake, Inno Setup 6 and GitHub CLI for publishing.

Place `Release/` in `TacticalRadioSoftware/`. Default layout assumes sibling repositories:

```text
Github/
  TacticalRadioSoftware/
    Release/
    apps/mumble-plugin/build/
    dist/
  TRS-Mumble/
    build-2026/
```

Both CMake projects must already be configured on the builder. TRS-Mumble uses your existing static Qt/vcpkg toolchain. Build scripts **build existing configurations**; they deliberately do not guess toolchains or download dependencies. `mumble.exe` and the radio plugin must be valid Windows x64 binaries.

## Local build

From `TacticalRadioSoftware`:

```powershell
.\Release\build.ps1 -Version 1.1.0
```

Override paths if necessary:

```powershell
.\Release\build.ps1 -Version 1.1.0 -MumbleRepo "C:\dev\TRS-Mumble" -MumbleBuildDir "C:\dev\TRS-Mumble\build-2026"
```

To stage previously compiled binaries:

```powershell
.\Release\build.ps1 -Version 1.1.0 -SkipMumbleBuild -SkipPluginBuild
```

Outputs:

- `dist/portable/TRS-Mumble/` - portable client and plugin
- `dist/installer/TacticalRadioSetup-1.1.0.exe` - installer
- `dist/installer/TacticalRadioSetup-1.1.0.manifest.json` - Git commits and SHA-256 checksums

`build.ps1` does not commit, push, or publish anything. It rejects uncommitted tracked changes unless `-AllowDirty` is specified (for local testing only).

## Test before publishing

1. Test launching the portable app from its staging location.
2. Test the installer on a clean Windows VM without normal Mumble; confirm dependencies and VC++ runtime availability.
3. Test upgrading an old Tactical Radio installation, including old launcher removal and plugin cleanup.
4. Confirm regular Mumble still works, and that no second Tactical Radio plugin is loaded there.
5. Confirm `%APPDATA%\TRS-Mumble\radio.json` is preserved and session discovery works against your bridge.
6. Confirm uninstall removes the app while leaving regular Mumble untouched.

**Note:** Only the DLLs shown in the working local portable build are staged. Verify Windows runtime dependencies on a clean VM; if additional runtime assets are needed, place them in `build-2026/distribution-extra/` before building, or extend the staging script. The build does not promise runtime compatibility solely from checking files.

**Note:** Legacy `{app}\config.json` is retained to avoid losing settings. Plan a migration or a user-approved cleanup before removing it in a later release. The new `%APPDATA%\TRS-Mumble\radio.json` is also left untouched. Existing users of the old updater must be checked to ensure its version-check and installer launch behavior still accepts this release.

**Note:** The plugin defaults to localhost if no radio settings exist. For public users, configure your bridge URL in the custom client's settings or provide an appropriate first-run setup flow; this pipeline does not silently hardcode a developer IP address.

## Publish the exact tested binary

```powershell
.\Release\publish.ps1 -Version 1.1.0
```

Requires `gh auth login`. Publisher verifies installer hash, source commit, and uniqueness of the release tag. It does not rebuild the installer. It pushes the checked-out branch and tag to `PentiumY/TacticalRadioSoftware` and creates a release with both `.exe` and `.manifest.json` assets.

Use `-Draft` to publish a draft. Before publishing, ensure your version is higher than the existing latest public release.

## Migration / ownership

- Reuses legacy Inno Setup AppId `{C4A7A0D7-42EA-4B2D-95C6-D65FD9A2EFBE}` for per-user upgrades.
- Installs to `%LOCALAPPDATA%\TacticalRadio` (same path as legacy).
- Removes known old Tactical Radio plugin names from regular Mumble's plugin folder; **does not uninstall or modify the regular Mumble executable**.
- Does not delete `%APPDATA%\TRS-Mumble\radio.json`.
- Does not ship the legacy WinUI launcher or Windows App Runtime prerequisites.
- Existing per-user installs should be upgraded in the same Windows user account.

## Source files

- `build.ps1`: end-to-end local compiler + distribution + installer
- `publish.ps1`: hash/commit-checked GitHub publication
- `scripts/BuildMumble.ps1`: Mumble build
- `scripts/BuildPlugin.ps1`: radio plugin build
- `scripts/StageDistribution.ps1`: portable folder
- `scripts/ValidateDistribution.ps1`: basic package integrity
- `scripts/GenerateManifest.ps1`: deterministic file hashes and source revisions
- `installer/TRS-Mumble.iss`: standalone per-user Windows installer

This is a local, CI-ready workflow, not a configured GitHub Actions workflow. GitHub Actions would require a Windows runner with the TRS-Mumble toolchain and access to both repositories.
