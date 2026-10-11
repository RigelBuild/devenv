#!/usr/bin/env bash
# A non-canonical homeDir would leave $HOME 0755, so the option rejects the shape at eval.
set -euo pipefail

[ "$(devenv eval containers.ok.homeDir | jq -r '."containers.ok.homeDir"')" = /home/agent ]

for bad in '/home/agent/' 'relative' '/' '/a/..' '/a/./b' '//x'; do
  printf '{ ... }: { containers.bad.homeDir = "%s"; }\n' "$bad" > devenv.local.nix
  if out=$(devenv eval containers.bad.homeDir 2>&1); then
    echo "homeDir '$bad' was accepted" >&2
    exit 1
  fi
  grep -q 'is not of type' <<<"$out"
done
rm devenv.local.nix
