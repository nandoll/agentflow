# shellcheck shell=bash
# af install [DIR]: instala o actualiza la capa de flujo en un repositorio.
#
# Archivos GESTIONADOS (se sobrescriben en cada install):
#   .agentflow/{bin,lib,templates,VERSION}
#   el bloque <!-- agentflow:begin --> ... <!-- agentflow:end --> de AGENTS.md
# Archivos del PROYECTO (se crean una vez y nunca se sobrescriben):
#   resto de AGENTS.md, CLAUDE.md, .agentflow/config, .codex/config.toml,
#   .claude/settings.json

cmd_install() {
  local target="${1:-.}"
  [ -d "$target" ] || die "no existe el directorio: $target"
  target="$(cd "$target" && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "$1 no es un repositorio git (ejecuta git init primero)"

  local dest="$target/.agentflow" t="$AF_HOME/templates"
  R_PROJECT="$(basename "$target")"
  R_TASKS_DIR=docs/agents/tasks

  # 1. Copia del kit (gestionado). Si ya estamos ejecutando desde esa copia, no se copia sobre sí misma.
  if [ "$(cd -P "$AF_HOME" && pwd)" != "$(mkdir -p "$dest" && cd -P "$dest" && pwd)" ]; then
    rm -rf "$dest/bin" "$dest/lib" "$dest/templates"
    cp -a "$AF_HOME/bin" "$AF_HOME/lib" "$AF_HOME/templates" "$AF_HOME/VERSION" "$dest/"
    info "kit $AF_VERSION copiado en .agentflow/"
  fi

  # 2. Configuración del proyecto.
  if [ ! -f "$dest/config" ]; then
    cp "$t/agentflow.config" "$dest/config"
    info "creado .agentflow/config (revísalo: AF_CHECK_CMD y AF_REVIEW_FOCUS)"
  fi
  # shellcheck disable=SC1091
  ( . "$dest/config"; echo "${AF_TASKS_DIR:-docs/agents/tasks}" ) > "$dest/.tasks_dir.tmp"
  R_TASKS_DIR="$(cat "$dest/.tasks_dir.tmp")"; rm -f "$dest/.tasks_dir.tmp"

  # 3. AGENTS.md: esqueleto si no existe + bloque gestionado del protocolo.
  if [ ! -f "$target/AGENTS.md" ]; then
    af_render "$t/AGENTS.project.md" "$target/AGENTS.md"
    info "creado AGENTS.md (completa las secciones del proyecto)"
  fi
  local block; block="$(mktemp)"
  af_render "$t/protocol.md" "$block"
  if grep -q '<!-- agentflow:begin' "$target/AGENTS.md"; then
    awk -v cf="$block" '
      BEGIN { while ((getline l < cf) > 0) c = c l "\n" }
      /<!-- agentflow:begin/ { printf "%s", c; skip = 1; next }
      /<!-- agentflow:end -->/ { skip = 0; next }
      !skip { print }' "$target/AGENTS.md" > "$target/AGENTS.md.af.tmp"
    mv "$target/AGENTS.md.af.tmp" "$target/AGENTS.md"
  else
    { printf '\n'; cat "$block"; } >> "$target/AGENTS.md"
  fi
  rm -f "$block"
  info "bloque del protocolo actualizado en AGENTS.md (v$AF_VERSION)"

  # 4. Puente de Claude.
  if [ ! -f "$target/CLAUDE.md" ]; then
    af_render "$t/CLAUDE.md" "$target/CLAUDE.md"
    info "creado CLAUDE.md (importa AGENTS.md)"
  elif ! grep -q '^@AGENTS.md' "$target/CLAUDE.md"; then
    warn "CLAUDE.md existe pero no importa @AGENTS.md: agrégalo como primera línea"
  fi

  # 5. Permisos de cada agente.
  if [ ! -f "$target/.codex/config.toml" ]; then
    mkdir -p "$target/.codex"
    cp "$t/codex.config.toml" "$target/.codex/config.toml"
    info "creado .codex/config.toml (sandbox workspace-write, sin red)"
  fi
  if [ ! -f "$target/.claude/settings.json" ]; then
    mkdir -p "$target/.claude"
    cp "$t/claude.settings.json" "$target/.claude/settings.json"
    info "creado .claude/settings.json (hook de HANDOFF y permisos)"
  elif ! grep -q 'handoff-check' "$target/.claude/settings.json"; then
    warn ".claude/settings.json existe sin el hook Stop de handoff-check; cópialo de .agentflow/templates/claude.settings.json"
  fi

  # 6. Carpeta de tareas.
  mkdir -p "$target/$R_TASKS_DIR"
  [ -e "$target/$R_TASKS_DIR/.gitkeep" ] || : > "$target/$R_TASKS_DIR/.gitkeep"

  info "listo. Siguiente: .agentflow/bin/af doctor"
}
