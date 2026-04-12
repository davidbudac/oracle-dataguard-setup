#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf "DEPRECATED: Use dg_triage_sid.sh\n" >&2
bash "${SCRIPT_DIR}/dg_triage_sid.sh" "$@" || true
exit 0
