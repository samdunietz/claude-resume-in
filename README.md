# claude-resume-in

Schedule a Claude Code session to resume after a delay, once your Mac is awake. Useful for waiting for Claude rate-limits to reset.

## Install

```bash
git clone https://github.com/samdunietz/claude-resume-in.git ~/claude-resume-in \
  && ln -s ~/claude-resume-in/claude-resume-in ~/bin/claude-resume-in   # or anywhere on $PATH
```

Requires bash, `nc`, and `claude` on `$PATH`. macOS-only as written (uses `nc -G` and `date -r`).

## Usage

```
claude-resume-in <duration> [session-id] <prompt>
```

- **duration** — compact format like `5d10h30m30s`, `4h30m`, `90m`, `45s`, or plain seconds (`3600`). Units must be in `d → h → m → s` order.
- **session-id** — optional UUID. If omitted, snapshots the most recent session in the current directory at scheduling time and resumes *that* one.
- **prompt** — first message to send when the session resumes (required).

```bash
claude-resume-in 4h30m 948228a7-c941-4a6f-829a-86f8a5382a3e "Continue."
claude-resume-in 4h30m "Continue."   # auto-resolve to most recent session
```

## How it works

- **Wall-clock-anchored sleep.** The script sleeps in 60-second chunks, re-anchoring against `date +%s` each iteration. macOS's `sleep(1)` doesn't advance through system suspend, so a single long sleep would extend wake-up by the suspend duration. The bounded chunks sidestep it: `date +%s` (wall clock) does advance through suspend, so after wake the loop catches up within ~60s of the wall-clock target. Thus, `claude-resume-in 4h30m "Continue."` will fire within a minute of 4h30m after scheduling, even if your Mac sleeps in the interim.
- **Network wait before exec.** After wake, wifi may not be reconnected yet. The script polls `api.anthropic.com:443` (with a 3s connect timeout via `nc -G`) before launching `claude`.
- **Eager session resolution.** When the session ID is omitted, the script captures the most-recent session UUID from the working directory at scheduling time, not wake time. A session started during the sleep window can't replace the one you meant to resume.

## Notes

- Run in a terminal you'll leave open, or inside `tmux`/`screen`.
- Indefinite network outage at wake time will loop forever waiting for connectivity.
