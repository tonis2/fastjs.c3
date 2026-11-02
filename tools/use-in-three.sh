#!/bin/bash
# Build three.c3 on fastjs instead of QuickJS: link this repo in as a library, swap the
# dependency, and change `import qjs;` to `import fastjs::qjs;`. Nothing else in three.c3 changes.
#   tools/use-in-three.sh [path/to/three.c3]      (default: ../three.c3)
# Undo with `git checkout -- .` and `rm lib/fastjs.c3l` in three.c3.
set -e
here="$(cd "$(dirname "$0")/.." && pwd)"
three="$(cd "${1:-$here/../three.c3}" && pwd)"
cd "$three"
[ -e lib/fastjs.c3l ] || ln -s "$here" lib/fastjs.c3l
sed -i 's/"quickjs", "mcp"/"fastjs", "mcp"/' project.json
grep -rl '^import qjs;' src test | xargs -r sed -i 's/^import qjs;/import fastjs::qjs;/'
echo "three.c3 now builds on fastjs: cd $three && c3c build three -O3 --safe=no"
