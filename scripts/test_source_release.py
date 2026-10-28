import hashlib
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from zipfile import ZipFile

import source_manifest as manifest


class SourceReleaseTests(unittest.TestCase):
    def test_manifest_and_bundle_match_actual_source(self):
        with tempfile.TemporaryDirectory() as root:
            bundle = Path(root)
            value = manifest.write_bundle(bundle)
            data = (bundle / 'hongguo.js').read_bytes()
            self.assertEqual(value['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(manifest.verify_bytes(data, (bundle / manifest.MANIFEST).read_bytes(), manifest.SOURCE.read_bytes()), value)

    def test_rejects_modified_or_missing_manifest(self):
        with self.assertRaises(ValueError):
            manifest.verify_bytes(b'changed', json.dumps({'id': 'hongguo', 'sha256': 'stale'}), b'expected')
        with self.assertRaises(ValueError):
            manifest.verify_bytes(b'expected', json.dumps({'id': 'wrong', 'sha256': manifest.digest(b'expected')}), b'expected')

    def test_ipa_reads_only_single_app_source_and_metadata(self):
        with tempfile.TemporaryDirectory() as root:
            ipa = Path(root) / 'app.ipa'
            with ZipFile(ipa, 'w') as archive:
                archive.writestr('Payload/App.app/Info.plist', plistlib.dumps({'CFBundleVersion': '123'}))
                archive.writestr('Payload/App.app/hongguo.js', b'source')
                archive.writestr('Payload/App.app/hongguo-source.json', '{}')
            data, value, info = manifest.inspect_ipa(ipa)
            self.assertEqual(data, b'source')
            self.assertEqual(info['CFBundleVersion'], '123')

    def test_invalid_source_fails_packaging(self):
        with tempfile.TemporaryDirectory() as root:
            source = Path(root) / 'empty.js'
            source.write_text('')
            with patch.object(manifest, 'SOURCE', source), self.assertRaises(ValueError):
                manifest.write_bundle(Path(root) / 'bundle')


if __name__ == '__main__':
    unittest.main()
