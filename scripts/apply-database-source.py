#!/usr/bin/env python3
"""Install tracked database implementation plus guarded native integration patch."""
import pathlib
import shutil
import subprocess
import sys
import tempfile

project = pathlib.Path(__file__).resolve().parent.parent
source = pathlib.Path(sys.argv[1]).resolve()
if not (source / 'v2/hcore/start.go').is_file():
    raise SystemExit('Expected pinned native core checkout')
# availability.go is now a complete tracked overlay, including database integration.
# Ignore its old incremental hunk for both fresh and already-overlaid checkouts.
patch = project / 'native-patches/database-source.patch'
with patch.open(newline='') as original:
    text = original.read()
parts = text.split('--- a/')
text = parts[0] + ''.join('--- a/' + part for part in parts[1:]
                        if not part.startswith('hiddify-sing-box/common/monitoring/availability.go\n'))
with tempfile.NamedTemporaryFile(mode='w', suffix='.patch') as temporary:
    temporary.write(text)
    temporary.flush()
    check = subprocess.run(['patch', '-p1', '--reverse', '--force', '--batch', '--dry-run', '-i', temporary.name],
                           cwd=source, capture_output=True)
    if '--check-patch' in sys.argv:
        raise SystemExit(check.returncode)
    if check.returncode:
        subprocess.run(['patch', '-p1', '--forward', '--batch', '-i', temporary.name], cwd=source, check=True)
for origin, destination in [(project / 'native/database', source / 'v2/configdb'),
                            (project / 'native/db', source / 'v2/db'),
                            (project / 'native/hcore', source / 'v2/hcore'),
                            (project / 'native/singbox', source / 'hiddify-sing-box')]:
    for file in origin.rglob('*'):
        if not file.is_file() or file.suffix not in {'.go', '.sql'}:
            continue
        target = destination / file.relative_to(origin)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(file, target)
print('Database native sources installed')

verification_patch = project / 'native/singbox/common/monitoring/verification-state.patch'
if verification_patch.exists():
    applied = subprocess.run(['patch', '-p1', '--reverse', '--force', '--batch', '--dry-run', '-i', str(verification_patch)], cwd=source, capture_output=True)
    if applied.returncode:
        subprocess.run(['patch', '-p1', '--forward', '--batch', '-i', str(verification_patch)], cwd=source, check=True)
