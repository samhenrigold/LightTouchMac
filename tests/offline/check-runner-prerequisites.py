#!/usr/bin/env python3
"""Acceptance must reject selected missing prerequisites and empty selections."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
from unittest.mock import patch
root=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('runner', root/'tests/run.py')
R=importlib.util.module_from_spec(spec);spec.loader.exec_module(R)
with tempfile.TemporaryDirectory(prefix='runner-prereqs-') as tmp:
    for strict,want in ((False,0),(True,1)):
        argv=['run.py','offline','--out',tmp]+(['--require-inputs'] if strict else [])
        with patch.object(R.sys,'argv',argv),patch.object(R,'offline_checks',return_value=([],[('offline/fixture','missing')])),patch.object(R.sources,'path',return_value=root),patch.object(R,'module_cache_shims',return_value=root),patch.object(R,'display_asleep',return_value=False),contextlib.redirect_stdout(io.StringIO()):
            assert R.main()==want
    with patch.object(R.sys,'argv',['run.py','offline','--only','typo','--out',tmp]),patch.object(R,'offline_checks',return_value=([],[('offline/fixture','missing')])),contextlib.redirect_stderr(io.StringIO()):
        try: R.main()
        except SystemExit as e: assert e.code==2
        else: raise AssertionError('empty selection passed')
print('PASS optional skips, strict missing prerequisites and empty selection rejection')
