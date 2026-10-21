import unittest

from scripts.speaker_shadow_runner import ROOT, score_raw_segments
from scripts.speaker_shadow_build import DEFAULT_SDK


class RawCommunityScoringTests(unittest.TestCase):
    def test_default_paths_are_relative_to_the_active_checkout(self):
        self.assertEqual(DEFAULT_SDK, ROOT / "native/local-speaker-install/sdk")

    def test_scores_turn_overlaps_after_permuting_anonymous_cluster_ids(self):
        turns = [
            {"start": 0.0, "end": 2.0, "source_speaker_id": "a"},
            {"start": 2.1, "end": 4.0, "source_speaker_id": "b"},
            {"start": 4.1, "end": 6.0, "source_speaker_id": "a"},
        ]
        segments = [
            {"start": 0.0, "end": 2.0, "cluster": "S9"},
            {"start": 2.1, "end": 4.0, "cluster": "S2"},
            {"start": 4.1, "end": 6.0, "cluster": "S9"},
        ]
        score = score_raw_segments(turns, segments)
        self.assertEqual(score["correct_after_anonymous_label_permutation"], 3)
        self.assertEqual(score["coverage"], 1.0)
        self.assertEqual(score["anonymous_cluster_to_public_speaker_mapping"], {"S2": "b", "S9": "a"})

    def test_leaves_uncovered_turn_unknown_instead_of_counting_it_wrong(self):
        turns = [
            {"start": 0.0, "end": 1.0, "source_speaker_id": "a"},
            {"start": 2.0, "end": 3.0, "source_speaker_id": "b"},
        ]
        score = score_raw_segments(turns, [{"start": 0.1, "end": 0.9, "cluster": "S1"}])
        self.assertEqual(score["covered_turns"], 1)
        self.assertEqual(score["unknown_turns"], 1)
        self.assertEqual(score["wrong_turns_after_anonymous_label_permutation"], 0)
        self.assertEqual(score["coverage"], 0.5)

    def test_maps_best_two_clusters_when_there_are_three(self):
        turns = [
            {"start": 0.0, "end": 1.0, "source_speaker_id": "a"},
            {"start": 1.0, "end": 2.0, "source_speaker_id": "b"},
            {"start": 2.0, "end": 3.0, "source_speaker_id": "b"},
            {"start": 3.0, "end": 4.0, "source_speaker_id": "b"},
        ]
        segments = [
            {"start": 0.0, "end": 1.0, "cluster": "S0"},
            {"start": 1.0, "end": 2.0, "cluster": "S1"},
            {"start": 2.0, "end": 3.0, "cluster": "S2"},
            {"start": 3.0, "end": 4.0, "cluster": "S2"},
        ]
        score = score_raw_segments(turns, segments)
        self.assertEqual(score["correct_after_anonymous_label_permutation"], 3)
        self.assertEqual(score["anonymous_cluster_to_public_speaker_mapping"], {"S0": "a", "S1": None, "S2": "b"})


if __name__ == "__main__":
    unittest.main()
