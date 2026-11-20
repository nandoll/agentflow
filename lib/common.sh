# shellcheck shell=bash
# Funciones compartidas por todos los comandos de agentflow.

AF_VERSION="$(tr -d '[:space:]' < "$AF_HOME/VERSION")"

die()  { printf 'af: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'af: aviso: %s\n' "$*" >&2; }
info() { printf 'af: %s\n' "$*"; }

af_help() {
  cat <<EOF
agentflow $AF_VERSION: flujo Claude Code + Codex por archivos y git.

Uso: af <comando> [opciones]

  install [DIR]               Instala o actualiza el flujo en el repo DIR (por defecto, el actual)
  new-task SLUG [--author claude|codex] [--base RAMA] [--here]
                              Crea rama, worktree y carpeta de la tarea (PLAN, HANDOFF, TASK)
  review [SLUG] [--reviewer claude|codex] [--ronda-extra]
                              Revisión de solo lectura por el agente que NO es el autor -> REVIEW.md
                              (máximo AF_REVIEW_MAX_RONDAS rondas; después decide el usuario)
  handoff-check [SLUG] [--hook]
                              Falla si HANDOFF.md no refleja los últimos cambios de la tarea
  status                      Lista las tareas abiertas en todos los worktrees
  check                       Ejecuta la verificación del proyecto (AF_CHECK_CMD)
  clean SLUG [--force]        Quita el worktree de una tarea ya integrada en su base
  doctor                      Diagnostica herramientas, configuración y riesgos de permisos
  version                     Muestra la versión

Configuración del proyecto: .agentflow/config
EOF
}

af_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "no estás dentro de un repositorio git"
}

# Carga la configuración del proyecto con valores por defecto. Define ROOT.
af_load_config() {
  ROOT="$(af_repo_root)"
  AF_BASE=main
  AF_TASKS_DIR=docs/agents/tasks
  AF_WORKTREE_ROOT=..
  AF_CHECK_CMD=""
  AF_REVIEW_FOCUS=""
  AF_DEFAULT_AUTHOR=claude
  AF_CODEX_REVIEW_ARGS=""
  AF_REVIEW_MAX_RONDAS=3
  if [ -f "$ROOT/.agentflow/config" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/.agentflow/config"
  fi
}

af_other() {
  case "$1" in
    claude) echo codex ;;
    codex)  echo claude ;;
    *) die "agente desconocido: $1 (usa claude o codex)" ;;
  esac
}

af_branch_for() {
  case "$1" in
    claude) echo "feat/$2" ;;
    codex)  echo "codex/$2" ;;
    *) die "agente desconocido: $1" ;;
  esac
}

af_current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null || true; }

af_slug_from_branch() {
  local b; b="$(af_current_branch)"
  case "$b" in
    feat/*|codex/*) echo "${b#*/}" ;;
    *) echo "" ;;
  esac
}

# af_task_get ARCHIVO_TASK CLAVE
af_task_get() { sed -n "s/^$2=//p" "$1" | head -1; }

# Ruta del worktree donde está desprotegida una rama (vacío si no hay).
af_worktree_for_branch() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{ w = substr($0, 10) }
    $0 == "branch " b { print w }'
}

# Busca el archivo TASK de una tarea: primero en el repo actual, luego en el
# worktree de su rama (feat/ o codex/).
af_find_task() {
  local slug="$1" w b
  if [ -f "$ROOT/$AF_TASKS_DIR/$slug/TASK" ]; then
    echo "$ROOT/$AF_TASKS_DIR/$slug/TASK"; return
  fi
  for b in "feat/$slug" "codex/$slug"; do
    w="$(af_worktree_for_branch "$b")"
    if [ -n "$w" ] && [ -f "$w/$AF_TASKS_DIR/$slug/TASK" ]; then
      echo "$w/$AF_TASKS_DIR/$slug/TASK"; return
    fi
  done
  echo ""
}

# af_render PLANTILLA SALIDA: sustituye {{VAR}} con las variables R_*.
af_render() {
  sed -e "s|{{VERSION}}|${AF_VERSION}|g" \
      -e "s|{{PROJECT}}|${R_PROJECT:-}|g" \
      -e "s|{{SLUG}}|${R_SLUG:-}|g" \
      -e "s|{{AUTHOR}}|${R_AUTHOR:-}|g" \
      -e "s|{{REVIEWER}}|${R_REVIEWER:-}|g" \
      -e "s|{{BRANCH}}|${R_BRANCH:-}|g" \
      -e "s|{{BASE}}|${R_BASE:-}|g" \
      -e "s|{{DATE}}|${R_DATE:-}|g" \
      -e "s|{{TASKS_DIR}}|${R_TASKS_DIR:-}|g" \
      "$1" > "$2"
}
