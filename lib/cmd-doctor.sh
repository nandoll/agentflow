# shellcheck shell=bash
# af doctor: comprueba herramientas, instalación del flujo y riesgos de permisos.

cmd_doctor() {
  local bad=0
  ok()   { printf '  ok     %s\n' "$*"; }
  note() { printf '  aviso  %s\n' "$*"; }
  fail() { printf '  FALTA  %s\n' "$*"; bad=1; }

  echo "Herramientas"
  local t
  for t in git claude codex; do
    if command -v "$t" >/dev/null; then ok "$t: $("$t" --version 2>/dev/null | head -1)"; else fail "$t no está en PATH"; fi
  done
  command -v jq >/dev/null && ok "jq (opcional)" || note "jq no está instalado (opcional)"

  echo "Repositorio"
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then fail "no es un repositorio git"; return 1; fi
  af_load_config
  git -C "$ROOT" rev-parse --verify --quiet "$AF_BASE^{commit}" >/dev/null \
    && ok "rama base $AF_BASE con commits" \
    || note "la rama base $AF_BASE aún no tiene commits (new-task lo necesita)"

  echo "Capa de flujo"
  [ -f "$ROOT/.agentflow/VERSION" ] && ok ".agentflow v$(tr -d '[:space:]' < "$ROOT/.agentflow/VERSION")" || fail ".agentflow/ no instalado (af install)"
  if [ -f "$ROOT/AGENTS.md" ] && grep -q '<!-- agentflow:begin' "$ROOT/AGENTS.md"; then
    local v; v="$(sed -n 's/.*<!-- agentflow:begin v\([0-9.]*\).*/\1/p' "$ROOT/AGENTS.md" | head -1)"
    [ "$v" = "$AF_VERSION" ] && ok "AGENTS.md con protocolo v$v" || note "AGENTS.md tiene protocolo v$v; el kit es v$AF_VERSION (af install)"
    grep -q 'AF:COMPLETAR' "$ROOT/AGENTS.md" && note "AGENTS.md tiene secciones AF:COMPLETAR"
  else
    fail "AGENTS.md sin bloque de protocolo"
  fi
  [ -f "$ROOT/CLAUDE.md" ] && grep -q '^@AGENTS.md' "$ROOT/CLAUDE.md" && ok "CLAUDE.md importa AGENTS.md" || fail "CLAUDE.md no importa @AGENTS.md"
  [ -n "$AF_CHECK_CMD" ] && ok "AF_CHECK_CMD: $AF_CHECK_CMD" || note "AF_CHECK_CMD vacío"
  grep -q 'handoff-check' "$ROOT/.claude/settings.json" 2>/dev/null && ok "hook Stop de HANDOFF en .claude/settings.json" || note "sin hook Stop de HANDOFF"

  echo "Permisos de Codex"
  local pc="$ROOT/.codex/config.toml" uc="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -f "$pc" ]; then
    ok ".codex/config.toml: $(grep -E '^(sandbox_mode|approval_policy)' "$pc" | tr '\n' ' ')"
  else
    fail "sin .codex/config.toml del proyecto"
  fi
  if [ -f "$uc" ]; then
    grep -Eq '^sandbox_mode *= *"danger-full-access"' "$uc" \
      && note "~/.codex/config.toml usa danger-full-access; el proyecto lo restringe solo si está como trusted"
    grep -Eq '^approval_policy *= *"never"' "$uc" \
      && note "~/.codex/config.toml usa approval_policy=never"
    grep -Fq '[projects."/"]' "$uc" \
      && note "~/.codex/config.toml marca \"/\" como trusted: cualquier repo clonado carga su .codex/ y sus hooks"
    local p="$ROOT" trusted=0
    while :; do
      grep -Fq "[projects.\"$p\"]" "$uc" && { trusted=1; break; }
      [ "$p" = "/" ] && break
      p="$(dirname "$p")"
    done
    [ "$trusted" = 1 ] && ok "proyecto trusted para Codex (se aplica .codex/config.toml)" \
      || note "proyecto no trusted en Codex: ignorará .codex/config.toml"
  fi
  echo "Nota: af review fuerza sandbox read-only para Codex, sin importar la configuración."
  return "$bad"
}
