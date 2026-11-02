#!/bin/bash
# Run every test/js/*.js with build/fjs and compare its output with the .out file node produced.
# Build first: c3c build fjs. FJS_FLAGS=--gc-stress runs every test with a collection at each safe point.
cd "$(dirname "$0")/../.."
pass=0
fail=0
for f in test/js/*.js test/js/*.mjs; do
	expected="${f%.*}.out"
	actual=$(./build/fjs $FJS_FLAGS "$f" 2>&1)
	if [ "$actual" == "$(cat "$expected")" ]; then
		pass=$((pass + 1))
	else
		fail=$((fail + 1))
		echo "FAIL $f"
		diff <(echo "$actual") "$expected" | head -${DIFF_LINES:-12}
	fi
done
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
