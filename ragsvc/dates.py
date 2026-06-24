#!/usr/bin/env python3
"""Relative date words → (start, end) inclusive range.

Aggregation questions ("how much did I spend last month") need a time window
first. Rule-based, zero dependency; mainly Chinese, plus the identically-written
Japanese words (先週/今月). `today` is injectable for deterministic tests.

Timezone: `today` defaults to the process's local date, which is correct for the
local-first single-user deployment (the sidecar runs on the user's machine). A
cloud multi-user deployment would need to thread each user's timezone through the
request — deferred with the cloud form (see the plan), not a single-user bug.
"""
from __future__ import annotations

import datetime as dt
import re

_RECENT_DAYS = re.compile(r"最近\s*(\d+)\s*天")
_MONTH_N = re.compile(r"(\d{1,2})\s*月")
_RECENT_DAYS_EN = re.compile(r"\b(?:last|past)\s+(\d+)\s+days?\b", re.IGNORECASE)


def _week_start(d: dt.date) -> dt.date:
    return d - dt.timedelta(days=d.weekday())


def _month_end(year: int, month: int) -> dt.date:
    if month == 12:
        return dt.date(year, 12, 31)
    return dt.date(year, month + 1, 1) - dt.timedelta(days=1)


def parse_range(q: str, today: dt.date | None = None) -> tuple[dt.date, dt.date] | None:
    """Recognise a relative date phrase (Chinese, light Japanese, or English),
    return the inclusive (start, end); else None. Order-sensitive: 上个月 / "last
    month" before bare N月, 上周 / "last week" before "this week"."""
    t = today or dt.date.today()
    ql = q.lower()

    if "今天" in q or "今日" in q or "today" in ql:
        return (t, t)
    if "昨天" in q or "昨日" in q or "yesterday" in ql:
        y = t - dt.timedelta(days=1)
        return (y, y)
    if "前天" in q:
        p = t - dt.timedelta(days=2)
        return (p, p)
    if "上周" in q or "上星期" in q or "先週" in q or "last week" in ql:
        start = _week_start(t) - dt.timedelta(days=7)
        return (start, start + dt.timedelta(days=6))
    if "这周" in q or "本周" in q or "这星期" in q or "今週" in q or "this week" in ql:
        return (_week_start(t), t)
    if "上个月" in q or "上月" in q or "先月" in q or "last month" in ql:
        last_prev = t.replace(day=1) - dt.timedelta(days=1)
        return (last_prev.replace(day=1), last_prev)
    if "这个月" in q or "本月" in q or "今月" in q or "this month" in ql:
        return (t.replace(day=1), t)
    if "今年" in q or "this year" in ql:
        return (dt.date(t.year, 1, 1), t)
    if "去年" in q or "last year" in ql:
        return (dt.date(t.year - 1, 1, 1), dt.date(t.year - 1, 12, 31))

    m = _RECENT_DAYS.search(q) or _RECENT_DAYS_EN.search(q)
    if m:
        n = int(m.group(1))
        return (t - dt.timedelta(days=n - 1), t)

    m = _MONTH_N.search(q)
    if m:
        month = int(m.group(1))
        if 1 <= month <= 12:
            return (dt.date(t.year, month, 1), _month_end(t.year, month))

    return None
