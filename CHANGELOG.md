# Changelog

## 0.1.0 - 2026-10-03

First public release.

- macOS app that holds calendar access and runs commands dropped into a folder.
- Commands: `list-calendars`, `dump-events`, `create-events`, `update-event`, `delete-event`.
- Repeats use iCalendar RRULE strings (RFC 5545), within what EventKit can store, plus the words daily, weekly, monthly, and yearly.
- `dump-events` prints events in the same shape `create-events` and `update-event` read, including the RRULE and time zone.
- `update-event` changes any field, moves events between calendars, and handles one occurrence or this-and-future.
- Optional IANA `timeZone` on timed events.
- Batches are checked before anything is saved. Write commands keep a receipt.
- `calendar-helper-submit` sends a command and explains a stopped, never-started, or access-denied helper.
