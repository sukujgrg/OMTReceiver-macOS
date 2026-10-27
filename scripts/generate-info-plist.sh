#!/bin/bash
set -euo pipefail
[[ $# -eq 3 ]] || { echo 'Usage: generate-info-plist.sh VERSION TEMPLATE OUTPUT' >&2; exit 1; }
python3 - "$1" "$2" "$3" <<'PY'
import datetime, os, pathlib, plistlib, re, subprocess, sys
version_file, template_file, output_file = map(pathlib.Path, sys.argv[1:])
version = version_file.read_text().strip()
if not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', version):
    raise SystemExit('error: VERSION must contain a numeric X.Y or X.Y.Z version.')
value = plistlib.loads(template_file.read_bytes())
value['CFBundleShortVersionString'] = version
build = os.environ.get('CURRENT_PROJECT_VERSION', '').strip()
if not build:
    build = datetime.datetime.now(datetime.timezone.utc).strftime('%y%m%d.%H%M%S')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', build):
    raise SystemExit('error: CURRENT_PROJECT_VERSION must be numeric.')
value['CFBundleVersion'] = build
commit = os.environ.get('RELEASE_SOURCE_COMMIT', '').strip()
if not commit:
    result = subprocess.run(['git', '-C', str(version_file.resolve().parent), 'rev-parse', 'HEAD'], capture_output=True, text=True)
    commit = result.stdout.strip() if result.returncode == 0 else 'development'
value['OMTReceiverSourceCommit'] = commit
output_file.parent.mkdir(parents=True, exist_ok=True)
output_file.write_bytes(plistlib.dumps(value))
PY
