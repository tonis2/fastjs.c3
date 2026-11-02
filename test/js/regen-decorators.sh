#!/bin/sh
# node can't run decorators yet: lower them with esbuild, then take node's output.
set -e
cd "$(dirname "$0")"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for f in decorators*.js decorators*.mjs; do
	# Modules are bundled, so the modules they import are lowered too.
	case "$f" in *.mjs) bundle="--bundle --format=esm" ;; *) bundle="" ;; esac
	npx -y esbuild@0.24.0 "$f" $bundle --target=es2022 --log-level=error --outfile="$tmp/$f"
	node "$tmp/$f" > "${f%.*}.out"
done
