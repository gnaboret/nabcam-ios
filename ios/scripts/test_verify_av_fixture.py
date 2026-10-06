import copy
import unittest
import math
from verify_av_fixture import validate, validate_processed_audio


class AVFixtureValidationTests(unittest.TestCase):
    def test_processed_audio_accepts_limited_gain_and_rejects_bypass(self):
        wave = [math.sin(index * 0.0576) for index in range(90_000)]
        rms, peak = validate_processed_audio([value * 0.89125 for value in wave])
        self.assertGreater(rms, 0.6)
        self.assertLess(peak, 0.9)
        for amplitude in [0, 0.25, 1.5]:
            with self.assertRaises(AssertionError):
                validate_processed_audio([value * amplitude for value in wave])

    def test_processed_audio_rejects_short_and_invalid_samples(self):
        for samples in [[0.6] * 100, [0.6] * 60_000 + [float('nan')],
                        [0.6] * 60_000 + [float('inf')], [0.6] * 60_000 + [1.1]]:
            with self.assertRaises(AssertionError):
                validate_processed_audio(samples)

    def setUp(self):
        self.report = {
            "streams": [{"codec_type": "video", "codec_name": "h264"},
                        {"codec_type": "audio", "codec_name": "aac", "sample_rate": "48000"}],
            "frames": [{"media_type": "video", "pts_time": str(i * 2048 / 48000),
                        "width": 1280, "height": 720, "key_frame": int(i in (0, 23))}
                       for i in range(44)] +
                      [{"media_type": "audio", "pts_time": str(i * 1024 / 48000)}
                       for i in range(88)]}

    def test_accepts_complete_synthetic_timeline(self):
        self.assertEqual(validate(self.report), {"video": 44, "audio": 88})

    def test_rejects_missing_audio_or_duplicate_stream(self):
        for streams in [self.report["streams"][:1], self.report["streams"] * 2]:
            bad = copy.deepcopy(self.report)
            bad["streams"] = streams
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_reset_gap_or_nonfinite_timestamp(self):
        for timestamp in ["0", "10", "nan", "inf"]:
            bad = copy.deepcopy(self.report)
            bad["frames"][25]["pts_time"] = timestamp
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_wrong_resolution_and_missing_recovery_keyframe(self):
        for field, value in [("width", 640), ("key_frame", 0)]:
            bad = copy.deepcopy(self.report)
            bad["frames"][23][field] = value
            with self.assertRaises(AssertionError):
                validate(bad)

    def test_rejects_video_that_stops_early(self):
        bad = copy.deepcopy(self.report)
        bad["frames"] = [f for f in bad["frames"] if f["media_type"] == "audio" or float(f["pts_time"]) < 1.1]
        with self.assertRaises(AssertionError):
            validate(bad)


if __name__ == "__main__":
    unittest.main()
