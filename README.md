# OpenCode Limit Tracker

Ruby CLI for OpenCode Go usage limits. It follows the same mental model as the reference tracker while using only OpenCode data sources.

## Data source

The tracker reads OpenCode's authenticated usage endpoint:

`https://opencode.ai/zen/go/v1/usage`

The endpoint returns the OpenCode-native `rolling`, `weekly`, and `monthly` windows with status, used percentage, and reset time. The API key is read from the existing OpenCode auth file (`opencode-go.key`) and is never printed or written to the repository. This installation uses `~/.local/share/opencode/auth.json`; `XDG_DATA_HOME` and `OPENCODE_AUTH_FILE` are also supported.

OpenCode's local database contains session-level token/cost statistics, but not the server-side subscription windows. It is deliberately not used to estimate quota values. If the endpoint is temporarily unavailable, the latest sanitized API response stored in `~/.local/share/opencode/limit_tracker_daily_snapshot.json` is used. There is no scraping or provider-independent quota fallback.

This endpoint is an OpenCode product API rather than a documented public CLI contract. Its path or response shape may change; the script fails clearly when supported fields are unavailable. No Codex binary, command, state directory, or session log is accessed.

## Usage

```bash
./opencode_limit_tracker.rb
./opencode_limit_tracker.rb --json
./opencode_limit_tracker.rb --refresh
./opencode_limit_tracker.rb --help
```

`--refresh` forces the live API request. Live data is requested by default too; the flag is provided for CLI compatibility and clarity. Weekly data drives the morning baseline and daily budget calculation. Rolling and monthly windows are displayed when OpenCode provides them.

JSON output is a single machine-readable object. It contains the stable weekly/daily fields plus `limits`, which preserves OpenCode's native windows and adds `left_percent`.

## macOS global command

```bash
chmod +x /Users/atilla/Documents/1_Projects/opencode_limit_tracker/opencode_limit_tracker.rb
ln -sf /Users/atilla/Documents/1_Projects/opencode_limit_tracker/opencode_limit_tracker.rb /usr/local/bin/opencode-limit-tracker
```

Then run `opencode-limit-tracker` from any directory. If `/usr/local/bin` is not writable, create the symlink with the appropriate administrator privileges.
