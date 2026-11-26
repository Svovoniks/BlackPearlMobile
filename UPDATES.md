# Builds and app updates

## Release checklist for agents

The public source and release repository is `Svovoniks/BlackPearlMobile`, and the release
branch is `master`. Installed apps update themselves from its public `/releases/latest`
endpoint (README.md, Building). Shipping is authorized when the user asks to ship an update.
Complete the whole flow below rather than stopping at a pushed branch, an open pull request,
or a workflow run.

Shipping means a reviewed pull request merged into `master`, then publishing and
verifying the GitHub release. Agents never push to `master` directly, and all agent
work happens in git worktrees (see AGENTS.md). Do not install on, open, or control the
user's phone as part of shipping. Install a release on a device or emulator only when the
user explicitly asks.

1. **Open the pull request.** Commit the change on your worktree's branch. Write the
   description to a file outside the repository: what changed and why, intentional
   behavior changes, removals, or performance costs, and how it was tested. Then run
   `./scripts/ship.ps1 -Message '<release note>' -BodyFile <path>`.
2. **Get an independent review.** Ask a separate agent with fresh context to review
   the PR with the `review-pr` skill (`.claude/skills/review-pr/SKILL.md`), giving it
   the PR number and head commit. The reviewer posts its verdict on the pull request
   with `scripts/review-pr.ps1`. It blocks on bugs, performance regressions, and
   broken existing features unless the description says the change is intentional.
3. **Fix until approved.** Fix the blocking findings, commit, rerun
   `./scripts/ship.ps1` (no arguments are needed to update the same PR), and ask for
   a re-review of the new head with the earlier findings and your replies. If the
   same point is disputed twice, or after five rounds without approval, ask the user.
4. **Merge and release.** Run `./scripts/ship.ps1 -Merge`. Report the PR, version,
   release URL, Actions result, local sync result, and any validation limitations.

Use the scripted flow by default. The goal is to let the automation do the bulk
of the work while agents stay focused on the change, the review, failure triage,
and release validation.

## Shipping with the release script

Run `scripts/ship.ps1` in PowerShell 7 from your worktree, on a feature branch that
contains the latest `origin/master` and has no uncommitted tracked changes.

**Open or update a pull request** (default mode). The script rejects branches whose
diff from `origin/master` touches anything other than release source paths: `lib/`,
`test/`, `android/`, `windows/`, `packages/`, `tool/`, `assets/`, `scripts/`,
`.github/workflows/`, `.claude/skills/`, top-level `*.md`, `pubspec.yaml`, `pubspec.lock`,
`analysis_options.yaml`, `.metadata` and `.gitattributes`. Within them it refuses build
output (`build/`, `.dart_tool/`, `.gradle/`, `.cxx/`, `node_modules/`), the stand-in PC's
`.state/`, signing files (`key.properties`, keystores), `local.properties`, `.env` files,
APKs, HTML reports, videos, databases, logs, and pictures outside the app's own icon and
asset folders. Top-level dotfiles such as `.gitignore`, and `.github/` outside `workflows/`,
are refused too. Change those by hand, outside this flow.

It picks a version above both the latest public release and `master`, and a build number
above `master`'s, and commits `Set version X+N` to `pubspec.yaml` on the branch if needed.
A branch that already has such a version keeps it across review rounds. The script pushes
the branch and creates the pull request, or updates the existing one's title, description,
and release note, so the workflow and the review start at once. The release note is kept in
the description under `### Release note` and becomes the merge commit's title
(`Release X: <note> (#PR)`) and the tag message.

It then starts the release checks in a background process that outlives the script, and
returns. They run `scripts/release-checks.ps1 -Lane all`: `flutter pub get`,
`flutter analyze`, `flutter test`, the shipping script checks, and then both release APKs
built as the tag build builds them, but signed with the debug key and without a Sentry
upload. That catches failures only a release build meets (R8, the native libraries for
both ABIs) before the merge instead of at the tag. Afterwards no tracked file may have
changed; a `pubspec.lock` that `pub get` rewrites means the lock file is out of date. The
checks run in a detached copy of the commit in a temp folder, so untracked files cannot
affect the result. On Windows that is the user's own (`%LOCALAPPDATA%\Temp`), whatever
`TEMP` says: Gradle's javac fails in a folder the user cannot list, such as
`C:\Windows\Temp`. A fresh copy builds libdatachannel for both ABIs from
source, so they take about ten minutes. That build (about 1 GB) goes to a folder of the
copy's own, named by `BLACKPEARL_NATIVE_STAGING`, and is removed with it; without the
variable, Windows builds keep it in `%LOCALAPPDATA%\bpdc`, one folder per checkout path
(`packages/blackpearl_datachannel/android/build.gradle`). Their record and log live in the repository's
shared git directory (`blackpearl-checks/`), so every worktree sees them. Pushing a newer
commit of the same branch stops the checks of the older one. A commit whose checks already
passed or are still running is not checked again.

On Windows, a `flutter pub get` in a fresh copy links the Windows plugins, which needs
permission to create symbolic links (Developer Mode, or an administrator). Without it Flutter
stops with "Building with plugins requires symlink support" after writing everything else.
The checks then run `pub get` once more, which succeeds without the links; only a Windows
build uses them (README.md, Windows), and the checks make none.

**Status** (`-Status`, optionally `-Pr N`). Shows the head's release checks
(running, passed, failed with the error and log, or interrupted), the workflow,
and the review verdict.

**Review.** `scripts/review-pr.ps1 -Pr N` checks out the head in a fresh temp
worktree and prints the description, versions, changed files, CI state, release check
state, and earlier verdicts. `-Verdict approve|changes -Head <sha> -BodyFile <path>`
posts the verdict as a PR comment with a `blackpearl-mobile-review` marker for that exact
commit. Every account here is the repository owner, and GitHub does not let authors
approve their own pull requests, so the marker comment is the approval. Only markers from
the owner, members, or collaborators count. The newest one wins.

**Merge** (`-Merge`, optionally `-Pr N`). The script refuses unless all of these
hold:

- The pull request is open, not a draft, and from this repository into `master`.
- The release checks have not failed on its exact head.
- The head contains the current `origin/master`.
- The newest reviewer verdict approves that head.
- Its version is higher than the latest release and has no tag, and its build number is
  higher than `master`'s.

It waits for the `build` workflow runs and the release checks on the head to succeed.
Release checks that were interrupted, for example by a restart, or never started on this
computer run in the foreground first. It then squash-merges with GitHub's head-SHA guard,
confirms the merged tree is exactly the reviewed tree, then tags and pushes `vX`. It
deletes the merged branch, waits for the tag's workflow run, and verifies without
authentication that `/releases/latest` is `vX`, not a draft or prerelease, with
`BlackPearl-vX.apk` and `BlackPearl-vX-armeabi-v7a.apk` uploaded under the release's own
URLs, each with a size and a SHA-256 digest. It downloads both APKs and checks their
bytes against those digests, which is what the app's updater checks, and that the public
release page links them. The tag job itself has already checked that both are signed with
the release certificate. Finally, it pulls `master` into the checkout that owns that
branch. If `master` has no checkout, it fast-forwards the local branch without switching
any checkout.

The script re-reads the verdict right before merging, so a rejection posted while CI
runs still stops the merge. If anything fails after the merge, the error names the
merged commit and the recovery step, because rerunning `-Merge` cannot help then.

**Without a release** (`-NoRelease`, only when the user asks not to release). Both
modes keep the version from `master`. They refuse a branch that changes it, and need
no release note. `-Merge -NoRelease` applies the same review, check, and CI gates.
It squash-merges with the PR title and synchronizes local `master`, with no tag or
release.

Any new commit, including a merge of `master` into the branch, needs another
`ship.ps1` run and a re-review, because approval covers one exact commit.

Local work is saved in a recovery stash and under the shared git directory
(`blackpearl-ship/`) before synchronizing a dirty master. The script merges the worktree
and index separately to preserve staged and unstaged edits, and retains untracked files.
Already-shipped changes do not remain as duplicate local edits. Divergence or conflicting
local work stops the sync without resetting commits or overwriting files. The recovery
stash is retained, and the error explicitly distinguishes a verified public release from
an incomplete local sync. `-VerifyOnly` also runs this final synchronization step so it
can complete a previously interrupted ship.

```powershell
# Preview the branch's files and version without changing anything.
./scripts/ship.ps1 -Plan

# Push, open the pull request, and start the release checks in the background.
./scripts/ship.ps1 -Message 'Back goes through the tabs instead of closing the app' -BodyFile $env:TEMP/pr-body.md

# Release checks, workflow, and review verdict for the branch's pull request.
./scripts/ship.ps1 -Status

# After fixing review findings or a failed check: push, update the same pull request, and check again.
./scripts/ship.ps1

# Reviewer: check out, then post a verdict for the exact reviewed head.
./scripts/review-pr.ps1 -Pr 27
./scripts/review-pr.ps1 -Pr 27 -Verdict approve -Head <sha> -BodyFile $env:TEMP/review.md

# Preview the merge gates, then merge, tag, and verify the release.
./scripts/ship.ps1 -Merge -Plan
./scripts/ship.ps1 -Merge

# A change the user does not want released: same flow, no version bump, tag, or release.
./scripts/ship.ps1 -NoRelease -Title 'Tidy the shipping docs' -BodyFile $env:TEMP/pr-body.md
./scripts/ship.ps1 -Merge -NoRelease

# Recheck an already pushed tag after a timeout or network interruption.
./scripts/ship.ps1 -VerifyOnly -Version 0.12.2

# Offline safety checks for the scripts; no pull request or release is created.
./scripts/ship-checks.ps1
```

Pass `-Flutter <path to flutter or flutter.bat>` when Flutter is not on PATH, or set
`FLUTTER`; otherwise the scripts try `flutter` on PATH, then `~/flutter/bin`. Pull
requests, reviews, and merges use the GitHub credential git already uses for pushes, read
through `git credential fill`; it is never printed. Public release verification stays
unauthenticated. No GitHub CLI is needed. `-TimeoutMinutes` defaults to 60. Verification
records and the downloaded APKs remain under `blackpearl-ship/` in the shared git
directory. A failed or interrupted check keeps its copy of the commit, named by `-Status`,
for investigation until the commit is checked again or a newer commit of the branch
replaces it. A failed workflow stops the script. It never rewrites a tag, replaces a
published APK, or installs the app.

### Manual fallback

Use this only to recover when the scripts cannot run:

1. Work on a branch in a worktree. Keep signing files, screenshots, local reports and build
   output out of commits.
2. Choose a version higher than the latest published release and set `version:` in
   `pubspec.yaml` to it, with a build number one above `master`'s, such as `0.12.2+26`. The
   release tag must be exactly `v0.12.2`; the tag job rejects tags that disagree with
   `pubspec.yaml`.
3. Run `./scripts/release-checks.ps1 -Lane all` from the worktree root, or at least
   `flutter analyze`, `flutter test` and
   `flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64`,
   and resolve failures.
4. Push the branch, open a pull request, and get the reviewer's approval as above.
   Merge only the approved head. Then tag that exact merge commit with an annotated
   tag and push the tag. Never force-push or move an existing release tag.
5. Wait for the **tag's** `build` Actions run to succeed. A branch or pull request
   run does not publish a release. The tag job builds the APKs, signs them with the release
   key from the repository secrets, checks the signing certificate, and creates the release
   with both APKs attached.
6. Verify without authentication that `/releases/latest` returns the expected
   tag, `draft=false`, and `prerelease=false`, and that both APKs have the exact expected
   names, a nonzero size, and a `sha256:` digest. Download them and check their SHA-256
   against the digests. This step matters: a draft or incomplete release cannot update
   users' apps.
7. Check that the public GitHub release page is available and links to both APKs.
8. Synchronize local `master` with `origin/master` and confirm it contains the
   published commit. Preserve unrelated staged/unstaged edits and untracked files.

Inspect Actions at https://github.com/Svovoniks/BlackPearlMobile/actions and releases at
https://github.com/Svovoniks/BlackPearlMobile/releases. Public REST endpoints work without
authentication; never print credentials when using authenticated APIs.

Public updater verification:

```powershell
$release = Invoke-RestMethod 'https://api.github.com/repos/Svovoniks/BlackPearlMobile/releases/latest'
$release | Select-Object tag_name,draft,prerelease
$release.assets | Select-Object name,size,digest,state,browser_download_url
```

If a tag build fails before the release is created, inspect its logs and fix the failure
in a new pull request with a higher version; do not move the tag. If a failure leaves a
release with only some of its APKs, attach the missing one only when it was built from the
same tagged commit by the tag job; otherwise ship a higher version. Never replace the bytes
of an APK already published. For a defective published version, release a higher patch
version with the fix; phones refuse a lower version code.

## Build and updater behavior

The `build` workflow runs `scripts/release-checks.ps1 -Lane ci` (pub get, analysis, tests
and the shipping script checks) on every pull request and push to `master`. A `v*` tag also
runs its release job: it checks the tag against `pubspec.yaml`, writes the signing key from
the repository secrets, builds one APK per ABI with the Sentry DSN and mapping upload,
checks that both carry the release certificate, and creates the GitHub release with them.
README.md, Building, describes the APK names, version codes, signing and crash reports, and
how installed apps find, download, check and install an update.
