# Apple Calendar Helper

Let your AI agents and scripts read and write every calendar on your Mac.

Apple has no API that covers every calendar in the Calendar app. iCloud speaks CalDAV, but only for iCloud calendars, and it needs an app-specific password. EventKit sees every account on the Mac, but it only works inside an app the user has granted calendar access, and agents usually run in a terminal or over SSH. This helper is that app. Anything that can write a file can ask it to do calendar work.

![Real output from a test calendar: a batch with one bad event, then deleting one occurrence of a repeating event](docs/screenshot.png)

## Try it

Needs a Mac and the Xcode command line tools (`xcode-select --install`).

```bash
git clone https://github.com/davideiffert/apple-calendar-helper
cd apple-calendar-helper
./build.sh
open "build/Apple Calendar Helper.app"
./calendar-helper-submit list-calendars
```

The first launch shows the macOS calendar permission prompt. Click Allow. `list-calendars` waits for that, then prints each account, calendar name, and ID. After the first launch, `open -a "Apple Calendar Helper"` starts it from anywhere.

## How it works

1. The helper runs in the background with calendar access and watches a folder.
2. `calendar-helper-submit` drops a JSON command into that folder and waits for the answer.
3. The helper runs the command through EventKit and writes the result back.

The folder is `~/Library/Application Support/apple-calendar-helper/`. To use a different one, set `CALENDAR_HELPER_HOME` for the submit script and start the helper with `open --env CALENDAR_HELPER_HOME=/your/folder "build/Apple Calendar Helper.app"`.

The helper has no window or Dock icon. To stop it, run `pkill -x calendar-helper`. To keep it running after a reboot, add `Apple Calendar Helper.app` to System Settings > General > Login Items. Copy it to `/Applications` first if you plan to delete the build folder.

To call the submit script from anywhere, link it onto your PATH, for example `ln -s "$PWD/calendar-helper-submit" /usr/local/bin/`.

Point your agent at [AGENTS.md](AGENTS.md) for the short version.

## Commands

| Command | Arguments | Changes calendars |
|---|---|---|
| `list-calendars` | none | No |
| `dump-events` | `<account> <calendar> <start yyyy-mm-dd> <end yyyy-mm-dd> <output.json>` | No |
| `create-events` | `<input.json> <receipt.json>` | Yes |
| `update-all-day-end` | `<event-id> <exclusive end yyyy-mm-dd> <receipt.json> [occurrence-start]` | Yes |
| `delete-event` | `<event-id> <receipt.json> [occurrence-start]` | Yes |
| `delete-event-series` | `<event-id> <receipt.json> [occurrence-start]` (that occurrence and later ones) | Yes |

- `<account>` is the account name from `list-calendars`, such as `iCloud`. `<calendar>` is a calendar name or its ID from `list-calendars`. Use the ID when two calendars share a name. `dump-events` also accepts `'*'` (quoted) for every calendar in the account.
- `dump-events` includes the start date and stops before the end date. It covers at most 4 years per call, which is EventKit's limit.
- Event IDs and start dates come from `dump-events` and from the receipts the write commands save. A repeating event shares one ID across all its occurrences, so changing one needs `[occurrence-start]`: the occurrence's `startDate` exactly as `dump-events` printed it.
- In `dump-events` output, an all-day event's `endDate` is the last second of its last day, as EventKit reports it. Date-only values use the Mac's time zone. Relative file paths are resolved from the directory you ran the command in.
- Write commands check that the receipt file can be written before they change anything.

```bash
./calendar-helper-submit dump-events iCloud Work 2026-10-01 2026-10-08 events.json
```

`create-events` takes a JSON array:

```json
[
  {
    "sourceTitle": "iCloud",
    "calendarTitle": "Work",
    "title": "Planning",
    "startDate": "2026-10-06T16:00:00Z",
    "endDate": "2026-10-06T17:00:00Z",
    "isAllDay": false,
    "recurrence": null,
    "recurrenceEndDate": null,
    "notes": null,
    "location": null
  }
]
```

For all-day events, use `yyyy-mm-dd` dates with an exclusive end date, so a one-day event on October 6 ends `2026-10-07`. `recurrence` can be `yearly`, `weekly`, `biweekly`, or `monthly-third-wednesday`. All but `yearly` need a `recurrenceEndDate`, written as `yyyy-mm-dd` or ISO 8601. `calendarTitle` also accepts a calendar ID.

If some events in a batch fail, the others are still created. The output says how many, and the receipt lists the ones that were created.

## When something goes wrong

Results print as `key=value` lines (`list-calendars` prints one tab-separated row per calendar). Failures exit non-zero and say what to do next:

```
error=calendar not found: iCloud/Wrok. Run list-calendars to see account and calendar names
error=the helper is not running. Start it with: open -a "Apple Calendar Helper"
error=bad input events.json: missing field "calendarTitle" at item 0. See the create-events example in README.md
```

If a command times out, the message says whether it ran. A command the helper had already picked up may have changed the calendar, so check with `dump-events` before retrying. The helper's own state is in `status.json` and `last-run.txt` in its folder.

## Limits

- macOS only, and the helper has to be running.
- Any process running as your user can drop a command in the folder. That is the same trust as your user account, but it means a misbehaving script can change your calendar.
- The build uses an ad-hoc signature, so macOS treats every rebuild as a new app and asks for calendar permission again. If you click Don't Allow, macOS will not ask again on its own. Run `tccutil reset Calendar io.github.davideiffert.apple-calendar-helper`, then `open -a "Apple Calendar Helper"` and click Allow. Set `SIGN_IDENTITY` to your own signing certificate to keep permission across rebuilds.
- Commands run one at a time, about one per second.
- Recurrence covers only the options above, not the full iCalendar set. No reminders, attendees, or alarms.
- Tested on macOS 26 on Apple silicon, including repeating events across a daylight saving change.

## Status

Maintained. Issues and pull requests are welcome.

## Contributing

Bug reports and small fixes are welcome. Please run the tests before opening a pull request, and test calendar changes against a throwaway calendar.

## Development

```bash
./build.sh                                # macOS only
python3 -m unittest discover -s tests     # runs anywhere
```

GitHub Actions builds the app on macOS and runs the tests. The calendar commands need a Mac with calendar access, so they are tested by hand against a throwaway calendar. See [CHANGELOG.md](CHANGELOG.md).

## License

MIT
