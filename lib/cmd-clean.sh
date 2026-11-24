# shellcheck shell=bash
# af clean SLUG [--force]: quita el worktree de una tarea. No borra la rama.
#
# La tarea cuenta como integrada si su contenido ya está en alguno de
# AF_CLEAN_TARGETS (por defecto, su base). Se detectan también los merges con
# squash, salvo que el destino haya vuelto a tocar esas líneas. Con
# AF_FETCH_BASE=1, los destinos remotos se actualizan antes de decidir.
# `--force` solo omite la comprobación de integración.
#
# `git worktree remove` borra sin avisar los archivos ignorados, así que antes se
# comprueba que solo haya enlaces locales y salidas regenerables
# (AF_CLEAN_DISPOSABLE). En modo local, los archivos de la tarea se conservan en
# el checkout principal.

cmd_clean() {
  af_load_config
  local slug="" force=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force) force=1 ;;
      -*) die "opción desconocida: $1" ;;
      *) slug="$1" ;;
    esac
    shift
  done
  [ -n "$slug" ] || die "uso: af clean SLUG [--force]"
  local taskf branch base wt
  taskf="$(af_find_task "$slug")"
  [ -n "$taskf" ] || die "no encuentro la tarea '$slug'"
  branch="$(af_task_get "$taskf" branch)"
  base="$(af_task_get "$taskf" base)"
  wt="$(af_worktree_for_branch "$branch")"
  [ -n "$wt" ] || die "la rama $branch no tiene worktree"
  [ "$wt" != "$MAIN_ROOT" ] || die "la tarea está en el worktree principal (--here); cambia de rama a mano"

  local -a targets; local tg integrated=""
  read -r -a targets <<< "${AF_CLEAN_TARGETS:-$base}"
  for tg in "${targets[@]}"; do
    af_fetch_ref "$tg"
    if af_contains "$branch" "$tg"; then
      info "  $tg: contiene $branch"
      integrated="$tg"
    else
      info "  $tg: aún no contiene $branch"
    fi
  done
  if [ -z "$integrated" ] && [ "$force" = 0 ]; then
    die "$branch no está integrada en ninguno de: ${targets[*]}. Si la integraron con ajustes posteriores, usa --force para quitar el worktree igualmente"
  fi

  local artifacts
  artifacts="$(af_user_artifacts "$wt")"
  if [ -n "$artifacts" ]; then
    die "el worktree tiene archivos ignorados que git borraría sin avisar: $(echo "$artifacts" | tr '\n' ' ')
Muévelos o, si son salidas regenerables, agrégalos a AF_CLEAN_DISPOSABLE en .agentflow/config"
  fi

  git worktree remove "$wt"
  info "worktree $wt eliminado. La rama $branch se conserva (bórrala con: git branch -D $branch)"
  if [ "$AF_LOCAL" = 1 ]; then
    info "los archivos de la tarea siguen en $MAIN_ROOT/$AF_TASKS_DIR/$slug"
  fi
}
