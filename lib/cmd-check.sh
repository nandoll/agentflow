# shellcheck shell=bash
# af check: verificación determinista del proyecto (lint + tests).

cmd_check() {
  af_load_config
  [ -n "$AF_CHECK_CMD" ] || die "AF_CHECK_CMD está vacío en .agentflow/config"
  cd "$ROOT"
  info "ejecutando: $AF_CHECK_CMD"
  bash -c "$AF_CHECK_CMD"
}
