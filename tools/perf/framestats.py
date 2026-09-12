#!/usr/bin/env python3
"""Parser for `adb shell dumpsys gfxinfo <pkg> framestats` output.

Reads the PROFILEDATA section(s) of a gfxinfo dump and computes frame-timing
metrics: total frame duration, jank rate (by both the reported per-frame
deadline and by the raw vsync budget), and a per-stage latency breakdown.

Why this exists instead of trusting the AOSP framestats column docs: a real
capture from an API-36 x86_64 emulator (perf-results/samples/framestats-sample.txt)
emits 24 columns, not the 23 the AOSP docs describe, in a device-specific order
(the extra column is WorkloadTarget). A parser that assumes a fixed column
layout silently mis-reads data on any device that differs -- this one indexes
every column strictly by the name in that capture's own header line, never by
position.

Column set is per-device/per-OS-version, so headers are re-read on every
PROFILEDATA block rather than assumed constant across a whole capture file.

Usage:
    framestats.py <file>          # one JSON object on stdout (default)
    framestats.py <file> --summary  # human-readable table
    cat dump.txt | framestats.py    # reads stdin if no file is given

Exit status is non-zero (with a message on stderr) if the input has no
PROFILEDATA section, a header is missing a column this tool needs, or zero
frames survive filtering -- a silently-empty 0%-jank result would be worse
than a hard failure.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Sequence, Tuple

PROFILEDATA_DELIM = "---PROFILEDATA---"

# Columns this tool actually reads. Missing any of these from a block's header
# is fatal (raised as MissingColumnError naming the column) because every
# metric below depends on at least one of them. Columns present in a real
# capture but never read here (Vsync, InputEventId, FrameStartTime,
# WorkloadTarget, SwapBuffers, DequeueBufferDuration, QueueBufferDuration,
# GpuCompleted, SwapBuffersCompleted, DisplayPresentTime,
# CommandSubmissionCompleted) are intentionally NOT required, so this parser
# keeps working on devices/OS versions that drop or rename them.
REQUIRED_COLUMNS = (
    "Flags",
    "IntendedVsync",
    "FrameCompleted",
    "FrameDeadline",
    "FrameInterval",
    "HandleInputStart",
    "AnimationStart",
    "PerformTraversalsStart",
    "DrawStart",
    "SyncQueued",
    "IssueDrawCommandsStart",
)

# Present on newer platform versions only; used to sharpen frame-dedup when
# available, but its absence must not break parsing.
OPTIONAL_DEDUP_COLUMN = "FrameTimelineVsyncId"


class FramestatsError(Exception):
    """Base class for errors this tool raises on purpose (clear, user-facing)."""


class NoProfileDataError(FramestatsError):
    pass


class MissingColumnError(FramestatsError):
    pass


class NoUsableFramesError(FramestatsError):
    pass


@dataclass
class ParsedFrames:
    raw_row_count: int
    block_row_counts: List[int]
    unique_rows: List[Dict[str, int]] = field(default_factory=list)


def _split_blocks(text: str) -> List[str]:
    """Split the dump on PROFILEDATA delimiter lines.

    Returns the text following each delimiter (there can be several: a capture
    script polls repeatedly and appends, so one file may hold many overlapping
    120-frame snapshots). Raises if the delimiter never appears at all, rather
    than silently treating unrelated text as frame data.
    """
    lines = text.splitlines()
    delim_indices = [i for i, line in enumerate(lines) if line.strip() == PROFILEDATA_DELIM]
    if not delim_indices:
        raise NoProfileDataError(
            f"no '{PROFILEDATA_DELIM}' marker found in input; "
            "is this `dumpsys gfxinfo <pkg> framestats` output?"
        )
    blocks = []
    for n, start in enumerate(delim_indices):
        end = delim_indices[n + 1] if n + 1 < len(delim_indices) else len(lines)
        blocks.append(lines[start + 1 : end])
    return blocks


def _parse_header(line: str) -> Optional[List[str]]:
    """Return column names if `line` is a header row, else None.

    A header is recognised by the literal field name "Flags" appearing among
    its comma-separated fields -- checked by membership, not position, since
    column order is device-specific. Data rows never contain that literal
    (their Flags field is a small integer), so this is unambiguous.
    """
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.endswith(","):
        stripped = stripped[:-1]
    fields = stripped.split(",")
    if "Flags" in fields:
        return fields
    return None


def _parse_data_row(line: str, header: Sequence[str]) -> Optional[Dict[str, int]]:
    """Return a name->int dict if `line` is a data row matching `header`, else None."""
    stripped = line.strip()
    if not stripped:
        return None
    if stripped.endswith(","):
        stripped = stripped[:-1]
    fields = stripped.split(",")
    if len(fields) != len(header):
        return None
    try:
        values = [int(f) for f in fields]
    except ValueError:
        return None
    return dict(zip(header, values))


def _check_required_columns(header: Sequence[str], block_index: int) -> None:
    missing = [c for c in REQUIRED_COLUMNS if c not in header]
    if missing:
        raise MissingColumnError(
            f"framestats block {block_index}: missing required column(s) "
            f"{missing!r}; header was {list(header)!r}"
        )


def _dedup_key(row: Dict[str, int]) -> Tuple[int, Optional[int]]:
    # Two rows are the same frame iff IntendedVsync matches (and
    # FrameTimelineVsyncId too, when the column is present). row.get() returns
    # None uniformly for every row when the column is absent from every
    # header, which collapses this to a plain IntendedVsync match.
    return (row["IntendedVsync"], row.get(OPTIONAL_DEDUP_COLUMN))


def parse_framestats(text: str) -> ParsedFrames:
    """Parse raw dumpsys text into deduplicated per-frame rows.

    Rows are deduplicated across all PROFILEDATA blocks by (IntendedVsync,
    FrameTimelineVsyncId): the device returns its last 120 frames on every
    poll without deduplicating, so a multi-poll capture overlaps heavily.
    Later occurrences win ties, since a frame that was still in-flight (and so
    had unreliable completion timestamps) on an earlier poll is more likely to
    have settled by a later one.
    """
    blocks = _split_blocks(text)
    raw_row_count = 0
    block_row_counts: List[int] = []
    ordered_rows: Dict[Tuple[int, Optional[int]], Dict[str, int]] = {}

    for block_index, block_lines in enumerate(blocks):
        header: Optional[List[str]] = None
        row_count = 0
        for line in block_lines:
            if header is None:
                header = _parse_header(line)
                if header is not None:
                    _check_required_columns(header, block_index)
                continue
            row = _parse_data_row(line, header)
            if row is None:
                # Blank line, or trailing dumpsys text (e.g. "View hierarchy:")
                # after the last data row -- this block's data is over.
                break
            ordered_rows[_dedup_key(row)] = row
            row_count += 1
        if header is not None:
            block_row_counts.append(row_count)
            raw_row_count += row_count

    return ParsedFrames(
        raw_row_count=raw_row_count,
        block_row_counts=block_row_counts,
        unique_rows=list(ordered_rows.values()),
    )


def percentile(sorted_values: Sequence[float], pct: float) -> float:
    """Linear-interpolation percentile (numpy's default 'linear' method).

    For N values this is exact and symmetric: p50 on an even-length list is
    the average of the two middle values, matching statistics.median.
    """
    if not sorted_values:
        raise ValueError("percentile() called on an empty sequence")
    if len(sorted_values) == 1:
        return sorted_values[0]
    rank = (len(sorted_values) - 1) * (pct / 100.0)
    lo = int(rank)
    hi = min(lo + 1, len(sorted_values) - 1)
    frac = rank - lo
    if lo == hi:
        return sorted_values[lo]
    return sorted_values[lo] * (1 - frac) + sorted_values[hi] * frac


def _stage_stats_ms(
    rows: Sequence[Dict[str, int]], start_col: str, end_col: str
) -> Tuple[Optional[Dict[str, float]], int]:
    """Percentile stats of (row[end_col] - row[start_col]) in ms, over rows where that gap is >= 0.

    Returns {p50, p90, p95, p99, max, mean} (None if no row survives) plus a
    count of rows excluded from THIS stage only.

    Full percentiles, not just a median, matter here: during a fling most
    frames do zero per-item work (e.g. RecyclerView binds no new row), so a
    per-bind cost that only some frames pay is invisible at p50 by
    construction and shows up only in the tail (p95/p99/max) -- reporting
    only a median would make an expensive per-item cost look free.

    A negative gap means end_col's timestamp precedes start_col's, which is
    physically impossible for a real stage -- it indicates a corrupted
    timestamp in that specific row (see the module-level caveats this feeds
    into), not a fast/instant stage. Such rows are excluded from just this
    stage's stats (they still count toward every other metric) and the
    exclusion is counted so it can be reported, never silently dropped.
    """
    values = []
    excluded = 0
    for r in rows:
        delta_ns = r[end_col] - r[start_col]
        if delta_ns < 0:
            excluded += 1
            continue
        values.append(delta_ns / 1e6)
    if not values:
        return None, excluded
    sorted_values = sorted(values)
    stats = {
        "p50": percentile(sorted_values, 50),
        "p90": percentile(sorted_values, 90),
        "p95": percentile(sorted_values, 95),
        "p99": percentile(sorted_values, 99),
        "max": sorted_values[-1],
        "mean": sum(sorted_values) / len(sorted_values),
    }
    return stats, excluded


def compute_metrics(unique_rows: Sequence[Dict[str, int]]) -> dict:
    """Compute jank/duration/stage metrics over deduplicated frame rows.

    Raises NoUsableFramesError if every row is excluded (all Flags != 0, all
    remaining rows physically impossible, or the input was empty) -- callers
    must not report a 0%-jank result computed over zero frames.
    """
    excluded_flagged = [r for r in unique_rows if r["Flags"] != 0]
    flags_ok = [r for r in unique_rows if r["Flags"] == 0]

    # A frame cannot complete before its own intended vsync: FrameCompleted <=
    # IntendedVsync is physically impossible and is a known gfxinfo artifact --
    # the most recently buffered frame can still be in flight (and so carry a
    # stale/incomplete FrameCompleted timestamp left over from an earlier
    # ring-buffer cycle) at the moment the dump is taken. These rows are
    # EXCLUDED from every metric below (not just noted), since leaving them in
    # silently corrupts min/mean for anyone reading the JSON without reading
    # the caveats.
    excluded_invalid = [r for r in flags_ok if r["FrameCompleted"] <= r["IntendedVsync"]]
    usable = [r for r in flags_ok if r["FrameCompleted"] > r["IntendedVsync"]]
    if not usable:
        raise NoUsableFramesError(
            f"0 usable frames out of {len(unique_rows)} unique frame(s) "
            f"({len(excluded_flagged)} flagged, {len(excluded_invalid)} physically "
            "impossible); nothing to compute metrics from"
        )

    caveats: List[str] = []
    if excluded_invalid:
        caveats.append(
            f"{len(excluded_invalid)} frame(s) had FrameCompleted <= IntendedVsync "
            "(physically impossible -- a frame cannot complete before its own "
            "intended vsync). This is a known gfxinfo artifact: the most recently "
            "buffered frame can still be in flight -- and so carry a stale/incomplete "
            "FrameCompleted timestamp from an earlier ring-buffer cycle -- at the "
            "moment the dump is taken. Excluded from all metrics (see "
            "excludedInvalid) rather than left in to skew min/mean."
        )

    durations_ns = [r["FrameCompleted"] - r["IntendedVsync"] for r in usable]
    durations_ms = [d / 1e6 for d in durations_ns]

    sorted_ms = sorted(durations_ms)
    duration_stats = {
        "min": sorted_ms[0],
        "max": sorted_ms[-1],
        "mean": sum(sorted_ms) / len(sorted_ms),
        "p50": percentile(sorted_ms, 50),
        "p90": percentile(sorted_ms, 90),
        "p95": percentile(sorted_ms, 95),
        "p99": percentile(sorted_ms, 99),
    }

    # --- jank by reported deadline, with a per-row fallback to the budget test
    janky_deadline = 0
    deadline_fallback_rows = 0
    budget_unknown_rows = 0
    janky_budget = 0
    budget_usable = 0
    for r, dur_ns in zip(usable, durations_ns):
        deadline = r["FrameDeadline"]
        interval = r["FrameInterval"]
        if deadline > 0:
            if r["FrameCompleted"] > deadline:
                janky_deadline += 1
        else:
            deadline_fallback_rows += 1
            if interval > 0 and dur_ns > interval:
                janky_deadline += 1

        # Budget-based jank always uses this row's own FrameInterval -- never
        # a hardcoded 16.67ms -- since refresh rate can vary per capture.
        if interval <= 0:
            budget_unknown_rows += 1
            continue
        budget_usable += 1
        if dur_ns > interval:
            janky_budget += 1

    if budget_unknown_rows:
        caveats.append(
            f"{budget_unknown_rows} usable frame(s) had FrameInterval <= 0 and were "
            "excluded from the budget-based jank rate (denominator reduced accordingly)."
        )

    # Stage breakdown (medians, ms). Each is one adjacent-timestamp subtraction
    # over AOSP's FrameInfo columns. These are phase ATTRIBUTIONS bucketed to
    # keep the list short, not independently verified as non-overlapping --
    # the bracketing matters more than any single number:
    #   inputHandlingMs = AnimationStart - HandleInputStart
    #       UI thread: consuming queued input events, before animation
    #       evaluation starts.
    #   animationMs     = PerformTraversalsStart - AnimationStart
    #       UI thread: evaluating animators/transitions, before layout
    #       traversal starts.
    #   traversalDrawMs = SyncQueued - PerformTraversalsStart
    #       UI thread: measure/layout + draw-list recording (DrawStart falls
    #       inside this span but isn't split out), ending when the display
    #       list is queued for RenderThread sync.
    #   syncMs          = IssueDrawCommandsStart - SyncQueued
    #       Hand-off latency: waiting for RenderThread to pick up the sync
    #       plus the sync itself, ending when RT starts issuing GL/Vulkan
    #       commands.
    #   gpuSwapMs       = FrameCompleted - IssueDrawCommandsStart
    #       RenderThread command issue + buffer swap + GPU execution, bundled
    #       into one bucket ending at FrameCompleted (SwapBuffers/GpuCompleted
    #       are not required columns, so are not split out).
    # Each stage reports full percentiles, not just a median: during a fling
    # most frames do zero per-item work (e.g. a RecyclerView binds no new row
    # unless one scrolls into view), so a per-bind cost that only some frames
    # pay is invisible at p50 by construction -- it only shows up in the tail
    # (p95/p99/max). A median-only report would make an expensive per-item
    # cost look free. Each stage excludes, from ITS OWN stats only, any row
    # where that stage's subtraction would be negative (see _stage_stats_ms)
    # -- the row still counts everywhere else (overall duration, jank, other
    # stages).
    stage_defs = (
        ("inputHandling", "HandleInputStart", "AnimationStart"),
        ("animation", "AnimationStart", "PerformTraversalsStart"),
        ("traversalDraw", "PerformTraversalsStart", "SyncQueued"),
        ("sync", "SyncQueued", "IssueDrawCommandsStart"),
        ("gpuSwap", "IssueDrawCommandsStart", "FrameCompleted"),
    )
    stage_stats: Dict[str, Optional[Dict[str, float]]] = {}
    stage_exclusions: Dict[str, int] = {}
    for name, start_col, end_col in stage_defs:
        stats, excluded = _stage_stats_ms(usable, start_col, end_col)
        stage_stats[name] = stats
        stage_exclusions[name] = excluded

    # uiThreadMs: UI-thread-only time per frame, from the start of input
    # handling through the start of draw-list recording --
    # DrawStart - HandleInputStart -- i.e. the input-handling, animation, and
    # traversal (PerformTraversalsStart -> DrawStart) stages summed (the
    # telescoping sum of adjacent subtractions collapses to this one). It
    # does NOT include the DrawStart -> SyncQueued draw-list-recording span
    # (also UI-thread work, folded into "traversalDraw" above instead -- which
    # is why traversalDraw, not uiThreadMs, is the better per-item-bind-cost
    # proxy), so this is a LOWER BOUND on total UI-thread involvement. Use it
    # for the intended purpose of comparing against gpuSwap to see whether
    # UI-thread work is even visible in end-to-end frame time.
    ui_thread_stats, ui_thread_excluded = _stage_stats_ms(usable, "HandleInputStart", "DrawStart")
    stage_exclusions["uiThread"] = ui_thread_excluded

    for name, excluded in stage_exclusions.items():
        if excluded:
            caveats.append(
                f"{excluded} row(s) excluded from the '{name}' stage/uiThreadMs "
                "percentiles because that span's own timestamps implied a negative "
                "duration (a corrupted-row artifact, same family as excludedInvalid "
                "above). Still counted in usableFrameCount, frameDurationMs, and jank."
            )

    n_usable = len(usable)
    result = {
        "rawRowCount": None,  # filled in by analyze()
        "blockCount": None,  # filled in by analyze()
        "uniqueFrameCount": len(unique_rows),
        "excludedFlagged": len(excluded_flagged),
        "excludedInvalid": len(excluded_invalid),
        "usableFrameCount": n_usable,
        "deadlineFallbackRows": deadline_fallback_rows,
        "frameDurationMs": duration_stats,
        "jankyFramesDeadline": {
            "count": janky_deadline,
            "percent": 100.0 * janky_deadline / n_usable,
        },
        "jankyFramesBudget": {
            "count": janky_budget,
            "percent": (100.0 * janky_budget / budget_usable) if budget_usable else None,
        },
        "stageMs": stage_stats,
        "uiThreadMs": ui_thread_stats,
        "stageExclusions": stage_exclusions,
        "caveats": caveats,
    }
    return result


def analyze(text: str) -> dict:
    parsed = parse_framestats(text)
    result = compute_metrics(parsed.unique_rows)
    result["rawRowCount"] = parsed.raw_row_count
    result["blockCount"] = len(parsed.block_row_counts)
    return result


def _fmt_ms(value: Optional[float]) -> str:
    return f"{value:.3f}" if value is not None else "n/a"


def _fmt_stage_row(label: str, stats: Optional[Dict[str, float]]) -> str:
    if stats is None:
        return f"  {label:<15}" + "  n/a" * 6
    return "  {:<15}{:>8}{:>8}{:>8}{:>8}{:>8}{:>8}".format(
        label,
        _fmt_ms(stats["p50"]),
        _fmt_ms(stats["p90"]),
        _fmt_ms(stats["p95"]),
        _fmt_ms(stats["p99"]),
        _fmt_ms(stats["max"]),
        _fmt_ms(stats["mean"]),
    )


def format_summary(result: dict) -> str:
    d = result["frameDurationMs"]
    jd = result["jankyFramesDeadline"]
    jb = result["jankyFramesBudget"]
    sm = result["stageMs"]
    lines = [
        f"raw rows            : {result['rawRowCount']} (across {result['blockCount']} block(s))",
        f"unique frames        : {result['uniqueFrameCount']}",
        f"excluded (Flags!=0)  : {result['excludedFlagged']}",
        f"excluded (invalid)   : {result['excludedInvalid']}",
        f"usable frames        : {result['usableFrameCount']}",
        "",
        "frame duration (ms)  : min={:.3f} mean={:.3f} p50={:.3f} p90={:.3f} p95={:.3f} p99={:.3f} max={:.3f}".format(
            d["min"], d["mean"], d["p50"], d["p90"], d["p95"], d["p99"], d["max"]
        ),
        f"janky (by deadline)  : {jd['count']} ({jd['percent']:.2f}%)"
        f"  [{result['deadlineFallbackRows']} row(s) used the budget fallback]",
        "janky (by budget)    : "
        + (f"{jb['count']} ({jb['percent']:.2f}%)" if jb["percent"] is not None else f"{jb['count']} (n/a%)"),
        "",
        # traversalDraw and gpuSwap lead the table: traversalDraw brackets
        # RecyclerView bind/traversal work (the per-item-bind-cost proxy),
        # gpuSwap is what it is usually compared against to judge whether a
        # UI-thread fix is even visible in end-to-end frame time.
        "stage percentiles (ms):",
        "  {:<15}{:>8}{:>8}{:>8}{:>8}{:>8}{:>8}".format("stage", "p50", "p90", "p95", "p99", "max", "mean"),
        _fmt_stage_row("traversalDraw", sm["traversalDraw"]),
        _fmt_stage_row("gpuSwap", sm["gpuSwap"]),
        _fmt_stage_row("inputHandling", sm["inputHandling"]),
        _fmt_stage_row("animation", sm["animation"]),
        _fmt_stage_row("sync", sm["sync"]),
        _fmt_stage_row("uiThread", result["uiThreadMs"]),
    ]
    if result["caveats"]:
        lines.append("")
        lines.append("caveats:")
        for c in result["caveats"]:
            lines.append(f"  - {c}")
    return "\n".join(lines)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        description="Parse `adb shell dumpsys gfxinfo <pkg> framestats` output into jank metrics."
    )
    parser.add_argument(
        "file", nargs="?", help="path to a captured framestats dump; omit (or '-') to read stdin"
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--json", action="store_true", help="emit one JSON object on stdout (default)")
    group.add_argument("--summary", action="store_true", help="emit a human-readable summary table")
    args = parser.parse_args(argv)

    if args.file and args.file != "-":
        with open(args.file, "r", encoding="utf-8", errors="replace") as f:
            text = f.read()
    else:
        text = sys.stdin.read()

    try:
        result = analyze(text)
    except FramestatsError as exc:
        print(f"framestats: {exc}", file=sys.stderr)
        return 1

    if args.summary:
        print(format_summary(result))
    else:
        print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
