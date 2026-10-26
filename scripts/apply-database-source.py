#!/usr/bin/env python3
"""Install tracked database implementation plus guarded native integration patch."""
import pathlib
import shutil
import subprocess
import sys

project = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(sys.argv[1]).resolve()
if not (source / 'v2/hcore/start.go').is_file():
    raise SystemExit('Expected pinned native core checkout')
for origin, destination in [(project / 'native/database', source / 'v2/configdb'),
                            (project / 'native/hcore', source / 'v2/hcore'),
                            (project / 'native/singbox', source / 'hiddify-sing-box')]:
    for file in origin.rglob('*'):
        if not file.is_file() or file.suffix not in {'.go', '.sql'}:
            continue
        target = destination / file.relative_to(origin)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
patch = project / 'native-patches/database-source.patch'
if patch.exists():
    check = subprocess.run(['patch', '-p1', '--reverse', '--batch', '--dry-run', '-i', str(patch)],
                           cwd=source, capture_output=True)
    if check.returncode:
        subprocess.run(['patch', '-p1', '--forward', '--batch', '-i', str(patch)], cwd=source, check=True)
print('Database native sources installed')
