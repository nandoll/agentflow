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
    if command -v "$t" >/dev/null; then ok "$t: $("$t" --version 2>/dev/null | awk 'NR == 1')"; else fail "$t no está en PATH"; fi
  done
  command -v jq >/dev/null && ok "jq (opcional)" || note "jq no está instalado (opcional)"
  local gv; gv="$(git --version | sed -n 's/^git version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p')"
  # shellcheck disable=SC2086
  set -- $gv
  if [ "${1:-0}" -gt 2 ] || { [ "${1:-0}" = 2 ] && [ "${2:-0}" -ge 38 ]; }; then
    ok "git >= 2.38 (af clean detecta merges con squash)"
  else
    note "git < 2.38: af clean no detecta merges con squash (usa --force)"
  fi

  echo "Repositorio"
  if ! git rev-parse --show-toplevel >/dev/null 2>&1; then fail "no es un repositorio git"; return 1; fi
  af_load_config
  git -C "$ROOT" rev-parse --verify --quiet "$AF_BASE^{commit}" >/dev/null \
    && ok "rama base $AF_BASE con commits" \
    || note "la rama base $AF_BASE aún no existe o no tiene commits (new-task la necesita)"
  [ -n "$AF_BRANCH_TEMPLATE" ] \
    && ok "ramas con plantilla: $(af_branch_for claude '<slug>' "$AF_BRANCH_TYPE")" \
    || ok "ramas clásicas: feat/<slug> o codex/<slug>"

  echo "Capa de flujo"
  [ -f "$ROOT/.agentflow/VERSION" ] && ok ".agentflow v$(tr -d '[:space:]' < "$ROOT/.agentflow/VERSION")" || fail ".agentflow/ no instalado (af install)"
  if [ -f "$ROOT/AGENTS.md" ] && grep -q '<!-- agentflow:begin' "$ROOT/AGENTS.md"; then
    local v; v="$(sed -n 's/.*<!-- agentflow:begin v\([0-9.]*\).*/\1/p' "$ROOT/AGENTS.md" | awk 'NR == 1')"
    [ "$v" = "$AF_VERSION" ] && ok "AGENTS.md con protocolo v$v" || note "AGENTS.md tiene protocolo v$v; el kit es v$AF_VERSION (af install)"
    grep -q 'AF:COMPLETAR' "$ROOT/AGENTS.md" && note "AGENTS.md tiene secciones AF:COMPLETAR"
  else
    fail "AGENTS.md sin bloque de protocolo"
  fi
  [ -f "$ROOT/CLAUDE.md" ] && grep -q '^@AGENTS.md' "$ROOT/CLAUDE.md" && ok "CLAUDE.md importa AGENTS.md" || fail "CLAUDE.md no importa @AGENTS.md"
  [ -n "$AF_CHECK_CMD" ] && ok "AF_CHECK_CMD: $AF_CHECK_CMD" || note "AF_CHECK_CMD vacío"

  local cs="$ROOT/.claude/settings.json"
  [ "$AF_LOCAL" = 1 ] && cs="$ROOT/.claude/settings.local.json"
  grep -q 'handoff-check' "$cs" 2>/dev/null && ok "hook Stop de HANDOFF en ${cs#"$ROOT"/}" || note "sin hook Stop de HANDOFF en ${cs#"$ROOT"/}"

  if [ "$AF_LOCAL" = 1 ]; then
    echo "Capa local (nada de la metodología entra al repositorio)"
    local p tracked
    while IFS= read -r p; do
      tracked="$(git -C "$ROOT" ls-files -- "$p" | awk 'NR == 1')"
      if [ -n "$tracked" ]; then
        fail "$p está versionado: el modo local no lo oculta"
      elif ! git -C "$ROOT" check-ignore -q -- "$p"; then
        fail "$p no está ignorado (af install --local lo excluye)"
      else
        ok "$p fuera de git"
      fi
    done < <(af_local_paths)
    if grep -Eq '"commit"[[:space:]]*:[[:space:]]*""' "$cs" 2>/dev/null; then
      ok "Claude sin atribución en commits (attribution.commit vacío)"
    else
      note "Claude agregará su atribución a los commits: define \"attribution\": {\"commit\": \"\", \"pr\": \"\"} en ${cs#"$ROOT"/}"
    fi
    if [ "$ROOT" != "$MAIN_ROOT" ]; then
      [ -L "$ROOT/.agentflow" ] && ok "worktree con enlaces al checkout principal" || note "este worktree no tiene enlaces a la capa local"
    fi
  fi

  echo "Permisos de Codex"
  local pc="$ROOT/.codex/config.toml" uc="${CODEX_HOME:-$HOME/.codex}/config.toml"
  if [ -f "$pc" ]; then
    ok ".codex/config.toml: $(grep -E '^(sandbox_mode|approval_policy)' "$pc" | tr '\n' ' ')"
  elif [ "$AF_LOCAL" = 1 ]; then
    note "sin .codex/config.toml del proyecto (modo local: Codex solo revisa con solo lectura forzada)"
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
    local p2="$ROOT" trusted=0
    while :; do
      grep -Fq "[projects.\"$p2\"]" "$uc" && { trusted=1; break; }
      [ "$p2" = "/" ] && break
      p2="$(dirname "$p2")"
    done
    [ "$trusted" = 1 ] && ok "proyecto trusted para Codex (se aplica .codex/config.toml)" \
      || note "proyecto no trusted en Codex: ignorará .codex/config.toml"
  fi
  echo "Nota: af review fuerza sandbox read-only para Codex, sin importar la configuración."
  return "$bad"
}
