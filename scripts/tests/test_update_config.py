import base64
import importlib.util
import os
import pathlib
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('update_config', pathlib.Path(__file__).parents[1] / 'update-config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)

class UpdateConfigTests(unittest.TestCase):
    def setUp(self):
        self.env = dict(MINASCP_VERSION='1.1.0', MINASCP_BUILD='260911.1',
                        MINASCP_FEED_URL=config.PRODUCTION_FEED, MINASCP_UPDATE_TEST='0',
                        MINASCP_UPDATE_PUBLIC_KEY=base64.b64encode(bytes(32)).decode())

    def validate(self, mode='release', **changes):
        with patch.dict(os.environ, self.env | changes, clear=True):
            return config.configuration(mode)

    def test_release_requires_key_but_debug_can_build_without_it(self):
        with self.assertRaises(ValueError):
            self.validate(MINASCP_UPDATE_PUBLIC_KEY='')
        self.assertEqual(self.validate('debug', MINASCP_UPDATE_PUBLIC_KEY='')[2], '')

    def test_invalid_keys_versions_and_feed_are_rejected(self):
        for changes in [dict(MINASCP_UPDATE_PUBLIC_KEY='bad'), dict(MINASCP_VERSION='1.1'),
                        dict(MINASCP_BUILD='1.bad'), dict(MINASCP_FEED_URL='http://example.com/appcast.xml'),
                        dict(MINASCP_FEED_URL='https://example.com/appcast.xml')]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.validate(**changes)

    def test_loopback_feed_requires_explicit_isolated_test_build(self):
        with self.assertRaises(ValueError):
            self.validate(MINASCP_FEED_URL='http://127.0.0.1:18765/appcast.xml')
        result = self.validate(MINASCP_UPDATE_TEST='1', MINASCP_FEED_URL='http://127.0.0.1:18765/appcast.xml')
        self.assertTrue(result[-1])
        with self.assertRaises(ValueError):
            self.validate(MINASCP_UPDATE_TEST='1', MINASCP_FEED_URL='https://example.com/appcast.xml')

if __name__ == '__main__':
    unittest.main()
