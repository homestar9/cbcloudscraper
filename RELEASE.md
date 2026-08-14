# Release cbcloudscraper

Use this guide to publish the CFML module and its Windows helper program as one release.

A release is incomplete until both parts are available. The module downloads the Windows helper
from the matching GitHub Release, so publishing only the ForgeBox package will break automatic
installation.

## What a complete release publishes

| File or package | Destination | Command that creates it |
| --- | --- | --- |
| Pure CFML module package | ForgeBox and the GitHub Release | The release kit called by `build\release.ps1` |
| `cbcloudscraper-win64.zip` | GitHub Release asset | `build\release.ps1` |
| `cbcloudscraper-win64.zip.sha256` | GitHub Release asset | `build\release.ps1` |

The PowerShell release script builds and publishes all three items.

## One-time setup

Install and configure these tools on Windows:

- Python 3.11 for building the helper program. Check it with `py -3.11 --version`.
- CommandBox. Check it with `box version`.
- GitHub CLI. Sign in with `gh auth login`.
- ForgeBox access. Sign in with `box forgebox login`.
- GitKraken for the Gitflow steps used by this project.

Gitflow is the branch workflow used for releases after `v1.0.0`. Work starts on `develop`, moves
to a release branch, and then merges into both `master` and `develop`.

In GitKraken, open **Preferences > Gitflow** and set the version tag prefix to `v`. The release
kit also uses `v` as its tag prefix.

Run the project setup check at any time:

```bash
box run-script release:check
```

Run releases from a clean Git working tree. The release kit stops when tracked or untracked
files have not been committed or stashed.

## Check whether the helper needs a rebuild

Rebuild the Windows helper when any of these conditions is true:

- A file under `engine/` changed.
- `build/cbcloudscraper.spec` changed.
- A newer runtime library should be included.
- A target site stopped working and you want to test newer browser fingerprints or challenge
  handling.

Run the update check:

```powershell
powershell -ExecutionPolicy Bypass -File build\check-updates.ps1
```

The script compares `engine\requirements.lock.txt` with the latest stable package versions on
PyPI, the Python Package Index. It also checks whether the helper source changed after the latest
release tag. The script does not install packages or change files.

The script exits with code `1` when it recommends a rebuild. Use `-Prerelease` when you also
want to see available prerelease packages:

```powershell
powershell -ExecutionPolicy Bypass -File build\check-updates.ps1 -Prerelease
```

`curl_cffi` uses a version range in `engine\requirements.txt`, so a new build may select a newer
version without a repository change. `cloudscraper25` uses an exact version. Update that exact
version in `engine\requirements.txt` only when you intend to change it.

## Build and test the Windows helper

Build the helper:

```powershell
powershell -ExecutionPolicy Bypass -File build\build-binary.ps1
```

The build creates `bin\win64\cbcloudscraper.exe` and its support files. It also rewrites
`engine\requirements.lock.txt` with the package versions included in the build.

Review and commit `engine\requirements.lock.txt` when it changes. Add `-Clean` to rebuild the
Python virtual environment from the beginning:

```powershell
powershell -ExecutionPolicy Bypass -File build\build-binary.ps1 -Clean
```

Run the smoke test after building. The smoke test makes one HTTP request with the built helper:

```powershell
powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1
```

You can test a real target by passing its URL:

```powershell
powershell -ExecutionPolicy Bypass -File build\smoke-test.ps1 -Url https://your-target.example.com/
```

A changed helper needs a new module version and a new release tag. Do not replace the ZIP file
on an older release. Installed modules record the release tag of their helper, so replacing an
old asset does not tell those modules to download it again.

## Publish the first release: `v1.0.0`

Use this section only for the first release. The repository currently has version `1.0.0` in
`box.json` and a dated `1.0.0` section in `CHANGELOG.md`.

Do not run a version bump command. A bump would skip `1.0.0`.

From `master`, commit all release changes and confirm that the working tree is clean. Then run:

```powershell
git status
box run-script release:check
powershell -ExecutionPolicy Bypass -File build\release.ps1
```

The script performs these actions:

1. Builds the Windows helper.
2. Runs the test suite on every supported engine: Lucee 6, Adobe 2023, Adobe 2025, and BoxLang
   CFML. The engines run one at a time because they share a port. A failure on any engine stops
   the release.
3. Starts the Adobe 2023 test server.
4. Runs the tests and builds the CFML package.
5. Publishes the module to ForgeBox.
6. Creates and pushes tag `v1.0.0`.
7. Creates the GitHub Release.
8. Creates the helper ZIP file and SHA-256 checksum.
9. Uploads the helper ZIP file and checksum.

The multi-engine tests take several minutes because they start and stop four servers. Use
`-SkipEngineTests` only when the release cannot wait for these tests. Skipping the multi-engine
tests can allow code that works on one CFML engine but fails to compile on another.

The Adobe 2023 test server may remain running after the release finishes.

## Verify what users will install

After publishing, test the same download path that the module uses for application servers.

Move your local `bin\win64` directory out of the module or test from a clean copy. Then run:

```bash
box task run taskFile=tasks/Binary.cfc :action=install
```

The task should download the ZIP file from the new GitHub Release, verify its checksum, extract
the helper, and write the release tag into the version stamp.

Do not remove an uncommitted local build unless you have another copy or can rebuild it.

## Turn on Gitflow after `v1.0.0`

This is a one-time step after the first release succeeds.

In GitKraken, select **Gitflow > Initialize** and use these values:

- Production branch: `master`
- Development branch: `develop`
- Version tag prefix: `v`

Push the new `develop` branch to `origin`.

## Publish later releases with GitKraken

Use this process for every release after `v1.0.0`.

1. Work on `develop`. Add user-facing notes under `## [Unreleased]` in `CHANGELOG.md` as changes
   are made.
2. Run `build\check-updates.ps1`. Build and smoke-test the helper if the check recommends it or
   helper code changed. Commit an updated `engine\requirements.lock.txt` with the related work.
3. In GitKraken, select **Gitflow > Start release**. Name the release with the new version, such
   as `1.1.0`.
4. On the new release branch, run the correct bump command:

   ```bash
   box run-script bump:patch   # bug fixes: 1.0.0 to 1.0.1
   box run-script bump:minor   # new features: 1.0.0 to 1.1.0
   box run-script bump:major   # breaking changes: 1.0.0 to 2.0.0
   ```

5. Review `box.json` and `CHANGELOG.md`. Stage only those two files. Commit them with a message
   such as `Release 1.1.0`, then push the release branch.
6. Rehearse the release:

   ```bash
   box run-script release:dryrun
   ```

   The dry run may warn that the current branch is not `master`. That warning is expected on a
   release branch.
7. In GitKraken, select **Gitflow > Finish release**. GitKraken merges the release into `master`
   and `develop`. GitKraken also creates a tag such as `v1.1.0`.
8. Push `master`, `develop`, and the new tag. Check out `master`.
9. Publish the existing tag:

   ```powershell
   powershell -ExecutionPolicy Bypass -File build\release.ps1 -ExistingTag
   ```

10. Run the user installation check from the previous section.

`-ExistingTag` is required because GitKraken already created the release tag. Without this
switch, the release kit tries to create the same tag and stops. The existing tag must point to
the current `master` commit.

A hotfix follows the same process, but it starts from `master` instead of `develop`. A hotfix
normally uses `bump:patch`. Finish the hotfix into both `master` and `develop` before publishing.

## Troubleshooting

| Problem | What to do |
| --- | --- |
| The helper is already built and has not changed. | Add `-SkipBinaryBuild` to `build\release.ps1`. The script still creates and uploads a fresh ZIP and checksum. |
| The release kit finished, but the helper upload failed. | Upload the two assets with the recovery command below. |
| ForgeBox published, but the tag or GitHub Release was not created. | Run the matching `build/Release.cfc` recovery command below. Do not run the full release again. |
| The command reports `Tag v1.1.0 already exists`. | Use `-ExistingTag` if GitKraken created the tag and it points to the current commit. Otherwise, check whether the version was already released. |
| The command reports uncommitted changes. | Review and commit or stash them. The release will not publish from a dirty working tree. |
| The tests report no answer from the server. | Start it with `box run-script start:2023`. |
| The binary build changed `engine/requirements.lock.txt`. | Review and commit the lock file, then run the release again from a clean working tree. |

If only the helper upload failed, replace `v1.1.0` with the release tag and run:

```powershell
gh release upload v1.1.0 .artifacts\binary\cbcloudscraper-win64.zip .artifacts\binary\cbcloudscraper-win64.zip.sha256 --clobber
```

If ForgeBox published but no tag or GitHub Release exists, run:

```bash
box task run taskFile=build/Release.cfc target=github :version=1.1.0
```

If the tag already exists and points to the release commit, add `:existingTag=true`:

```bash
box task run taskFile=build/Release.cfc target=github :version=1.1.0 :existingTag=true
```

Do not rerun the complete release after ForgeBox has published the version. ForgeBox will reject
the duplicate version, and the release may already be partly available to users.
