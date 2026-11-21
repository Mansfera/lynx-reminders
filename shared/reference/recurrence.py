#!/usr/bin/env python3
"""Reference implementation of Lynx Reminders repeat rules (docs/SPEC.md §5).

This file is the source of truth. The Swift (apple/) and Kotlin (android/) ports must
produce exactly the same instants for every case in shared/vectors/*.json.
Run `python3 shared/reference/recurrence.py` to regenerate the vectors.
"""
from __future__ import annotations

import calendar
import json
import pathlib
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo

UTC = timezone.utc


# ---------- parsing / formatting ----------

def parse_instant(s: str) -> datetime:
    """ISO-8601 UTC instant like 2026-03-01T08:00:00Z."""
    return datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=UTC)


def fmt_instant(d: datetime) -> str:
    return d.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_local(s: str) -> datetime:
    """Local wall time like 2026-03-01T09:00 (no zone)."""
    return datetime.strptime(s, "%Y-%m-%dT%H:%M")


def fmt_local(d: datetime) -> str:
    return d.strftime("%Y-%m-%dT%H:%M")


def parse_hm(s: str) -> time:
    h, m = s.split(":")
    return time(int(h), int(m))


def to_utc(local: datetime, tz: ZoneInfo) -> datetime:
    """Wall time -> instant. Gaps resolve forward, overlaps to the earlier offset
    (same as java.time ZonedDateTime.of and Foundation Calendar)."""
    return local.replace(tzinfo=tz, fold=0).astimezone(UTC)


def to_local(instant: datetime, tz: ZoneInfo) -> datetime:
    return instant.astimezone(tz).replace(tzinfo=None)


def add_months(d: datetime, months: int, day: int) -> datetime:
    y, m = divmod(d.month - 1 + months, 12)
    y, m = d.year + y, m + 1
    last = calendar.monthrange(y, m)[1]
    return d.replace(year=y, month=m, day=min(day, last))


# ---------- the generator ----------

def generate(rule: dict, tz: ZoneInfo):
    """Yields every occurrence of the series as a UTC instant, ascending, starting at the anchor.
    Ignores `end` (callers apply it)."""
    anchor = parse_local(rule["anchor"])
    unit, n = rule["unit"], int(rule.get("interval", 1))
    assert n >= 1
    weekdays = sorted(set(rule.get("weekdays") or []))  # ISO 1=Mon..7=Sun

    if unit in ("minute", "hour"):
        step = timedelta(minutes=n * (1 if unit == "minute" else 60))
        window = rule.get("window")
        if window:
            ws, we = parse_hm(window["start"]), parse_hm(window["end"])
            d = anchor.date()
            while True:
                if not weekdays or d.isoweekday() in weekdays:
                    t = datetime.combine(d, ws)
                    while t.date() == d and t.time() <= we:
                        if t >= anchor:
                            yield to_utc(t, tz)
                        t += step
                d += timedelta(days=1)
        else:
            # Absolute durations: every N minutes of real time, DST does not shift the rhythm.
            start = to_utc(anchor, tz)
            k = 0
            while True:
                yield start + k * step
                k += 1

    elif unit == "day":
        k = 0
        while True:
            yield to_utc(anchor + timedelta(days=k * n), tz)
            k += 1

    elif unit == "week":
        if not weekdays:
            k = 0
            while True:
                yield to_utc(anchor + timedelta(weeks=k * n), tz)
                k += 1
        week0 = anchor.date() - timedelta(days=anchor.isoweekday() - 1)  # Monday
        w = 0
        while True:
            for wd in weekdays:
                d = week0 + timedelta(days=w * n * 7 + wd - 1)
                t = datetime.combine(d, anchor.time())
                if t >= anchor:
                    yield to_utc(t, tz)
            w += 1

    elif unit == "month":
        k = 0
        while True:
            yield to_utc(add_months(anchor, k * n, anchor.day), tz)
            k += 1

    elif unit == "year":
        k = 0
        while True:
            yield to_utc(add_months(anchor, k * n * 12, anchor.day), tz)
            k += 1
    else:
        raise ValueError(unit)


def within_end(rule: dict, instant: datetime, tz: ZoneInfo) -> bool:
    end = rule.get("end") or {"type": "never"}
    if end["type"] == "on":
        return to_local(instant, tz).date() <= date.fromisoformat(end["date"])
    return True  # "never"; "after" is counted in completions, see complete()


def next_after(rule: dict, tz: ZoneInfo, after: datetime) -> datetime | None:
    """First occurrence strictly after `after`, or None when the series has ended."""
    for occ in generate(rule, tz):
        if not within_end(rule, occ, tz):
            return None
        if occ > after:
            return occ
    return None


def upcoming(rule: dict, tz: ZoneInfo, after: datetime, limit: int) -> list[datetime]:
    out, t = [], after
    while len(out) < limit:
        nxt = next_after(rule, tz, t)
        if nxt is None:
            break
        out.append(nxt)
        t = nxt
    return out


def effective_due(rule: dict, tz: ZoneInfo, due_at: datetime, now: datetime) -> datetime:
    """advance == "auto": the series rolls forward without completion. The current slot is the
    latest occurrence <= now that is >= due_at; before due_at it is due_at itself."""
    if rule.get("advance", "complete") != "auto" or now < due_at:
        return due_at
    cur = due_at
    while True:
        nxt = next_after(rule, tz, cur)
        if nxt is None or nxt > now:
            return cur
        cur = nxt


def complete(rule: dict, tz: ZoneInfo, due_at: datetime, completed_at: datetime) -> dict:
    """What a completion does to a repeating reminder. Returns the new fields:
    {"completed": bool, "due_at": str, "repeat": {...}}"""
    rule = json.loads(json.dumps(rule))
    count = int(rule.get("completed_count", 0)) + 1
    rule["completed_count"] = count
    end = rule.get("end") or {"type": "never"}
    current = effective_due(rule, tz, due_at, completed_at)

    if end["type"] == "after" and count >= int(end["count"]):
        return {"completed": True, "due_at": fmt_instant(current), "repeat": rule}

    if rule.get("from", "due") == "completion":
        unit, n = rule["unit"], int(rule.get("interval", 1))
        anchor_time = parse_local(rule["anchor"]).time()
        done_local = to_local(completed_at, tz)
        if unit in ("minute", "hour"):
            nxt = completed_at + timedelta(minutes=n * (1 if unit == "minute" else 60))
            new_anchor = to_local(nxt, tz)
        else:
            base = datetime.combine(done_local.date(), anchor_time)
            if unit == "day":
                new_anchor = base + timedelta(days=n)
            elif unit == "week":
                new_anchor = base + timedelta(weeks=n)
            elif unit == "month":
                new_anchor = add_months(base, n, base.day)
            else:
                new_anchor = add_months(base, n * 12, base.day)
            nxt = to_utc(new_anchor, tz)
        rule["anchor"] = fmt_local(new_anchor.replace(second=0, microsecond=0))
        if not within_end(rule, nxt, tz):
            return {"completed": True, "due_at": fmt_instant(current), "repeat": rule}
        return {"completed": False, "due_at": fmt_instant(nxt), "repeat": rule}

    nxt = next_after(rule, tz, current)
    if nxt is None:
        return {"completed": True, "due_at": fmt_instant(current), "repeat": rule}
    return {"completed": False, "due_at": fmt_instant(nxt), "repeat": rule}


def nag_times(nag: dict, fired_at: datetime) -> list[datetime]:
    """Alert again every N minutes after the first alert, up to `max` times (null = 24h worth, capped at 48)."""
    every = int(nag["every_minutes"])
    mx = nag.get("max")
    if mx is None:
        mx = min(48, (24 * 60) // every)
    return [fired_at + timedelta(minutes=every * k) for k in range(1, int(mx) + 1)]


# ---------- vectors ----------

def R(**kw):
    return kw


NEXT_CASES = [
    ("daily 9:00", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-03-01T09:00"), "2026-03-01T07:00:00Z"),
    ("every 3 days across DST (wall time kept)", "Europe/Bratislava", R(unit="day", interval=3, anchor="2026-03-24T09:00"), "2026-03-24T09:00:00Z"),
    ("weekly no weekdays", "Europe/Bratislava", R(unit="week", interval=1, anchor="2026-01-07T18:30"), "2026-01-07T17:00:00Z"),
    ("every 2 weeks Mon+Thu", "Europe/Bratislava", R(unit="week", interval=2, weekdays=[1, 4], anchor="2026-01-07T08:00"), "2026-01-01T00:00:00Z"),
    ("weekdays 7:15", "Europe/Bratislava", R(unit="week", interval=1, weekdays=[1, 2, 3, 4, 5], anchor="2026-11-13T07:15"), "2026-11-13T12:00:00Z"),
    ("monthly on the 31st clamps", "Europe/Bratislava", R(unit="month", interval=1, anchor="2026-01-31T10:00"), "2026-01-31T09:00:00Z"),
    ("every 3 months", "America/New_York", R(unit="month", interval=3, anchor="2026-02-15T20:00"), "2026-02-16T00:00:00Z"),
    ("yearly Feb 29", "Europe/Bratislava", R(unit="year", interval=1, anchor="2028-02-29T09:00"), "2028-02-29T08:00:00Z"),
    ("every 90 minutes, absolute", "Europe/Bratislava", R(unit="minute", interval=90, anchor="2026-03-28T22:00"), "2026-03-28T21:00:00Z"),
    ("every 45 min in 09:00-18:00 window", "Europe/Bratislava", R(unit="minute", interval=45, window={"start": "09:00", "end": "18:00"}, anchor="2026-11-14T09:00"), "2026-11-14T16:00:00Z"),
    ("every 2 h 08-20 on weekdays", "Europe/Bratislava", R(unit="hour", interval=2, window={"start": "08:00", "end": "20:00"}, weekdays=[1, 2, 3, 4, 5], anchor="2026-11-13T08:00"), "2026-11-13T18:30:00Z"),
    ("daily ends on date", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-05-01T09:00", end={"type": "on", "date": "2026-05-03"}), "2026-04-30T00:00:00Z"),
    ("every 4 hours Tokyo", "Asia/Tokyo", R(unit="hour", interval=4, anchor="2026-06-01T06:00"), "2026-06-01T00:00:00Z"),
    ("every 10 days New York across fall DST", "America/New_York", R(unit="day", interval=10, anchor="2026-10-25T07:00"), "2026-10-25T12:00:00Z"),
]

EFFECTIVE_CASES = [
    ("auto 45 min window, mid afternoon", "Europe/Bratislava", R(unit="minute", interval=45, window={"start": "09:00", "end": "18:00"}, anchor="2026-11-14T09:00", advance="auto"), "2026-11-14T08:00:00Z", "2026-11-14T13:10:00Z"),
    ("auto daily, three days late", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-10T09:00", advance="auto"), "2026-11-10T08:00:00Z", "2026-11-13T10:00:00Z"),
    ("complete mode stays overdue", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-10T09:00"), "2026-11-10T08:00:00Z", "2026-11-13T10:00:00Z"),
    ("auto before first due", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-20T09:00", advance="auto"), "2026-11-20T08:00:00Z", "2026-11-13T10:00:00Z"),
]

COMPLETE_CASES = [
    ("daily completed on time", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-10T09:00"), "2026-11-10T08:00:00Z", "2026-11-10T08:05:00Z"),
    ("daily completed late keeps schedule", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-10T09:00"), "2026-11-10T08:00:00Z", "2026-11-12T19:00:00Z"),
    ("every 2 weeks Mon+Thu", "Europe/Bratislava", R(unit="week", interval=2, weekdays=[1, 4], anchor="2026-01-08T08:00"), "2026-01-08T07:00:00Z", "2026-01-08T07:30:00Z"),
    ("ends after 3, third completion", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-11-10T09:00", completed_count=2, end={"type": "after", "count": 3}), "2026-11-12T08:00:00Z", "2026-11-12T08:01:00Z"),
    ("ends on date, last one", "Europe/Bratislava", R(unit="day", interval=1, anchor="2026-05-01T09:00", end={"type": "on", "date": "2026-05-03"}), "2026-05-03T07:00:00Z", "2026-05-03T07:10:00Z"),
    ("from completion, every 3 days", "Europe/Bratislava", R(unit="day", interval=3, anchor="2026-11-01T09:00", **{"from": "completion"}), "2026-11-01T08:00:00Z", "2026-11-05T17:42:00Z"),
    ("from completion, every 2 hours", "Europe/Bratislava", R(unit="hour", interval=2, anchor="2026-11-14T10:00", **{"from": "completion"}), "2026-11-14T09:00:00Z", "2026-11-14T09:47:00Z"),
    ("from completion, monthly on the 31st", "Europe/Bratislava", R(unit="month", interval=1, anchor="2026-01-15T09:00", **{"from": "completion"}), "2026-01-15T08:00:00Z", "2026-01-31T12:00:00Z"),
    ("auto window, completing skips to next slot", "Europe/Bratislava", R(unit="minute", interval=45, window={"start": "09:00", "end": "18:00"}, anchor="2026-11-14T09:00", advance="auto"), "2026-11-14T08:00:00Z", "2026-11-14T13:10:00Z"),
    ("monthly clamp keeps the 31st", "Europe/Bratislava", R(unit="month", interval=1, anchor="2026-01-31T10:00"), "2026-02-28T09:00:00Z", "2026-02-28T09:30:00Z"),
]

NAG_CASES = [
    ("every 10 min, 3 times", {"every_minutes": 10, "max": 3}, "2026-11-14T08:00:00Z"),
    ("every 2 h, unlimited -> 12 in 24h", {"every_minutes": 120, "max": None}, "2026-11-14T08:00:00Z"),
    ("every 5 min, unlimited -> capped at 48", {"every_minutes": 5, "max": None}, "2026-11-14T08:00:00Z"),
]


def build_vectors() -> dict:
    out = {"next": [], "effective_due": [], "complete": [], "nag": []}
    for name, tzname, rule, after in NEXT_CASES:
        tz = ZoneInfo(tzname)
        exp = [fmt_instant(d) for d in upcoming(rule, tz, parse_instant(after), 6)]
        out["next"].append({"name": name, "time_zone": tzname, "repeat": rule, "after": after, "expect": exp})
    for name, tzname, rule, due, now in EFFECTIVE_CASES:
        tz = ZoneInfo(tzname)
        exp = fmt_instant(effective_due(rule, tz, parse_instant(due), parse_instant(now)))
        out["effective_due"].append({"name": name, "time_zone": tzname, "repeat": rule, "due_at": due, "now": now, "expect": exp})
    for name, tzname, rule, due, done in COMPLETE_CASES:
        tz = ZoneInfo(tzname)
        exp = complete(rule, tz, parse_instant(due), parse_instant(done))
        out["complete"].append({"name": name, "time_zone": tzname, "repeat": rule, "due_at": due, "completed_at": done, "expect": exp})
    for name, nag, fired in NAG_CASES:
        exp = [fmt_instant(d) for d in nag_times(nag, parse_instant(fired))]
        out["nag"].append({"name": name, "nag": nag, "fired_at": fired, "expect": exp})
    return out


if __name__ == "__main__":
    path = pathlib.Path(__file__).resolve().parents[1] / "vectors" / "recurrence.json"
    path.write_text(json.dumps(build_vectors(), indent=2) + "\n")
    print("wrote", path)
