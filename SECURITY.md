# Security

Report vulnerabilities through [private vulnerability reporting](https://github.com/paulbalaji/talos/security/advisories/new). Include the Talos commit or version, operating system, and the smallest reproduction you can share. Redact credentials, private source, review replies, and home-directory details.

Talos is a local process running as your user. Choose trusted executables and provider profiles. Use a private Talos state directory. Enable publication only for repositories where your GitHub identity is authorized to review and where unattended reviews are acceptable.

Keep credentials in the logins managed by the provider CLIs, a secret manager, or environment variables supported by the relevant CLI. CI builds and tests need no provider credentials. If a separate workflow ever needs credentials, store them in GitHub Actions secrets and inject them into the specific job step. Never add credential files, provider output, or live watcher state to this repository.

GitHub secret scanning and push protection are enabled. CI scans Git history with Gitleaks. Contributors can install the staged-file hook with `git config core.hooksPath .githooks` after installing Gitleaks.
