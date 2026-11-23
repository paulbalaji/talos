# Talos

Talos watches open GitHub pull requests from your machine. It baselines the PRs that are already ready, then reviews new ready PRs, drafts that become ready, and new commits on open PRs. The watcher saves reviews locally by default. Each repository can opt into posting comment reviews, approvals, or both.

Talos is written in Zig. It uses your GitHub CLI login and runs the review through your choice of Codex, Claude Code, or Kimi Code CLI.

## Install

Use Zig 0.15.2, Git, a current GitHub CLI with `gh api --slurp`, and a current version of your selected review CLI. macOS needs Xcode Command Line Tools for the build. The scan and review commands also run on Linux.

```sh
git clone https://github.com/paulbalaji/talos.git
cd talos
zig build -Doptimize=ReleaseSafe
mkdir -p "$HOME/.local/bin"
install -m 755 zig-out/bin/talos "$HOME/.local/bin/talos"
```

If Zig 0.15.2 cannot link against a newer macOS SDK, set a supported deployment target explicitly for the executable build.

```sh
case "$(uname -m)" in
  arm64) talos_arch=aarch64 ;;
  x86_64) talos_arch=x86_64 ;;
esac
mkdir -p zig-out/bin
zig build-exe src/main.zig -lc -O ReleaseSafe \
  -target "$talos_arch-macos.15.0" --sysroot "$(xcrun --show-sdk-path)" \
  -femit-bin=zig-out/bin/talos
install -m 755 zig-out/bin/talos "$HOME/.local/bin/talos"
```

Put `$HOME/.local/bin` on your PATH and sign in with `gh auth login` and the applicable provider CLI. Register repositories using the GitHub `OWNER/REPO` name and a local full clone.

```sh
talos add OWNER/REPO "$HOME/work/repo" --interval 180
talos run-once OWNER/REPO 123
talos install
talos status
```

`run-once` always prints a dry-run result and leaves the queue unchanged. With a PR number, it reviews an existing ready PR even if it was part of the baseline. Without a PR number, it scans and previews one eligible queued review per selected repository. `talos queue OWNER/REPO 123` instead asks the scheduler to review the current head under that repository's configured policy.

### Reviewer and publication settings

```sh
talos add OWNER/REPO "$HOME/work/repo" --engine claude --model sonnet
talos add OWNER/REPO "$HOME/work/repo" --engine kimi --model kimi-code/kimi-for-coding
talos add OWNER/REPO "$HOME/work/repo" --comments --approvals
```

Use `--engine codex` or omit the option for Codex. Pass `--model` to select a model your login can access. Use `--git`, `--gh`, `--codex`, `--claude`, and `--kimi` to override paths. Talos resolves executables on PATH at registration and records the selected paths. Re-running `add` updates settings and keeps the baseline and queue. Supply the full set of settings you want to keep. Omitting publication options returns the repo to dry-run.

Publication is commit-bound and uses the GitHub identity from registration. `--comments` allows one consolidated comment review per commit. `--approvals` allows a clean approval when the review is complete, checks pass, the PR is mergeable without conflicts, there are no unresolved review threads, and the reviewer is not the author. With only comments enabled, an approval candidate can be posted as a comment. Talos never requests changes or merges PRs.

Talos uses existing logins by default. For automation, GitHub CLI accepts `GH_TOKEN`, and Talos passes supported provider-specific environment variables to the corresponding reviewer. launchd does not source your shell startup files. Log in as the scheduled user or supply credentials through your environment or secret manager. Keep tokens out of command arguments, plists, Talos state, git, and logs. GitHub Actions secrets are appropriate for workflows that need credentials. Talos CI runs without provider credentials.

### Status, scheduling, and removal

```sh
talos status OWNER/REPO
talos status --json
talos pause OWNER/REPO
talos resume OWNER/REPO
talos remove
```

`install` creates a per-user launchd job, `dev.talos.watcher`. It wakes the watcher every 15 seconds; individual repositories default to a 180-second scan. The Mac must be awake with an active user session. Use `talos tick` from a scheduler on Linux. One process holds a filesystem lock per state directory, including manual dry runs, to prevent overlapping reviews. An explicit dry run with a PR number remains available while its repo is paused.

The state directory defaults to `~/.local/state/talos` and must be private. It contains `state.json`, the status ledger; `repos/OWNER/REPO/results/`, local candidate reviews; and `launchd.log`, scheduler errors. Scan and job errors appear in `status`. Recovery retries back off from 30 seconds to a cap of 16 minutes. After six failed attempts for a head, `queue` can retry it. If a POST might have reached GitHub, retries reconcile its receipt without submitting a second POST. An unresolved ambiguous publication stays visible as `uncertain` for manual investigation. Coordinate publication on one Talos instance per repo; GitHub's review API has no cross-machine idempotency key.

Use both `--home /absolute/private/path` and `--label dev.talos.test` to run a separate registration in launchd. Pass the same arguments to remove it. Removing the scheduler preserves state and results. To fully uninstall after removal, delete the installed binary and, if you no longer need its records, the Talos state directory.

## Review boundaries

Talos fetches verified head and base commits into its own bare object cache under dedicated refs. It borrows existing objects from the configured checkout. Talos computes the merge base without moving the checkout's branch or writing any tracked files. It builds bounded source context and passes both open and resolved threads with their replies as untrusted evidence. Reviewers run in an empty temporary working directory with execution tools disabled. Codex additionally runs in its read-only sandbox. Kimi Code CLI uses its configured provider profile and may save CLI sessions. Only use trusted local settings and providers approved to receive the repository's source and review discussion.

Talos validates the structured result and checks each inline anchor against GitHub's diff. It refreshes threads and the head and base before sending any review, then reads the review back. The GitHub API binds the review to the head commit. The base check happens immediately before submission because the API has no expected-base field. Source context excludes common credential-file paths. A partial snapshot cannot produce an automatic approval.

The review workflow draws on Paul's [comprehensive and exact-head review skills](https://github.com/paulbalaji/skills). The resolved-thread test covers the accepted reorg-polling tradeoff from [Hyperlane PR #10122](https://github.com/hyperlane-xyz/hyperlane-monorepo/pull/10122).

## Develop

```sh
zig fmt --check build.zig src
zig build test
gitleaks git --redact --no-banner
```

Use Conventional Commits for PR titles and commit subjects, for example `fix(cli): handle missing config`. CI checks the PR title and every non-merge commit. Squash merges use the PR title as the commit subject.

Install Gitleaks and enable the optional local hooks to check staged content and commit subjects before pushing. Autosquash local fixups before opening a PR.

```sh
git config core.hooksPath .githooks
```

MIT licensed.
