# Apple Calendar Helper

Bridges local scripts and agents to Apple Calendar through EventKit. README.md has the full field reference.

## Use

- The helper must be running: `open -a "Apple Calendar Helper"` (after the first launch from `build/`).
- Send commands with `./calendar-helper-submit <command> [args...]`.
- Commands: `list-calendars`, `dump-events`, `create-events`, `update-event`, `delete-event`.
- `dump-events` output uses the same fields that `create-events` and `update-event` take. To edit, dump, change fields, and send them back.
- Repeats are RRULE strings: `FREQ=MONTHLY;BYDAY=3WE` (third Wednesday), `FREQ=MONTHLY;BYDAY=-1FR` (last Friday), `FREQ=WEEKLY;INTERVAL=2;BYDAY=TU`, or `weekly`.
- Runtime files live in `~/Library/Application Support/apple-calendar-helper/` unless `CALENDAR_HELPER_HOME` is set.

## Safety

- `create-events`, `update-event`, and `delete-event` change real calendars. Run them only when the user asked for that change.
- Do not print private calendar data unnecessarily.
- Repeating events share one ID. Changing or deleting one needs the occurrence's `startDate` and a span: `this` (only it) or `future` (it and later ones). Choose the span the user meant. `future` from the first occurrence affects the whole series.
- If a command times out after the helper picked it up, it may have run. Check with `dump-events` before retrying a write.

## Checks

```bash
./build.sh   # macOS only
./test.sh
```
