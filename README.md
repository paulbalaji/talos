# Talos

Talos reviews GitHub pull requests from your machine using Codex, Claude Code, or Kimi Code. It records the ready PRs that already exist, then picks up new ready PRs, drafts that become ready, and new heads. It also rereviews heads it has reviewed when the discussion or effective diff changes. Reviews stay local by default. Each repo can opt into comments and approvals separately.

## Use Talos

You need Zig 0.15.2, Git, GitHub CLI with `gh api --slurp`, and one reviewer CLI. On macOS, install the Xcode Command Line Tools. On Linux, run `talos tick` from your scheduler.

```sh
git clone https://github.com/paulbalaji/talos.git
cd talos
zig build -Doptimize=ReleaseSafe
mkdir -p "$HOME/.local/bin"
install -m 755 zig-out/bin/talos "$HOME/.local/bin/talos"
export PATH="$HOME/.local/bin:$PATH"
```

Sign in with `gh auth login` and sign in to your reviewer CLI. Replace `OWNER/REPO` and `123` with your repo and an open, ready PR.

```sh
talos add OWNER/REPO                   # Track this repo with your default reviewer
talos run-once OWNER/REPO 123          # Preview this PR, including a baselined PR
talos install                         # Start the macOS scheduler
talos status                          # See scans, queue, errors, and cache sizes
```

| Do this | Run |
| --- | --- |
| Preview a specific PR with a review mode | `talos run-once OWNER/REPO 123 --mode perf-maxxing` |
| Look for needless complexity in a refactor | `talos run-once OWNER/REPO 123 --mode simplicity` |
| Preview the next eligible reviews | `talos run-once` |
| Preview the next review in one repo | `talos run-once OWNER/REPO` |
| Show or set the reviewer default for new repos | `talos defaults` or `talos defaults --engine claude` |
| Queue a specific PR under the repo's publication policy | `talos queue OWNER/REPO 123` |
| Queue a review with a focus | `talos queue OWNER/REPO 123 --mode perf-maxxing --prompt 'Check allocations on the request path.' --publish` |
| Read the latest local review candidate for a PR | `talos result OWNER/REPO 123` |
| Open a draft for a deferred finding | `talos followup THREAD_URL` |
| Preview a followup | `talos followup THREAD_URL --dry-run` |
| Track drafts and merge readiness | `talos followup status` |
| Pause or resume a followup | `talos followup pause THREAD_URL` or `talos followup resume THREAD_URL` |
| Queue a numbered GitHub stack | `talos stack OWNER/REPO 10088` |
| Queue branches as an explicit stack | `talos stack OWNER/REPO feature 123 124 125` |
| Remove an explicit local stack definition | `talos unstack OWNER/REPO feature` |
| Inspect one repo or read JSON | `talos status OWNER/REPO` or `talos status --json` |
| Show provider starts and cooldowns | `talos usage` |
| Set a provider’s starts per UTC day | `talos usage codex 40` |
| Show or set the review budget per tick | `talos queue-budget` or `talos queue-budget 3` |
| Pause or resume reviews for a repo | `talos pause OWNER/REPO` or `talos resume OWNER/REPO` |
| Run one scheduler pass | `talos tick` |
| Remove the macOS scheduler | `talos remove` |
| List flags and commands | `talos --help` |

`run-once` always previews. `tick` uses the configured publication policy. A numbered preview also works while its repo is paused.

### Focus a review

Use a review mode on a numbered preview or queued review. Add `--prompt` to give the configured reviewers specific context or a question.

```sh
talos run-once OWNER/REPO 123 --mode perf-maxxing --prompt 'Check allocations on the request path.'
talos run-once OWNER/REPO 123 --mode reliability-maxxing
talos run-once OWNER/REPO 123 --mode security-maxxing
```

Performance covers hot paths and scaling. Reliability covers partial failure, retries, and recovery. Security checks trust boundaries and mitigations from static source. With no mode, Talos runs the general review. Talos saves queued prompts locally and sends them to the configured reviewers. Keep credentials out of them. A review with a custom prompt stays local by default. Add `--publish` to allow its result to appear on GitHub when the repo allows comments. Review modes without a custom prompt follow the repo’s comment policy. Focused reviews publish as comments. Queue the same head again with no flags to retry with its saved options.

After a review, Talos checks for new human replies, closed or reopened threads, and changes to the base branch or merge base. It checks up to four completed PRs per repo per scan. A rereview includes the previous verdict on individual findings and a bounded diff from the last reviewed commit when available. Talos keeps up to 16 notes for each tracked PR. The review receipt prevents a duplicate post after a restart.

When approvals are enabled and CI is the only reason Talos withheld approval, passing checks trigger a rereview on the same head. The new review rechecks the current source and discussion before approving.

If a rereview finds an issue after an approval, its comment flags the earlier approval for a person to reassess. On upgrade, Talos uses newer human replies to catch up completed reviews. It tracks resolution changes from the first successful scan.

`talos status OWNER/REPO` shows up to five completed jobs still tracked and links to verified GitHub reviews. `talos result OWNER/REPO 123` prints the last saved local candidate, including its reviewed commit. A review reconciled from GitHub can have a receipt without a local candidate.

### Follow up on a deferred finding

Copy the link to an inline review comment in a registered repo.

```sh
thread='https://github.com/OWNER/REPO/pull/123#discussion_r456'
talos followup "$thread" --dry-run
talos followup "$thread"
talos followup status
talos followup "$thread" --merge-when-ready
```

The scheduler waits for the original PR to merge, then checks the finding against the current target branch. If it can make a small fix, Talos pushes a branch and opens a draft linked to the thread. It reuses the same draft on retry. The command grants permission to open that draft, including in a repo whose reviews stay local. The dry run prints the proposed replacement and skips the branch and draft.

Talos uses the configured reviewer CLIs to propose changes to the file named in the thread. It can read up to three more source files from the pinned commit, within 24 KiB of extra context. It applies the replacement in an isolated Git index and leaves code execution to GitHub CI. Followups share the review budget and respect repo pauses.

Talos watches the draft from creation. It verifies feedback on the current head, pushes up to three scoped updates, and marks the draft ready when GitHub checks pass. Feedback outside the original fix and changes from another author can require a human decision. Use `talos followup status --json` for the tracked head and state.

With `--merge-when-ready`, Talos submits the current head for normal GitHub merge after an independent approval and passing checks. The same flag also opts in an existing followup. Use the thread link shown by `status` to pause or resume. Pausing a followup stops Talos actions. GitHub handles any merge already submitted.

### Review a PR stack

When Talos scans ready PRs, it uses the number and member order GitHub recorded for each `gh stack`. It reads that metadata through the GitHub API. Stack detection keeps the baseline intact and groups existing per-head jobs.

For PRs without a GitHub stack, Talos can infer a linear chain when each PR targets the previous PR's branch and exact head in the same repo. Ambiguous or branched relationships stay in the ordinary queue. You can also define a local stack with two to eight ready PRs in one repo, bottom to top.

```sh
talos stack OWNER/REPO 10088
talos stack OWNER/REPO feature 123 124 125
talos status OWNER/REPO
talos run-once OWNER/REPO 124
talos unstack OWNER/REPO feature
```

Talos waits for queued ancestor reviews or merges before starting the next scheduled PR. A baselined ancestor can contribute its pinned diff and any available review without starting a new model run. Reviewers see excerpts from the nearest ancestors, and Talos rechecks the entire ordered prefix before publication. Each PR keeps its own diff anchors and publication receipt. Use `status` to see the stack number, order, and why a PR is blocked. `unstack` removes an explicit local definition and keeps its queued jobs. A later scan can detect the chain again. [GitHub stack APIs](https://docs.github.com/en/pull-requests/reference/stacked-pull-requests-apis-and-webhooks)

### Route reviews by risk

Fixed routing is the default. To evaluate adaptive routing, use a separate state directory and queue a few ready PRs.

```sh
trial_state=$(mktemp -d)
talos --home "$trial_state" add OWNER/REPO --routing shadow --light-model codex=gpt-6-luna
talos --home "$trial_state" queue OWNER/REPO 123
talos --home "$trial_state" tick
talos --home "$trial_state" status OWNER/REPO --json
```

Shadow runs the configured full review and records the suggested route, per-pass timings, and finding-anchor differences. Compare those results against the actual changes before enabling adaptive routing. Matching anchors are a rough comparison. Check the findings themselves for missed defects and incorrect escalations.

Adaptive routing uses four levels.

| Level | Review |
| --- | --- |
| Light | One lightweight review of a complete, narrowly mechanical image patch bump. Any finding, unclear discussion, or missing evidence sends it to full review. A light review can post a comment. |
| Regular | The configured reviewer or reviewer group. |
| Focused | The regular reviewers receive the relevant performance, reliability, or defensive security prompts. |
| Multi | At least two providers with distinct briefs. A synthesis pass checks reported issues against the source and combines duplicates. Talos waits if the provider pool cannot supply both reviewers. |

Talos routes contract changes, ownership and signing changes, deployment permissions, and changes to access policy directly to multi-provider review. Other clear risks go to the relevant focused review. A configured lightweight model can recommend a stronger route for ambiguous changes. Manual modes and prompts take precedence. GitHub approvals require a full review.

On scheduled reviews, the screening model can request up to six specific files or excerpts from the pinned commit. Talos fetches those itself before starting the full review. A multi review with findings may use one more reviewer start for synthesis. If the current tick has no starts left, Talos saves the completed passes and finishes on a later tick.

### Configure provider fallback

```sh
talos add OWNER/REPO --engine codex --fallback claude,kimi
talos add OWNER/REPO --routing shadow --light-model codex=gpt-6-luna --light-model claude=haiku
talos usage codex 40
talos usage
```

List only providers approved to receive the repo’s source and discussions. Talos tries the primary reviewer list in order and uses authorized fallbacks when a provider is cooling down or at its daily start cap. A multi-review job keeps successful passes across ticks and restarts while waiting for the remaining independent providers. Talos rechecks the pinned input before reusing a pass. Use `--fallback off` to remove fallback providers and `--light-model ENGINE=off` to remove a screening model. Include publication flags when updating a tracked repo.

`talos usage` counts starts made by this Talos state directory. It includes screening, failed attempts, and previews. Daily caps reset at midnight UTC. A cap of `0` means unlimited. The count estimates local workload. It has no view of requests made by other tools or of the provider’s remaining subscription quota.

Every model start also counts against the per-tick budget. Adaptive routing reserves enough starts for its strongest possible route and releases unused starts after the job returns. Routing reports and accumulated passes are private local state. Screens use standard speed and skip advisor calls.

### Configure each repo

Talos starts with Codex as the default. To use Claude Code on a Claude-only machine, run `talos defaults --engine claude` once. New repos use that setting unless you pass `--engine`. Existing repos keep their reviewer settings.

Run `add` again to update settings and carry forward the baseline and queue. Talos keeps the repo's reviewers, model, and executable paths when you omit their flags. Repeat any other settings you want to keep. Leaving out both publication flags returns the repo to dry-run.

```sh
talos add OWNER/REPO --engine codex --interval 180
talos add OWNER/REPO --engine claude --model sonnet
talos add OWNER/REPO --engine kimi --model kimi-code/kimi-for-coding
talos add OWNER/REPO --engine claude,codex --model sonnet
talos add OWNER/REPO --engine claude,codex,kimi --reviewer-model claude=sonnet --reviewer-model kimi=kimi-code/kimi-for-coding
talos add OWNER/REPO --engine claude,codex --claude-advisor off --reviewer-effort codex=medium
talos add OWNER/REPO --comments
talos add OWNER/REPO --approvals
talos add OWNER/REPO --comments --approvals
talos add OWNER/REPO --cache-mib 256 --cache-idle-days 14
talos add OWNER/REPO --cache-mib 0
```

At registration, Talos resolves Git, GitHub CLI, and each selected reviewer on PATH. Set paths explicitly with `--git`, `--gh`, `--codex`, `--claude`, or `--kimi`.

Use `--model MODEL` for the first reviewer, or repeat `--reviewer-model ENGINE=MODEL` for any selected reviewers. A named override takes precedence for that reviewer. When you set `--engine` again, repeat any model overrides you want to keep.

| Reviewer | Default model | Effort | Advisor |
| --- | --- | --- | --- |
| Codex | GPT-6.2 Sol (`gpt-6.2-sol`) | High | |
| Claude Code | Latest Opus (`opus`) | High | Latest Fable (`fable`) |
| Kimi Code | K3.1 Pro (`kimi-code/k3.1-pro`) | High | |

Use `--reviewer-effort ENGINE=LEVEL` to change effort. Use `default` to leave effort to the CLI. Codex and Claude accept `low`, `medium`, `high`, `xhigh`, and `max`. Kimi accepts `low`, `high`, and `max`. The chosen model must support the requested settings.

Talos requests standard serving speed in Codex and disables Claude's fast mode. It selects regular Kimi models and rejects model IDs named as premium speed variants. Use standard-speed routes when defining custom model aliases. [Codex speed](https://learn.chatgpt.com/docs/agent-configuration/speed) · [Claude fast mode](https://code.claude.com/docs/en/fast-mode) · [Kimi models](https://www.kimi.com/code/docs/en/kimi-code/models.html)

Fable receives the review context when Claude consults it. It requires Fable access and can use usage credits. Set `--claude-advisor off` on a repo to disable it. If your Kimi plan lacks K3.1 Pro, select an available model with `--reviewer-model kimi=MODEL`. [Claude advisor](https://code.claude.com/docs/en/advisor) · [Kimi models](https://www.kimi.com/code/docs/en/kimi-code/models.html)

Each reviewer in a list gets the same pinned source and discussion. Talos runs them in order, groups findings at the same diff line, and sends one review with reviewer attribution. A failed reviewer retries the job. Choose providers that can receive the repo's source and discussion.

`--comments` allows publishing a comment review. `--approvals` requires complete coverage and no findings from every configured reviewer, passing checks, and no merge conflicts. Each reviewer must give an evidence-based reason why each open thread is non-blocking. Any active finding or unassessed thread blocks approval. GitHub applies the target branch’s conversation-resolution rule at merge time. The author must differ from the configured GitHub identity. A clean candidate can become a comment when only comments are enabled.

### macOS build fallback

If Zig 0.15.2 cannot link against your macOS SDK, build with an explicit deployment target.

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

## How it fits together

```mermaid
flowchart TD
    User[Developer] -->|commands| Talos
    subgraph Machine[Developer machine]
        Scheduler[launchd or Linux scheduler] -->|tick| Talos[Talos]
        Talos --> State[State and Git cache]
        Talos --> Tools[Git and GitHub CLI]
        Talos <-->|context and findings| Reviewer[Selected reviewer CLIs]
    end
    Tools <-->|source and PRs| GitHub
    Reviewer <--> Provider[Model provider]
```

Talos pins the PR head and base, computes their merge base, and sends bounded source and review threads to the reviewer. The context includes resolved threads and author replies. Repo content and GitHub discussion are untrusted input. Each reviewer runs in a temporary directory with local tools disabled. Codex also uses its read-only sandbox. Use provider accounts approved to receive that repo's source and discussion. Kimi Code may retain its own sessions.

Talos publishes one short review with concrete findings inline and links to existing threads that still matter. It checks the head, base, and discussion before publication and reads back the review and posted inline locations. Partial coverage rules out automatic approval. The review names any material evidence gaps or checks holding up approval.

## Operate Talos

The macOS job is `dev.talos.watcher`. It wakes every 15 seconds while the Mac and user session are available. Repos poll every 180 seconds by default. launchd uses the installation PATH and the scheduled user's login. Keep credentials in CLI logins, supported environment variables such as `GH_TOKEN`, or a secret manager. See [security](SECURITY.md).

```sh
launchctl print "gui/$(id -u)/dev.talos.watcher"
talos status --json
```

The state directory is `~/.local/state/talos`. One process holds its lock at a time. Each tick admits up to three independent PRs per repo across five repos. Model reviews run in parallel. One coordinator collects source, updates state, and handles GitHub publication. PRs in a stack still wait for queued ancestors. `state.json` holds reviewer defaults, the baseline, queue, stacks, publication receipts, and recent errors. `repos/OWNER/REPO/results/` holds candidate reviews. Check `launchd.log` for scheduler errors.

Talos rotates `launchd.log` on the next tick after a UTC day boundary or when it reaches 1 MiB. It keeps up to 30 days and 10 MiB across the active log and its archives, with newer diagnostics taking priority. The scheduler also reports the last 12 errors per repo through `talos status`. Log retention only applies to scheduler diagnostics.

The machine budget defaults to 15 reviewer starts per tick for new installs. Existing installs keep their saved limit. A PR with two configured reviewers reserves two starts. The same limit applies separately to receipt lookups, which use GitHub calls and zero reviewer starts. Set it with `talos queue-budget 15`. It must fit the largest configured reviewer list. Unserved work stays queued, and Talos rotates between repos across restarts. `status` shows the next eligible PR and the last active tick's review starts and GitHub CLI calls. Each repo keeps its own scan interval and Git cache limits.

A recognized GitHub rate limit holds scans and review jobs. A recognized reviewer rate limit holds jobs that use that reviewer. Talos saves these cooldowns across restarts and backs off from 60 seconds up to 16 minutes. During a GitHub cooldown it can hold up to 15 finished analyses for reuse. Reuse requires the same review inputs and fresh checks before publishing.

Job retries back off from 30 seconds, with six attempts per head. Use `queue` to retry. If a POST may have reached GitHub, Talos retries the receipt lookup and leaves the head `uncertain` until it can confirm the result. Run one publisher per repo because GitHub has no cross-machine idempotency key for reviews.

### Git cache

Each watched repo has a Talos-owned bare cache at `repos/OWNER/REPO/objects.git`. Talos fetches Git history directly from GitHub and downloads file contents as needed. V0 registrations carry forward automatically, and Talos discards caches from the old checkout-based workflow.

Talos checks the cache after source collection and every hour. It evicts the whole cache above **128 MiB** or after **seven idle days** by default. The next review rebuilds it. A fetch can temporarily exceed the retained limit. Set `--cache-mib 0` to discard the cache after every snapshot. `status` shows cache file sizes in bytes.

### Test a build alongside the installed watcher

```sh
test_state=$(mktemp -d /tmp/talos-check.XXXXXX)
zig-out/bin/talos --home "$test_state" add OWNER/REPO
zig-out/bin/talos --home "$test_state" run-once OWNER/REPO 123
zig-out/bin/talos --home "$test_state" install --label dev.talos.test
launchctl print "gui/$(id -u)/dev.talos.test"
zig-out/bin/talos --home "$test_state" remove --label dev.talos.test
```

Use `talos remove` to stop the default scheduler and keep its data. For a full uninstall, remove the binary and the state directory after saving any records you need.

## Develop Talos

| Change | Start here |
| --- | --- |
| CLI parsing, registration, and scheduling | `src/repo_config.zig`, `src/main.zig`, `src/launchd.zig` |
| Discovery, retries, and publication policy | `src/core.zig`, `src/store.zig` |
| Review budget, scheduling order, and cooldowns | `src/queue.zig` |
| Review routing and fallback execution | `src/routing.zig`, `src/adaptive.zig` |
| Durable provider start counts and limits | `src/usage.zig` |
| PR stacks and inherited context | `src/stack.zig` |
| Git snapshots, anchors, and cache eviction | `src/source.zig`, `src/cache.zig` |
| GitHub API | `src/github.zig` |
| Reviewer adapters and result schema | `src/reviewers/`, `src/runner.zig`, `src/review-schema.json` |

Each reviewer adapter sets its allowed environment, builds the CLI invocation, and extracts the result. Register new adapters in `src/runner.zig` and add the corresponding engine and executable to the CLI. The shared pipeline validates findings and handles GitHub publication.

```sh
zig fmt --check build.zig src
zig build test
gitleaks git --redact --no-banner
git config core.hooksPath .githooks      # Optional local checks with Gitleaks installed
```

Use Conventional Commits for commit subjects and PR titles. CI checks both and runs on macOS and Linux. Keep GitHub mutation in the Zig process, leave model tools disabled, and preserve exact-commit readback and deduplication. The resolved-thread regression is based on [Hyperlane PR #10122](https://github.com/hyperlane-xyz/hyperlane-monorepo/pull/10122).

Write docs with commands, expected behavior, and the conditions that change what the reader should do. The review design and docs draw on Paul's [review skills](https://github.com/paulbalaji/skills) and [writing guide](https://github.com/paulbalaji/skills/tree/main/write-like-paul).

[MIT license](LICENSE)
