# shellcheck shell=bash
# af install [DIR] [--local]: instala o actualiza la capa de flujo en un repositorio.
#
# Archivos GESTIONADOS (se sobrescriben en cada install):
#   .agentflow/{bin,lib,templates,VERSION}
#   el bloque <!-- agentflow:begin --> ... <!-- agentflow:end --> de AGENTS.md
# Archivos del PROYECTO (se crean una vez y nunca se sobrescriben):
#   resto de AGENTS.md, CLAUDE.md, .agentflow/config, ajustes de Claude y Codex
#
# Modo local (--local, o AF_LOCAL=1 en .agentflow/config): pensado para repos de
# equipo donde solo deben llegar los cambios. Las rutas de la metodología se
# excluyen en .git/info/exclude (compartido por todos los worktrees), los
# ajustes de Claude van en .claude/settings.local.json y no se crea
# .codex/config.toml (Codex solo revisa, y `af review` ya lo fuerza a solo lectura).

cmd_install() {
  local target="." want_local=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --local) want_local=1 ;;
      -*) die "opción desconocida: $1" ;;
      *) target="$1" ;;
    esac
    shift
  done
  [ -d "$target" ] || die "no existe el directorio: $target"
  target="$(cd "$target" && git rev-parse --show-toplevel 2>/dev/null)" \
    || die "$target no es un repositorio git (ejecuta git init primero)"

  local dest="$target/.agentflow" t="$AF_HOME/templates"
  R_PROJECT="$(basename "$target")"

  # 0. Modo y rutas, desde la configuración existente o la plantilla.
  local cfg="$dest/config"
  [ -f "$cfg" ] || cfg="$t/agentflow.config"
  local I_LOCAL I_LOCAL_PATHS
  eval "$(
    AF_TASKS_DIR=docs/agents/tasks AF_LOCAL=0 AF_LOCAL_PATHS="$AF_LOCAL_PATHS_DEFAULT"
    # shellcheck disable=SC1090
    . "$cfg"
    printf 'R_TASKS_DIR=%q\nI_LOCAL=%q\nI_LOCAL_PATHS=%q\n' "${AF_TASKS_DIR%/}" "$AF_LOCAL" "$AF_LOCAL_PATHS"
  )"
  if [ "$want_local" = 1 ] && [ "$I_LOCAL" != 1 ]; then
    [ -f "$dest/config" ] && die ".agentflow/config ya existe con AF_LOCAL=$I_LOCAL; cámbialo a AF_LOCAL=1 y vuelve a ejecutar install"
    I_LOCAL=1
  fi

  local paths p
  paths="$(read -r -a ps <<< "$I_LOCAL_PATHS"; for p in "${ps[@]}"; do echo "${p%/}"; done; echo "$R_TASKS_DIR")"

  # 1. Modo local: solo en el checkout principal (los worktrees reciben enlaces),
  #    excluir ANTES de crear nada, nunca sobre rutas versionadas, y comprobar
  #    que la exclusión gana (una negación en .gitignore tiene prioridad sobre info/exclude).
  if [ "$I_LOCAL" = 1 ]; then
    local main
    main="$(git -C "$target" worktree list --porcelain | awk '/^worktree / && !d { print substr($0, 10); d = 1 }')"
    [ "$target" = "$main" ] || die "en modo local, instala desde el checkout principal ($main), no desde un worktree"
    while IFS= read -r p; do
      [ -z "$(git -C "$target" ls-files -- "$p" | awk 'NR == 1')" ] \
        || die "$p está versionado en el repo: el modo local no puede ocultarlo"
    done <<< "$paths"
    local excl
    excl="$(git -C "$target" rev-parse --path-format=absolute --git-path info/exclude)"
    mkdir -p "$(dirname "$excl")"
    touch "$excl"
    grep -qxF '# agentflow: capa local (la metodología no entra al repositorio)' "$excl" \
      || printf '\n# agentflow: capa local (la metodología no entra al repositorio)\n' >> "$excl"
    while IFS= read -r p; do
      grep -qxF "/$p" "$excl" || echo "/$p" >> "$excl"
    done <<< "$paths"
    while IFS= read -r p; do
      git -C "$target" check-ignore -q -- "$p" \
        || die "$p no queda ignorado (¿una negación en .gitignore?); el modo local no puede ocultarlo"
    done <<< "$paths"
    info "modo local: rutas excluidas en $excl"
  fi

  # 2. Copia del kit (gestionado). Si ya estamos ejecutando desde esa copia, no se copia sobre sí misma.
  if [ "$(cd -P "$AF_HOME" && pwd)" != "$(mkdir -p "$dest" && cd -P "$dest" && pwd)" ]; then
    rm -rf "$dest/bin" "$dest/lib" "$dest/templates"
    cp -a "$AF_HOME/bin" "$AF_HOME/lib" "$AF_HOME/templates" "$AF_HOME/VERSION" "$dest/"
    info "kit $AF_VERSION copiado en .agentflow/"
  fi

  # 3. Configuración del proyecto.
  if [ ! -f "$dest/config" ]; then
    cp "$t/agentflow.config" "$dest/config"
    if [ "$I_LOCAL" = 1 ]; then
      sed -e 's/^AF_LOCAL=0$/AF_LOCAL=1/' "$dest/config" > "$dest/config.af.tmp"
      mv "$dest/config.af.tmp" "$dest/config"
    fi
    info "creado .agentflow/config (revísalo: AF_BASE, AF_CHECK_CMD y AF_REVIEW_FOCUS)"
  fi

  # 4. AGENTS.md: esqueleto si no existe + bloque gestionado del protocolo.
  #    El bloque se reemplaza in situ; otros bloques gestionados (p. ej. el de Next.js) no se tocan.
  if [ ! -f "$target/AGENTS.md" ]; then
    af_render "$t/AGENTS.project.md" "$target/AGENTS.md"
    info "creado AGENTS.md (completa las secciones del proyecto)"
  fi
  local block; block="$(mktemp)"
  af_render "$t/protocol.md" "$block.raw"
  # Líneas por modo: "@@local " solo en modo local, "@@tracked " solo en modo versionado.
  if [ "$I_LOCAL" = 1 ]; then
    sed -e '/^@@tracked /d' -e 's/^@@local *//' "$block.raw" > "$block"
  else
    sed -e '/^@@local/d' -e 's/^@@tracked //' "$block.raw" > "$block"
  fi
  rm -f "$block.raw"
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

  # 5. Puente de Claude.
  if [ ! -f "$target/CLAUDE.md" ]; then
    af_render "$t/CLAUDE.md" "$target/CLAUDE.md"
    info "creado CLAUDE.md (importa AGENTS.md)"
  elif ! grep -q '^@AGENTS.md' "$target/CLAUDE.md"; then
    warn "CLAUDE.md existe pero no importa @AGENTS.md: agrégalo como primera línea"
  fi

  # 6. Permisos de cada agente.
  local cs
  if [ "$I_LOCAL" = 1 ]; then
    cs="$target/.claude/settings.local.json"
    if [ ! -f "$cs" ]; then
      mkdir -p "$target/.claude"
      cp "$t/claude.settings.local.json" "$cs"
      info "creado .claude/settings.local.json (hook de HANDOFF, permisos y sin atribución en commits)"
    elif ! grep -q 'handoff-check' "$cs"; then
      warn ".claude/settings.local.json existe sin el hook Stop de handoff-check; cópialo de .agentflow/templates/claude.settings.local.json"
    fi
    info "modo local: no se crea .codex/config.toml (Codex revisa en solo lectura forzada)"
  else
    cs="$target/.claude/settings.json"
    if [ ! -f "$target/.codex/config.toml" ]; then
      mkdir -p "$target/.codex"
      cp "$t/codex.config.toml" "$target/.codex/config.toml"
      info "creado .codex/config.toml (sandbox workspace-write, sin red)"
    fi
    if [ ! -f "$cs" ]; then
      mkdir -p "$target/.claude"
      cp "$t/claude.settings.json" "$cs"
      info "creado .claude/settings.json (hook de HANDOFF y permisos)"
    elif ! grep -q 'handoff-check' "$cs"; then
      warn ".claude/settings.json existe sin el hook Stop de handoff-check; cópialo de .agentflow/templates/claude.settings.json"
    fi
  fi

  # 7. Carpeta de tareas.
  mkdir -p "$target/$R_TASKS_DIR"
  if [ "$I_LOCAL" != 1 ]; then
    [ -e "$target/$R_TASKS_DIR/.gitkeep" ] || : > "$target/$R_TASKS_DIR/.gitkeep"
  fi

  info "listo. Siguiente: .agentflow/bin/af doctor"
}
