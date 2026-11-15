import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('acl', ROOT / 'scripts/render-acl.py')
acl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acl)


class DiscoveryACL(unittest.TestCase):
    def test_default_is_byte_for_byte_unchanged(self):
        base = (ROOT / 'config/acl.conf').read_text()
        self.assertEqual(acl.render(base, ''), base)

    def test_only_named_account_gets_discovery_without_changing_base_policy(self):
        base = (ROOT / 'config/acl.conf').read_text()
        result = acl.render(base, 'ha-house')
        self.assertTrue(result.endswith(base))
        self.assertEqual(result.count('homeassistant/#'), 1)
        self.assertIn('{username, "ha-house"}', result)
        self.assertNotIn('["#"]', result)

    def test_patterns_and_rule_injection_are_refused(self):
        for value in ['*', '+', '#', '$SYS', 'a/b', 'a"}, all, ["#"]}.', 'a\nadmin', 'x'*65]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                acl.render('unchanged', value)
