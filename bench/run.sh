#!/bin/bash
# Time each benchmark in fastjs and in QuickJS (through three.c3's prebuilt archive).
#   bench/run.sh [qjsrun-binary]
# Build fjs optimized first: c3c build fjs -O3 --safe=no
cd "$(dirname "$0")/.."
QJS=${1:-bench/qjsrun/build/qjsrun}
[ -x "$QJS" ] || QJS=""
printf "%-14s %10s %10s %8s\n" benchmark fastjs quickjs ratio
for f in bench/*.js; do
	t0=$(date +%s.%N); a=$(./build/fjs "$f"); t1=$(date +%s.%N)
	fj=$(echo "$t1 - $t0" | bc)
	if [ -n "$QJS" ]; then
		t0=$(date +%s.%N); b=$("$QJS" "$f"); t1=$(date +%s.%N)
		qj=$(echo "$t1 - $t0" | bc)
		[ "$a" != "$b" ] && echo "  result mismatch: fastjs=$a quickjs=$b"
		printf "%-14s %9.3fs %9.3fs %7.2fx\n" "$(basename $f .js)" "$fj" "$qj" "$(echo "$qj / $fj" | bc -l)"
	else
		printf "%-14s %9.3fs\n" "$(basename $f .js)" "$fj"
	fi
done
