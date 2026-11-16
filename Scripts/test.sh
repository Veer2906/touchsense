#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

FLAGS=()
if ! xcode-select -p 2>/dev/null | grep -q Xcode; then
  FRAMEWORKS=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  FLAGS=(-Xswiftc "-F$FRAMEWORKS" -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays
         -Xlinker "-F$FRAMEWORKS" -Xlinker -rpath -Xlinker "$FRAMEWORKS")
fi
swift test ${FLAGS[@]+"${FLAGS[@]}"} "$@"
