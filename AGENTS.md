# Repository Guidelines

## Project Structure & Module Organization

This is a small macOS-focused Bash utility for connecting to ECNU VPN through `openconnect`.

- `ecnu-vpn.sh` is the executable entry point. It loads configuration, retrieves credentials, manages routes/DNS, and implements `up`, `down`, and `status`.
- `.env.example` documents supported local configuration. Copy it to `.env`; `.env` is ignored and must never be committed.
- `domains.txt` is the default split-tunnel domain allowlist (one domain per line; `#` comments are accepted).
- `clash-config.yaml` is an optional local client configuration and is ignored.
- `tmp/` holds generated wrappers, PID files, and logs; treat it as runtime output, not source.

## Development & Verification Commands

There is no build step or test framework. Before committing shell changes, run:

```bash
bash -n ecnu-vpn.sh       # validate Bash syntax without executing it
./ecnu-vpn.sh status      # safely check current connection state
```

For manual end-to-end verification on macOS, configure a private `.env`, then use `sudo bash ./ecnu-vpn.sh up --split` and `sudo bash ./ecnu-vpn.sh down`. This changes networking; do not run it casually. The script requires Homebrew's `openconnect`, its `vpnc-script`, and `dig` for split mode.

## Coding Style & Naming Conventions

Keep the script compatible with Bash and retain `set -euo pipefail`. Use two-space indentation in control blocks, `lower_snake_case` for functions, and uppercase names for configuration/environment variables (for example, `DOMAINS_FILE`). Quote variable expansions unless deliberate word splitting is needed. Prefer small functions with localized `local` variables, explicit error messages through `log`, and macOS-compatible utilities/options. Update comments when changing routing, DNS, or credential behavior.

## Testing Guidelines

Run `bash -n` for every script edit and exercise the affected command path manually when safe. For split-tunnel edits, test against a temporary domain list and confirm the generated wrapper and `tmp/ecnu-vpn.log`; avoid exposing credentials or tokens in logs, fixtures, or commits.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commit-like subjects such as `feat(split): add dynamic split-tunnel wrapper` and `refactor: replace vpn-slice`. Use concise imperative subjects with an optional scope. Keep commits focused. Pull requests should explain user-visible networking changes, list validation performed, link related issues when applicable, and include sanitized logs or screenshots only when they clarify behavior. Never commit `.env`, passwords, certificates, PID files, or logs.
