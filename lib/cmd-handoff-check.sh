# shellcheck shell=bash
# af handoff-check [SLUG] [--hook]
# HANDOFF.md está al día si: (a) tiene cambios sin commitear, o (b) su último
# commit es igual o posterior al último commit de código y no hay código sin
# commitear. Con --hook (hook Stop de Claude Code) sale con 2 para pedir que lo
# actualice, y respeta stop_hook_active para no entrar en bucle.

cmd_handoff_check() {
  local slug="" hook=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --hook) hook=1 ;;
      -*) die "opción desconocida: $1" ;;
      *) slug="$1" ;;
    esac
    shift
  done

  if [ "$hook" = 1 ]; then
    local input; input="$(cat 2>/dev/null || true)"
    printf '%s' "$input" | grep -Eq '"stop_hook_active"[[:space:]]*:[[:space:]]*true' && return 0
    git rev-parse --show-toplevel >/dev/null 2>&1 || return 0
  fi

  af_load_config
  [ -n "$slug" ] || slug="$(af_slug_from_branch)"
  if [ -z "$slug" ]; then
    [ "$hook" = 1 ] || info "la rama actual no es de una tarea (feat/* o codex/*): nada que comprobar"
    return 0
  fi
  local tdir="$AF_TASKS_DIR/$slug" handoff
  handoff="$tdir/HANDOFF.md"
  if [ ! -f "$ROOT/$tdir/TASK" ]; then
    [ "$hook" = 1 ] && return 0
    die "no existe $tdir/TASK en este worktree"
  fi
  local base; base="$(af_task_get "$ROOT/$tdir/TASK" base)"

  cd "$ROOT"
  local last_code last_handoff dirty_code dirty_handoff
  last_code="$(git log -1 --format=%ct "$base..HEAD" -- . ":(exclude)$tdir" 2>/dev/null || true)"
  last_handoff="$(git log -1 --format=%ct "$base..HEAD" -- "$handoff" 2>/dev/null || true)"
  dirty_code="$(git status --porcelain -- . ":(exclude)$tdir" | head -1)"
  dirty_handoff="$(git status --porcelain -- "$handoff" | head -1)"

  local problem=""
  if [ -n "$last_code" ] || [ -n "$dirty_code" ]; then
    if [ -n "$last_code" ] && [ -z "$last_handoff" ]; then
      problem="hay código commiteado pero HANDOFF.md nunca se commiteó (commitea la carpeta de la tarea con el código)"
    elif [ -n "$dirty_handoff" ]; then
      :
    elif [ -n "$dirty_code" ]; then
      problem="hay cambios de código sin commitear y HANDOFF.md no se ha tocado"
    elif [ -z "$last_handoff" ] || [ "$last_handoff" -lt "$last_code" ]; then
      problem="el último commit de código es posterior al último commit de HANDOFF.md"
    fi
    if [ -z "$problem" ] && grep -q 'AF:PENDIENTE' "$handoff"; then
      problem="HANDOFF.md aún tiene marcas AF:PENDIENTE"
    fi
  fi

  if [ -z "$problem" ]; then
    [ "$hook" = 1 ] || info "HANDOFF.md de '$slug' al día"
    return 0
  fi
  local msg="HANDOFF.md de la tarea '$slug' está desactualizado: $problem. Actualiza $handoff (Estado, Hecho, Siguiente paso, Decisiones, Cómo verificar) y commitéalo con el código antes de terminar."
  if [ "$hook" = 1 ]; then
    printf '%s\n' "$msg" >&2
    exit 2
  fi
  die "$msg"
}
