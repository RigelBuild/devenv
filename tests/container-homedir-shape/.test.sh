#!/usr/bin/env bash
# A non-canonical homeDir would leave $HOME 0755, so the option rejects the shape at eval.
set -euo pipefail

[ "$(devenv eval containers.ok.homeDir | jq -r '."containers.ok.homeDir"')" = /home/agent ]

check() {
  printf '{ ... }: { containers.probe.homeDir = "%s"; }\n' "$1" > devenv.local.nix
  devenv eval containers.probe.homeDir 2>&1
}

# Dot-led names are ordinary components, not `.` or `..`.
for good in '/.cfg' '/..x' '/a/...'; do
  if ! out=$(check "$good"); then
    echo "homeDir '$good' was rejected: $out" >&2
    exit 1
  fi
done

for bad in '/home/agent/' 'relative' '/' '/a/..' '/a/./b' '//x'; do
  if out=$(check "$bad"); then
    echo "homeDir '$bad' was accepted" >&2
    exit 1
  fi
  grep -q 'is not of type' <<<"$out"
done
rm devenv.local.nix
