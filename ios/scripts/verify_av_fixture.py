"""Decode only the bounded synthetic SRTLA fixture produced by simulator tests.

This is not a camera FPS, perceptual quality, or physical-device lip-sync test.
The fixture sends 1024-sample audio chunks and video every second chunk at 48 kHz.
Its video input changes format halfway through without restarting the publisher.
"""
import json
import math
import pathlib
import subprocess
import sys


def validate(report):
    streams = report.get("streams", [])
    video = [s for s in streams if s.get("codec_type") == "video"]
    audio = [s for s in streams if s.get("codec_type") == "audio"]
    assert len(video) == len(audio) == 1, "Expected exactly one video and audio stream"
    assert video[0]["codec_name"] == "h264"
    assert audio[0]["codec_name"] == "aac"
    assert int(audio[0]["sample_rate"]) == 48000
    frames = report.get("frames", [])
    tracks = {}
    for kind, minimum, maximum_gap in [("video", 30, 0.15), ("audio", 60, 0.08)]:
        decoded = [f for f in frames if f.get("media_type") == kind]
        assert len(decoded) >= minimum, f"Too few decoded {kind} frames: {len(decoded)}"
        times = [float(f["pts_time"]) for f in decoded]
        assert all(math.isfinite(t) for t in times), "Invalid presentation timestamp"
        gaps = [b - a for a, b in zip(times, times[1:])]
        assert all(0 < gap <= maximum_gap for gap in gaps), f"{kind} timestamp reset or gap: {gaps}"
        assert times[-1] - times[0] >= 1.4, f"{kind} stopped before the format-change recovery window"
        assert sum(t - times[0] >= 1.0 for t in times) >= 10, f"Missing post-change {kind} frames"
        tracks[kind] = (decoded, times)
    assert all((f["width"], f["height"]) == (1280, 720) for f in tracks["video"][0])
    assert sum(f.get("key_frame", 0) for f in tracks["video"][0]) >= 2, "No new keyframe after format change"
    assert abs(tracks["video"][1][0] - tracks["audio"][1][0]) <= 0.15, "Large initial synthetic A/V timestamp offset"
    return {kind: len(track[0]) for kind, track in tracks.items()}


def main():
    source = pathlib.Path(sys.argv[1]).resolve(strict=True)
    assert 0 < source.stat().st_size <= 2 * 1024 * 1024, "Missing or oversized synthetic fixture"
    result = subprocess.run(["ffprobe", "-v", "error", "-err_detect", "explode",
                             "-show_streams", "-show_frames", "-of", "json", str(source)],
                            capture_output=True, text=True, timeout=60, check=True)
    # A zero exit code alone does not prove successful decoding; some demuxer
    # diagnostics are nonfatal, so reject reported errors as well.
    assert not result.stderr.strip(), f"Decoder reported errors: {result.stderr[:4000]}"
    report = json.loads(result.stdout)
    counts = validate(report)
    print("Synthetic receiver A/V decoded across the input format change:", counts)
    print("This does not establish iPhone camera FPS, perceptual quality, or physical lip sync.")


if __name__ == "__main__":
    main()
