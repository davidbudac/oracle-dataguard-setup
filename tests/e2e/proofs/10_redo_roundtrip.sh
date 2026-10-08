#!/usr/bin/env bash
# proof: a row committed on the primary after the build is covered by the
# standby's applied SCN (PROVE_REDO_ROUNDTRIP)
proof_redo_roundtrip() {
    [[ "${PROVE_REDO_ROUNDTRIP:-yes}" == "yes" ]] || return 2
    local seq; seq=$(mark "redo-roundtrip ${SCN_ID} $(date '+%F %T')")
    [[ "$seq" =~ ^[0-9]+$ ]] || { log_fail "marker insert failed: ${seq}"; return 1; }
    if wait_applied_past "$seq" 300; then
        log_pass "standby applied log sequence ${seq} (applied up to $(standby_applied_seq))"
    else
        log_fail "standby did not apply sequence ${seq} within 300 s (applied up to $(standby_applied_seq))"
        return 1
    fi
    mrp_running && log_pass "MRP still running" || { log_fail "MRP not running after the roundtrip"; return 1; }
}
