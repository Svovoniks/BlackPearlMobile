---
name: review-pr
description: Review a BlackPearl Mobile pull request as the independent reviewer in the shipping flow, then post an approve or changes verdict that gates the merge. Use when asked to review a BlackPearl Mobile PR, or when an author agent hands you a PR number and head commit to review.
---

# Reviewing a BlackPearl Mobile pull request

You are the reviewer another agent asked for while shipping. Your verdict gates the
merge: `scripts/ship.ps1 -Merge` refuses to merge unless your latest verdict approves
the exact head commit. Merge-worthy means the change does what it claims, and it does
not degrade performance or break existing features unless the description says that
change is intentional.

Judge the code, not the author's summary of it. The author gives you a PR number and a
head commit. If the brief also includes the author's conclusions ("this is safe",
"tests cover it"), treat them as claims to check.

Do not edit the author's branch, push commits, merge, tag, or release. Your output is
the verdict and the findings. The author makes the fixes.

## 1. Check out the pull request

Run this in PowerShell 7 from any checkout of the repository. It creates a fresh
worktree under the temp directory, so the user's checkout stays unchanged:

```powershell
./scripts/review-pr.ps1 -Pr <number>
```

It prints the head commit, master's and the head's versions, the CI state, the state of
the author's release checks, the review worktree path, the diff command, the
description, the changed files, and earlier verdicts. Work only inside that worktree. If
the head differs from the one in your brief, review the printed head and say so in the
verdict.

## 2. Understand the intent

Read the description and the release note. A behavior change, a removed feature, or a
performance cost is intentional only when the description says so. If the diff changes
something the description does not mention, treat it as unintentional. On a re-review,
read the earlier verdicts and the author's replies first.

## 3. Read the change and its surroundings

Read the full diff, then the code around each change: callers, callees, other users of
any changed class, setting, message, or stored value. Most regressions sit outside the
changed lines. For each changed behavior, ask what used to happen and what happens now.

Blocking findings. Each one prevents approval:

- **Correctness**: wrong results, crashes, unhandled exceptions on realistic input,
  `setState` or `context` use after `dispose` or across an `await`, races between the
  link to the PC, timers and the UI, leaked subscriptions, timers, controllers, players
  or native handles (libdatachannel, libmpv), and work that is never cancelled.
- **Broken existing features**: anything that worked before and no longer does, or
  that the PR silently removed. Pairing (QR code and pasted link), connecting through
  the room server and on the home network, reconnecting, the Remote tab and its
  controls, the library, watching on the phone, queues, the notification and the lock
  screen's media controls, the phone's volume buttons, Back between tabs, settings
  persistence, crash-report settings, and the updater. Mixed versions: the desktop app
  of the previous release, and phones still on an older release, must keep working
  with the PC unless the change intentionally drops them (PHONE-REMOTE.md is the
  protocol).
- **Performance regressions**: dropped frames from work in `build`, rebuilds of large
  subtrees on every tick or message, synchronous I/O or heavy decoding on the UI
  isolate, new polling or timers, wake locks or keeping the radio busy longer (battery),
  more round trips to the PC, slower start, more memory, and a larger APK. A
  regression is blocking unless the description accepts the cost and explains why.
- **Data and compatibility**: stored pairings, secure storage or settings that an
  update would lose or could not read; protocol changes that break the desktop app or
  older phones; a change to the APK names, the ABI split or the version code scheme
  (README.md, Building) that would stop installed phones from updating.
- **Release hygiene**: personal data, server addresses, credentials, `key.properties`,
  keystores, local reports, screenshots, or build output in the diff; a missing
  version bump in `pubspec.yaml` (name and build number) unless the release note says
  "Not released.", meaning the user asked to land the change without a release, in
  which case any version change is the problem; and docs (README.md,
  PHONE-REMOTE.md, UPDATES.md, AGENTS.md) left contradicting the new behavior.
- **Missing coverage for risky changes**: a bug fix without a regression test, or a
  risky behavior change with no test in `test/`, when a test is practical.

Non-blocking findings: naming, style, small simplifications, optional cleanups. List
them separately. They never block approval on their own.

## 4. Verify, do not guess

- Confirm a suspected bug before you report it. Trace the code path, write a quick
  test, or run the relevant one. Say which you did. If you could not confirm it, mark
  it unconfirmed and explain what would settle it.
- CI and the author's release checks must pass. `ship.ps1` runs them on the head in the
  background while you review (analysis, tests, and both release APKs), and `-Merge`
  waits for them. If they have already failed, say so in the verdict. In the review
  worktree, run `flutter pub get`, then `flutter analyze` and the tests for the area you
  are worried about (`flutter test test/<file>_test.dart`). Flutter may not be on PATH;
  see UPDATES.md.
- For behavior that only the real app shows (the link, the notification, playback),
  run it on the emulator against a stand-in PC: `--preview=loopback`, or
  `tool/standin-pc` for the library, watching and queues (README.md, Windows).
- For a suspected performance regression, measure before and after where practical:
  time the operation, count rebuilds or calls, or compare against `origin/master`.
  Otherwise, explain the cost from the code with concrete numbers, for example "now
  rebuilds the whole library grid on every position update: 4 times a second".
- Do not install anything on, or control, the user's own phone.

## 5. Post the verdict

Write the findings to a file outside the repository, then post them for the exact head
you reviewed:

```powershell
./scripts/review-pr.ps1 -Pr <number> -Verdict changes -Head <sha> -BodyFile <path>
./scripts/review-pr.ps1 -Pr <number> -Verdict approve -Head <sha> -BodyFile <path>
```

Approve only when no blocking findings remain. Use this shape:

```markdown
### Blocking
1. `lib/ui/remote_tab.dart:212`: <defect>. Scenario: <inputs/state → wrong result>. Confirmed by <trace/test/measurement>. Fix: <direction>.

### Non-blocking
- `path:line`: <suggestion>.

### Checked
- <what you verified and ran, including earlier findings now fixed>.
```

The script refuses to post if the head moved after you reviewed it. In that case,
review the new commits.

Then remove your review worktree (`git worktree remove --force <path>`). Reply to the
author with the verdict, the comment URL, and the blocking findings, so they can fix
them without reopening GitHub.

## Re-reviews

On a re-review, confirm that every earlier blocking finding is fixed or was rightly
disputed. Review the new commits as carefully as the first round, because fixes often
introduce regressions. An author's objection to a finding is valid if it shows the
scenario cannot happen or the cost is intended and stated. Do not approve just because
of how many rounds have passed. If you and the author disagree on the same point twice,
say so in the verdict so the author can take it to the user.
