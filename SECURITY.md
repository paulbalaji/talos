# Security

Report vulnerabilities privately. Include the Talos commit, OS, and the smallest reproduction you can share. Redact credentials and private source or review discussion. [Report a vulnerability](https://github.com/paulbalaji/talos/security/advisories/new)

Talos runs as your user. Use trusted executables and reviewer profiles, keep its state directory private, and enable publication only where your GitHub identity is authorized to review. Use reviewer providers approved to receive the repo's code and discussion.

Keep credentials in CLI logins, a secret manager, or supported environment variables. If a workflow needs credentials, inject GitHub Actions secrets into the relevant step. Talos CI uses no provider credentials. Keep credential files, live state, and reviewer output out of Git.

GitHub secret scanning and push protection are enabled. CI scans Git history with Gitleaks. Install Gitleaks and run `git config core.hooksPath .githooks` to check staged files locally.
