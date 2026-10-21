import importlib.util
import unittest


class PublicEditionIdentityIsolationTests(unittest.TestCase):
    def test_private_shared_people_adapter_is_not_shipped(self):
        self.assertIsNone(importlib.util.find_spec("shared_people"))


if __name__ == "__main__":
    unittest.main()
