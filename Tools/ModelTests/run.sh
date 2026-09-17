#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
mkdir -p .build/module-cache
xcrun swiftc -swift-version 5 -target arm64-apple-macos26.4 \
  -module-cache-path .build/module-cache -parse-as-library \
  Sources/LocalTranslation.swift Tools/ModelTests/ClientTests.swift -o .build/model-tests
python3 - <<'PY'
import subprocess,time
p=subprocess.Popen(['python3','Tools/ModelTests/server.py'])
try:
 time.sleep(0.3)
 subprocess.run(['.build/model-tests'],check=True)
finally:
 p.terminate()
 p.wait()
PY
