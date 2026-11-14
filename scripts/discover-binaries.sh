#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root to read /proc/<pid>/exe symlinks." >&2
   exit 1
fi

echo "# Ground-truth executables currently running inside Docker containers:"
echo "# Copy these paths into policies/standalone-docker.yaml under matchBinaries:"
echo ""

declare -A UNIQUE_BINARIES

for cid in $(docker ps -q); do
  cname=$(docker inspect --format '{{.Name}}' "$cid" | sed 's/^\///')
  echo "# --- Container: $cname ($cid) ---"
  for pid in $(docker top "$cid" -eo pid | tail -n +2); do
    exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)
    if [[ -n "$exe" ]]; then
      echo "#   PID $pid -> $exe"
      UNIQUE_BINARIES["$exe"]=1
    fi
  done
done

echo ""
echo "# Deduplicated YAML snippet:"
for bin in "${!UNIQUE_BINARIES[@]}"; do
  echo "                - \"$bin\""
done | sort

