#!/bin/sh
# Regenerate the expected output of every test with node (the reference implementation).
cd "$(dirname "$0")"
for f in *.js; do node "$f" > "${f%.js}.out" 2>&1; done
