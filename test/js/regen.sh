#!/bin/sh
# Regenerate the expected output of every test with node (the reference implementation).
cd "$(dirname "$0")"
export TZ=Europe/Tallinn
for f in *.js *.mjs; do node "$f" > "${f%.*}.out" 2>&1; done
