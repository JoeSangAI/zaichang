import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import runtime_config


class RuntimeConfigurationTests(unittest.TestCase):
    def test_uses_portable_standalone_default(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(Path, "home", return_value=Path("/portable/home")):
            self.assertEqual(runtime_config.data_root(), Path("/portable/home/Library/Application Support/ZaichangStandalone"))

    def test_child_process_override_is_shared(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp) / "meeting-data"
            self.assertEqual(runtime_config.data_root({"ZAICHANG_DATA_ROOT": str(root)}), root.resolve())

    def test_rejects_relative_traversal_and_accepts_safe_named_root(self):
        with patch.object(Path, "home", return_value=Path("/portable/home")):
            self.assertEqual(runtime_config.data_root({"ZAICHANG_DATA_ROOT": "../outside"}), Path("/portable/home/Library/Application Support/ZaichangStandalone"))
            self.assertEqual(runtime_config.data_root({"ZAICHANG_DATA_ROOT": "ExistingEdition"}), Path("/portable/home/Library/Application Support/ExistingEdition"))


if __name__ == "__main__":
    unittest.main()
