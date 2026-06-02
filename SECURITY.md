# Security Policy

## Reporting a vulnerability

If you discover a security issue, please **do not open a public issue**.
Instead, report it privately using GitHub's
[private vulnerability reporting](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability)
on this repository, or contact the maintainer directly.

Please include:

- A description of the issue and its impact.
- Steps to reproduce.
- Any relevant logs **with secrets and resource identifiers redacted**.

## Scope and handling of secrets

This project is designed so that **no secrets are ever stored on disk**:

- The Application Insights connection string is fetched at runtime via `az cli`
  and passed to the container as an in-memory environment variable.
- Configuration files reference `${APPLICATIONINSIGHTS_CONNECTION_STRING}` only —
  never the literal value.

If you find a connection string, instrumentation key, subscription ID, or other
identifier committed to the repository (including git history), treat it as a
vulnerability and report it so it can be rotated and purged.

## Security & GHAS setup (after publishing)

These are repository **Settings** toggles to enable once the repo is public
(under **Settings → Code security**). They are free for public repositories.

- [ ] **Secret scanning** — detects committed credentials.
- [ ] **Push protection** — blocks commits that contain detected secrets before
      they reach the remote.
- [ ] **Dependabot alerts** — notifies on vulnerable dependencies.
- [ ] **Dependabot security updates** — opens PRs to patch them.
- [ ] **Private vulnerability reporting** — lets researchers report issues
      privately (see above).

Dependabot **version** updates for GitHub Actions are already configured in
[`.github/dependabot.yml`](.github/dependabot.yml).

> **CodeQL code scanning is intentionally not used.** CodeQL does not support
> PowerShell or YAML, which are the only languages in this repo. Static analysis
> is instead covered by PSScriptAnalyzer and secret scanning by `gitleaks`, both
> running in the `lint` workflow.

## Supported versions

This is a single-track tool; only the latest `main` is maintained.
