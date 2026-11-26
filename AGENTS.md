# Agent instructions

BlackPearl Mobile is the phone remote for the BlackPearl desktop app: a Flutter app for Android, with a Windows target
only for looking at screens while developing. README.md covers how it works and how to build it, PHONE-REMOTE.md the
protocol it speaks with the PC, and UPDATES.md how releases are built, shipped and verified.

## Working here

- Work on a branch in your own git worktree. Never push to `master` directly; changes reach it through reviewed pull
  requests (below).
- Flutter is not always on PATH. The scripts find it through `-Flutter <path>`, the `FLUTTER` environment variable,
  `flutter` on PATH, or `~/flutter/bin`. Use the version in `FLUTTER_VERSION` in `.github/workflows/build.yml`.
- `flutter pub get` rewrites `windows/flutter/generated_plugin*` with other line endings and no other change. Restore
  them rather than committing them.
- Keep the user's private details out of the repository and pull requests: server addresses, domains, pairing links,
  paths, and library contents. Keep `android/key.properties`, keystores, screenshots, local reports and build output
  out of commits.

## Shipping updates

"Ship" means: pull request → independent review → fixes until approved → merge →
release. When the user asks to ship, publish, or release an app update, follow
[UPDATES.md](UPDATES.md). Do the bulk of the work through `scripts/ship.ps1` (PowerShell 7), not
manual git, version, tag, and verification commands:

1. Commit the intended changes on your worktree's branch. Write a pull request
   description to a file outside the repository. Cover what changed and why, any
   intentional behavior changes, removals, or performance costs, and how you tested.
   Then run `./scripts/ship.ps1 -Message '<release note>' -BodyFile <path>`. It
   bumps the version and build number in `pubspec.yaml`, pushes the branch, opens the
   pull request, and starts the release checks on a clean copy of the commit in the
   background. `./scripts/ship.ps1 -Status` shows them, the workflow, and the review verdict.
2. Ask a separate agent with fresh context to review it, for example with
   `delegate_task`, `Agent`, or `spawn_agent`. Do not use a fork of yourself. Ask
   right away; the checks run during the review. Give it the PR number, the head
   commit, and the instruction to follow the `review-pr` skill in
   `.claude/skills/review-pr/SKILL.md`. Do not include your conclusions
   about the change.
3. Fix every blocking finding, and any failed check, in your worktree, commit, and
   rerun `./scripts/ship.ps1`, which pushes again, updates the same pull request,
   and checks the new head. Then ask for a re-review of the new head. Give the
   reviewer its earlier findings and your reply to each one. If you dispute a finding, explain why in
   that reply rather than ignoring it. Repeat until the reviewer approves. If you
   and the reviewer disagree on the same point twice, or there is no approval after
   five rounds, stop and ask the user.
4. After approval, run `./scripts/ship.ps1 -Merge`. It merges only the approved
   head, after CI and the release checks pass on it, and only if it still contains
   `master`. Then it tags the release, waits for the tag build, verifies the public
   release and its APKs as the app's updater sees them, and synchronizes the user's local `master`.

Stay with a ship until it finishes. Do not end your turn while `ship.ps1`, its
release checks, CI, or `-Merge` are still running. Wait on them, and answer every
completion notice by reading the end of that output. A notice is never "no response
requested". Report once, after the release is verified and local `master` is
synchronized, or say exactly which step failed.

If the user wants a change landed without a new release, pass `-NoRelease` to both
`ship.ps1` runs. The PR then keeps `master`'s version, and the merge creates no tag
or release. The review and fix loop is the same. Use it only when the user says not
to release.

Shipping is authorized for the whole flow above, including posting review comments
and merging the approved pull request. Do not add confirmation prompts for an
already authorized release. A pushed branch, an open pull request, or a successful
workflow run alone does not ship an update. Shipping does not authorize installing
on, opening, or controlling the user's phone. Verify the public GitHub release page and
its APKs; install on a device or emulator only when the user explicitly asks.

The public release repository is `Svovoniks/BlackPearlMobile`; its release branch is `master`. The signed APKs are
built by the tag job of `.github/workflows/build.yml`. Never move an existing version tag or replace an APK of a
published version. Use a higher version, and a higher build number, for every shipped change: phones accept an update
only when its version code is higher, and only when it is signed with the same key.

Fix check failures before asking for review. Reserve manual commands for exceptions, inspection, or recovery only.

After the public release is verified, `ship.ps1 -Merge` synchronizes local `master` with `origin/master`, including
the published commit, in the checkout that owns `master`. It preserves unrelated local work and keeps a recovery
stash if synchronization fails. If the release is verified but local synchronization failed, report exactly that.
Complete the local synchronization before reporting the shipping workflow as finished.
