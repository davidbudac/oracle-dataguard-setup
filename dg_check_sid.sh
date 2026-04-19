#!/usr/bin/env bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

printf "DEPRECATED: Use dg_triage_sid.sh\n" >&2
# exec replaces the shell, so dg_triage_sid.sh's exit code is the
# wrapper's exit code. The previous `|| true ; exit 0` masked all
# failures, which breaks CI that still invokes the deprecated name.
exec bash "${SCRIPT_DIR}/dg_triage_sid.sh" "$@"
