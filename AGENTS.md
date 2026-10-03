# Apple Calendar Helper

Bridges local scripts and agents to Apple Calendar through EventKit. See README.md for setup.

## Use

- The helper must be running: `open -a "Apple Calendar Helper"` (after the first launch from `build/`).
- Send commands with `./calendar-helper-submit <command> [args...]`.
- Read-only checks: `list-calendars`, `dump-events`.
- Runtime files live in `~/Library/Application Support/apple-calendar-helper/` unless `CALENDAR_HELPER_HOME` is set.

## Safety

- `create-events`, `update-all-day-end`, `delete-event`, and `delete-event-series` change real calendars. Run them only when the user asked for that change.
- Do not print private calendar data unnecessarily.
- Repeating events share one ID. To change one occurrence, pass its `startDate` from `dump-events` as the last argument.
- If a command times out after the helper picked it up, it may have run. Check with `dump-events` before retrying a write.

## Checks

```bash
./build.sh                                   # macOS only
python3 -m unittest discover -s tests
```
