#!/usr/bin/env python3
"""Tests for framestats.py.

Run with: python3 -m unittest discover -s tools/perf
"""

import os
import unittest

from framestats import (
    MissingColumnError,
    NoUsableFramesError,
    analyze,
    compute_metrics,
    parse_framestats,
    percentile,
)

SAMPLE_PATH = os.path.join(os.path.dirname(__file__), "..", "..", "perf-results", "samples", "framestats-sample.txt")

# The device's real header, in the order it actually emits (24 columns,
# WorkloadTarget is the one AOSP docs don't list).
REAL_HEADER = (
    "Flags,FrameTimelineVsyncId,IntendedVsync,Vsync,InputEventId,HandleInputStart,"
    "AnimationStart,PerformTraversalsStart,DrawStart,FrameDeadline,FrameStartTime,"
    "FrameInterval,WorkloadTarget,SyncQueued,SyncStart,IssueDrawCommandsStart,"
    "SwapBuffers,FrameCompleted,DequeueBufferDuration,QueueBufferDuration,GpuCompleted,"
    "SwapBuffersCompleted,DisplayPresentTime,CommandSubmissionCompleted,"
)


def make_row(
    flags=0,
    frame_timeline_vsync_id=1000,
    intended_vsync=1_000_000_000,
    vsync=1_000_000_000,
    input_event_id=0,
    handle_input_start=1_000_100_000,
    animation_start=1_000_200_000,
    perform_traversals_start=1_000_300_000,
    draw_start=1_000_400_000,
    frame_deadline=1_016_666_666,
    frame_start_time=1_000_050_000,
    frame_interval=16_666_666,
    workload_target=16_666_666,
    sync_queued=1_000_500_000,
    sync_start=1_000_600_000,
    issue_draw_commands_start=1_000_700_000,
    swap_buffers=1_000_800_000,
    frame_completed=1_010_000_000,
    dequeue_buffer_duration=0,
    queue_buffer_duration=0,
    gpu_completed=1_009_000_000,
    swap_buffers_completed=1_010_500_000,
    display_present_time=0,
    command_submission_completed=1_000_900_000,
):
    """Build one data row (as a CSV string, trailing comma, real column order)."""
    values = [
        flags,
        frame_timeline_vsync_id,
        intended_vsync,
        vsync,
        input_event_id,
        handle_input_start,
        animation_start,
        perform_traversals_start,
        draw_start,
        frame_deadline,
        frame_start_time,
        frame_interval,
        workload_target,
        sync_queued,
        sync_start,
        issue_draw_commands_start,
        swap_buffers,
        frame_completed,
        dequeue_buffer_duration,
        queue_buffer_duration,
        gpu_completed,
        swap_buffers_completed,
        display_present_time,
        command_submission_completed,
    ]
    return ",".join(str(v) for v in values) + ","


def make_capture(rows, header=REAL_HEADER):
    return "---PROFILEDATA---\n" + header + "\n" + "\n".join(rows) + "\n"


class TestRealSample(unittest.TestCase):
    def test_real_sample_parses_120_rows_one_block(self):
        with open(SAMPLE_PATH, "r", encoding="utf-8") as f:
            text = f.read()
        parsed = parse_framestats(text)
        self.assertEqual(parsed.raw_row_count, 120)
        self.assertEqual(len(parsed.block_row_counts), 1)
        self.assertEqual(parsed.block_row_counts[0], 120)
        # No duplicate IntendedVsync values in a single un-overlapped capture.
        self.assertEqual(len(parsed.unique_rows), 120)

    def test_real_sample_yields_usable_metrics(self):
        with open(SAMPLE_PATH, "r", encoding="utf-8") as f:
            text = f.read()
        result = analyze(text)
        self.assertEqual(result["rawRowCount"], 120)
        self.assertEqual(result["uniqueFrameCount"], 120)
        self.assertEqual(result["excludedFlagged"], 0)
        # The real capture's last row has FrameCompleted <= IntendedVsync (a
        # corrupted, still-in-flight frame at dump time) and is excluded.
        self.assertEqual(result["excludedInvalid"], 1)
        self.assertEqual(result["usableFrameCount"], 119)
        self.assertGreater(result["frameDurationMs"]["min"], 0)
        self.assertGreater(result["frameDurationMs"]["p50"], 0)
        self.assertIn("stageMs", result)
        self.assertIn("uiThreadMs", result)
        for stats in list(result["stageMs"].values()) + [result["uiThreadMs"]]:
            self.assertIsNotNone(stats)
            for key in ("p50", "p90", "p95", "p99", "max", "mean"):
                self.assertIn(key, stats)


class TestColumnOrderIndependence(unittest.TestCase):
    def test_shuffled_column_order_parses_correctly(self):
        # Fully shuffle the column order (Flags is no longer first) to prove
        # values are matched by name, not position.
        shuffled_names = [
            "GpuCompleted", "FrameInterval", "SyncStart", "Flags", "DrawStart",
            "IssueDrawCommandsStart", "IntendedVsync", "FrameTimelineVsyncId",
            "SwapBuffersCompleted", "PerformTraversalsStart", "FrameCompleted",
            "CommandSubmissionCompleted", "DisplayPresentTime", "Vsync",
            "WorkloadTarget", "SyncQueued", "AnimationStart", "InputEventId",
            "FrameDeadline", "SwapBuffers", "QueueBufferDuration",
            "DequeueBufferDuration", "FrameStartTime", "HandleInputStart",
        ]
        canonical = make_row(
            intended_vsync=42_000_000_000,
            frame_completed=42_020_000_000,
            frame_timeline_vsync_id=777,
        )
        canonical_fields = dict(
            zip(
                [c.rstrip(",") for c in REAL_HEADER.split(",") if c],
                canonical.rstrip(",").split(","),
            )
        )
        shuffled_row = ",".join(canonical_fields[name] for name in shuffled_names) + ","
        shuffled_header = ",".join(shuffled_names) + ","

        text = make_capture([shuffled_row], header=shuffled_header)
        parsed = parse_framestats(text)
        self.assertEqual(len(parsed.unique_rows), 1)
        row = parsed.unique_rows[0]
        self.assertEqual(row["IntendedVsync"], 42_000_000_000)
        self.assertEqual(row["FrameCompleted"], 42_020_000_000)
        self.assertEqual(row["FrameTimelineVsyncId"], 777)
        self.assertEqual(row["Flags"], 0)


class TestMissingColumn(unittest.TestCase):
    def test_missing_required_column_raises_named_error(self):
        header_without_deadline = REAL_HEADER.replace("FrameDeadline,", "")
        text = make_capture([make_row()], header=header_without_deadline)
        with self.assertRaises(MissingColumnError) as ctx:
            parse_framestats(text)
        self.assertIn("FrameDeadline", str(ctx.exception))


class TestDeduplication(unittest.TestCase):
    def test_overlapping_blocks_dedup_to_right_unique_count(self):
        # Block 1: frames at t=0,1,2 (by IntendedVsync). Block 2 (a later
        # poll): frames at t=1,2,3 -- t=1 and t=2 overlap, t=3 is new.
        rows_block1 = [
            make_row(intended_vsync=1_000_000_000 + i * 16_666_666, frame_timeline_vsync_id=100 + i)
            for i in range(3)
        ]
        rows_block2 = [
            make_row(intended_vsync=1_000_000_000 + i * 16_666_666, frame_timeline_vsync_id=100 + i)
            for i in range(1, 4)
        ]
        text = (
            "---PROFILEDATA---\n" + REAL_HEADER + "\n" + "\n".join(rows_block1) + "\n"
            + "---PROFILEDATA---\n" + REAL_HEADER + "\n" + "\n".join(rows_block2) + "\n"
        )
        parsed = parse_framestats(text)
        self.assertEqual(parsed.raw_row_count, 6)
        self.assertEqual(len(parsed.block_row_counts), 2)
        self.assertEqual(len(parsed.unique_rows), 4)  # t=0,1,2,3


class TestFlagsExclusion(unittest.TestCase):
    def test_nonzero_flags_rows_excluded_and_counted(self):
        rows = [
            make_row(intended_vsync=1_000_000_000, frame_completed=1_010_000_000, frame_timeline_vsync_id=1, flags=0),
            make_row(intended_vsync=1_020_000_000, frame_completed=1_030_000_000, frame_timeline_vsync_id=2, flags=0),
            make_row(
                intended_vsync=1_040_000_000, frame_completed=1_050_000_000, frame_timeline_vsync_id=3, flags=1
            ),  # layout change
            make_row(
                intended_vsync=1_060_000_000, frame_completed=1_070_000_000, frame_timeline_vsync_id=4, flags=64
            ),
        ]
        text = make_capture(rows)
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)
        self.assertEqual(result["uniqueFrameCount"], 4)
        self.assertEqual(result["excludedFlagged"], 2)
        self.assertEqual(result["usableFrameCount"], 2)


class TestPercentileMath(unittest.TestCase):
    def test_percentile_on_known_input(self):
        values = sorted([10.0, 20.0, 30.0, 40.0, 50.0, 60.0, 70.0, 80.0, 90.0, 100.0])
        # rank = (10-1) * p/100
        self.assertEqual(percentile(values, 0), 10.0)
        self.assertEqual(percentile(values, 100), 100.0)
        # p50: rank=4.5 -> interpolate values[4]=50, values[5]=60 -> 55.0
        self.assertEqual(percentile(values, 50), 55.0)
        # p90: rank=8.1 -> values[8]=90, values[9]=100 -> 90 + 0.1*10 = 91.0
        self.assertAlmostEqual(percentile(values, 90), 91.0, places=9)

    def test_percentile_single_value(self):
        self.assertEqual(percentile([42.0], 50), 42.0)
        self.assertEqual(percentile([42.0], 99), 42.0)

    def test_percentile_empty_raises(self):
        with self.assertRaises(ValueError):
            percentile([], 50)


class TestZeroUsableFrames(unittest.TestCase):
    def test_all_flagged_rows_raise(self):
        rows = [
            make_row(intended_vsync=1_000_000_000, frame_timeline_vsync_id=1, flags=1),
            make_row(intended_vsync=1_020_000_000, frame_timeline_vsync_id=2, flags=2),
        ]
        text = make_capture(rows)
        parsed = parse_framestats(text)
        with self.assertRaises(NoUsableFramesError):
            compute_metrics(parsed.unique_rows)

    def test_no_profiledata_marker_raises(self):
        from framestats import NoProfileDataError

        with self.assertRaises(NoProfileDataError):
            parse_framestats("no profile data here at all\njust some text\n")


class TestJankAndStages(unittest.TestCase):
    def test_jank_by_deadline_and_budget(self):
        # Frame A: completes before its deadline and within budget -> not janky.
        row_a = make_row(
            intended_vsync=1_000_000_000,
            frame_timeline_vsync_id=1,
            frame_deadline=1_016_666_666,
            frame_interval=16_666_666,
            frame_completed=1_010_000_000,
        )
        # Frame B: completes after its deadline and over budget -> janky both ways.
        row_b = make_row(
            intended_vsync=2_000_000_000,
            frame_timeline_vsync_id=2,
            frame_deadline=2_016_666_666,
            frame_interval=16_666_666,
            frame_completed=2_030_000_000,
        )
        # Frame C: FrameDeadline absent (0) -> falls back to the budget test;
        # duration (40ms) exceeds the 16.67ms budget -> janky, and counted as
        # a fallback row.
        row_c = make_row(
            intended_vsync=3_000_000_000,
            frame_timeline_vsync_id=3,
            frame_deadline=0,
            frame_interval=16_666_666,
            frame_completed=3_040_000_000,
        )
        text = make_capture([row_a, row_b, row_c])
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)
        self.assertEqual(result["deadlineFallbackRows"], 1)
        self.assertEqual(result["jankyFramesDeadline"]["count"], 2)  # B and C
        self.assertEqual(result["jankyFramesBudget"]["count"], 2)  # B and C

    def test_stage_stats_are_computed_from_named_columns(self):
        # A single row: every percentile of a 1-element sample collapses to
        # that one value, which lets this test pin down the exact stage
        # subtractions without needing a distribution.
        row = make_row(
            intended_vsync=1_000_000_000,
            frame_timeline_vsync_id=9,
            handle_input_start=1_000_000_000,
            animation_start=1_001_000_000,  # +1ms
            perform_traversals_start=1_003_000_000,  # +2ms
            draw_start=1_004_000_000,  # +1ms (within traversal/draw span)
            sync_queued=1_006_000_000,  # +2ms after draw_start
            issue_draw_commands_start=1_010_000_000,  # +4ms
            frame_completed=1_015_000_000,  # +5ms
        )
        text = make_capture([row])
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)
        sm = result["stageMs"]

        def assert_all_percentiles(stats, expected_ms):
            for key in ("p50", "p90", "p95", "p99", "max", "mean"):
                self.assertAlmostEqual(stats[key], expected_ms, places=6, msg=key)

        assert_all_percentiles(sm["inputHandling"], 1.0)
        assert_all_percentiles(sm["animation"], 2.0)
        assert_all_percentiles(sm["traversalDraw"], 3.0)
        assert_all_percentiles(sm["sync"], 4.0)
        assert_all_percentiles(sm["gpuSwap"], 5.0)
        # uiThreadMs = DrawStart - HandleInputStart = 4ms.
        assert_all_percentiles(result["uiThreadMs"], 4.0)
        self.assertEqual(sum(result["stageExclusions"].values()), 0)

    def test_stage_percentiles_reveal_a_tail_hidden_by_the_median(self):
        # The scenario this whole feature exists for: during a fling, most
        # frames do zero per-item work (nothing new binds), so a per-bind
        # cost only shows up on a few frames -- invisible at p50, visible in
        # the tail. 19 "no-bind" frames with a tiny traversalDraw gap, plus 1
        # "bind" frame with a much larger one.
        rows = []
        for i in range(19):
            rows.append(
                make_row(
                    intended_vsync=1_000_000_000 + i * 16_666_666,
                    frame_timeline_vsync_id=i,
                    perform_traversals_start=1_000_300_000 + i * 16_666_666,
                    sync_queued=1_000_400_000 + i * 16_666_666,  # +0.1ms: no bind
                    frame_completed=1_010_000_000 + i * 16_666_666,
                )
            )
        bind_frame = make_row(
            intended_vsync=1_000_000_000 + 19 * 16_666_666,
            frame_timeline_vsync_id=19,
            perform_traversals_start=1_000_300_000 + 19 * 16_666_666,
            sync_queued=1_010_300_000 + 19 * 16_666_666,  # +10ms: one bind cost
            frame_completed=1_020_000_000 + 19 * 16_666_666,
        )
        rows.append(bind_frame)
        text = make_capture(rows)
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)
        td = result["stageMs"]["traversalDraw"]

        # p50 sits with the 19 cheap frames and looks free...
        self.assertLess(td["p50"], 0.5)
        # ...but p99 and max land on the one expensive bind frame, which the
        # median could never reveal.
        self.assertGreater(td["p99"], 8.0)
        self.assertGreater(td["max"], 8.0)
        self.assertGreater(td["mean"], td["p50"])


class TestInvalidFrameExclusion(unittest.TestCase):
    def test_physically_impossible_row_is_excluded_from_all_metrics(self):
        # Two normal frames, plus one where FrameCompleted <= IntendedVsync --
        # physically impossible (a frame cannot complete before its own
        # intended vsync), the known ring-buffer artifact for a frame still
        # in flight at dump time.
        good_a = make_row(
            intended_vsync=1_000_000_000, frame_timeline_vsync_id=1, frame_completed=1_010_000_000
        )
        good_b = make_row(
            intended_vsync=1_020_000_000, frame_timeline_vsync_id=2, frame_completed=1_030_000_000
        )
        impossible = make_row(
            intended_vsync=1_040_000_000,
            frame_timeline_vsync_id=3,
            frame_completed=1_038_000_000,  # before its own IntendedVsync
        )
        text = make_capture([good_a, good_b, impossible])
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)

        self.assertEqual(result["uniqueFrameCount"], 3)
        self.assertEqual(result["excludedInvalid"], 1)
        self.assertEqual(result["usableFrameCount"], 2)
        self.assertGreater(result["frameDurationMs"]["min"], 0)
        self.assertTrue(any("excludedInvalid" in c or "physically impossible" in c for c in result["caveats"]))

    def test_all_impossible_rows_raise_no_usable_frames(self):
        rows = [
            make_row(intended_vsync=1_000_000_000, frame_timeline_vsync_id=1, frame_completed=999_000_000),
            make_row(intended_vsync=1_020_000_000, frame_timeline_vsync_id=2, frame_completed=1_020_000_000),
        ]
        text = make_capture(rows)
        parsed = parse_framestats(text)
        with self.assertRaises(NoUsableFramesError):
            compute_metrics(parsed.unique_rows)


class TestStageLevelNegativeExclusion(unittest.TestCase):
    def test_negative_stage_gap_excluded_from_that_stage_only(self):
        # Frame's overall duration is valid (FrameCompleted > IntendedVsync),
        # but AnimationStart precedes HandleInputStart in this row -- a
        # corrupted single-stage timestamp. It must be dropped from
        # 'inputHandling' only, not from usableFrameCount or the other stages.
        normal = make_row(
            intended_vsync=1_000_000_000,
            frame_timeline_vsync_id=1,
            handle_input_start=1_000_100_000,
            animation_start=1_000_200_000,  # +0.1ms, valid
            frame_completed=1_010_000_000,
        )
        corrupted = make_row(
            intended_vsync=2_000_000_000,
            frame_timeline_vsync_id=2,
            handle_input_start=2_000_500_000,
            animation_start=2_000_100_000,  # BEFORE handle_input_start -> negative gap
            frame_completed=2_010_000_000,
        )
        text = make_capture([normal, corrupted])
        parsed = parse_framestats(text)
        result = compute_metrics(parsed.unique_rows)

        self.assertEqual(result["usableFrameCount"], 2)  # both still usable overall
        self.assertEqual(result["stageExclusions"]["inputHandling"], 1)
        # p50 (and every other percentile) computed from the one remaining
        # (normal) row's own gap, since only one value survives.
        self.assertAlmostEqual(result["stageMs"]["inputHandling"]["p50"], 0.1, places=6)
        self.assertTrue(any("inputHandling" in c for c in result["caveats"]))


if __name__ == "__main__":
    unittest.main()
