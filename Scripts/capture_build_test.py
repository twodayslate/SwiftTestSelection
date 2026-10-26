#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Zachary Gorak
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
"""Capture reuse regressions; no Xcode or test execution required."""
import json
from pathlib import Path
import runpy
import tempfile
import unittest

select_manifests = runpy.run_path(str(Path(__file__).with_name('capture-build.py')))['select_manifests']


class CaptureReuseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.sequence = 0

    def job(self, primaries, module='App', sources=('A.swift', 'B.swift', 'C.swift'), **overrides):
        self.sequence += 1
        record = dict(status='complete', started=self.sequence, directory=str(self.root),
                      arguments=['-module-name', module, '-Onone', '-g'],
                      sourceFiles=list(sources), primaryFiles=list(primaries),
                      sources={s: 'digest' for s in sources})
        record.update(overrides)
        path = self.root / str(self.sequence) / 'manifest.json'
        path.parent.mkdir()
        path.write_text(json.dumps(record))
        return path

    def test_repeated_full_builds_and_noop_reuse_stay_bounded(self):
        retained = set()
        for _ in range(4):
            fresh = {self.job(['A.swift']), self.job(['B.swift', 'C.swift'])}
            retained = select_manifests(fresh, retained)
            self.assertEqual(retained, fresh)
            self.assertEqual(select_manifests(set(), retained), retained)

    def test_partial_build_retains_uncovered_primaries_across_batch_changes(self):
        old_ab, old_c = self.job(['A.swift', 'B.swift']), self.job(['C.swift'])
        new_a = self.job(['A.swift'])
        retained = select_manifests({new_a}, {old_ab, old_c})
        self.assertEqual(retained, {new_a, old_ab, old_c})
        new_b = self.job(['B.swift'])
        retained = select_manifests({new_b}, retained)
        self.assertEqual(retained, {new_a, new_b, old_c})
        whole_module = self.job([])
        self.assertEqual(select_manifests({whole_module}, retained), {whole_module})

    def test_legacy_accumulated_duplicates_are_compacted_on_noop(self):
        older = {self.job(['A.swift']), self.job(['B.swift', 'C.swift'])}
        latest = {self.job(['A.swift']), self.job(['B.swift', 'C.swift'])}
        self.assertEqual(select_manifests(set(), older | latest), latest)

    def test_different_modules_and_inventories_cannot_mask_each_other(self):
        original = self.job(['A.swift'])
        other_module = self.job(['A.swift'], module='Tests')
        other_inventory = self.job(['A.swift'], sources=('A.swift', 'B.swift'))
        self.assertEqual(select_manifests({other_module, other_inventory}, {original}),
                         {original, other_module, other_inventory})

    def test_unsupported_fresh_records_remain_visible_without_superseding_coverage(self):
        original = self.job([])
        failed = self.job([], status='failed')
        optimized = self.job([], arguments=['-module-name', 'App', '-O', '-g'])
        malformed = self.job(['Missing.swift'])
        self.assertEqual(select_manifests({failed, optimized, malformed}, {original}),
                         {original, failed, optimized, malformed})

    def test_conflicting_source_hashes_remain_visible_to_provenance_validation(self):
        original, changed = self.job([]), self.job([])
        record = json.loads(changed.read_text())
        record['sources']['A.swift'] = 'different bytes'
        changed.write_text(json.dumps(record))
        self.assertEqual(select_manifests({changed}, {original}), {original, changed})


if __name__ == '__main__':
    unittest.main()
