# Changelog

## 0.1.0 - 2026-10-03

First public release.

- macOS app that holds calendar access and runs commands dropped into a folder.
- Commands: `list-calendars`, `dump-events`, `create-events`, `update-all-day-end`, `delete-event`, `delete-event-series`.
- `calendar-helper-submit` script that sends a command and prints the result.
- Errors explain the next step, including a stopped, never-started, or access-denied helper.
- Relative file paths resolve from the caller's directory.
