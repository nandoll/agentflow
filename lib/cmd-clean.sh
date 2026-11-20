# shellcheck shell=bash
# af clean SLUG [--force]: quita el worktree de una tarea. No borra la rama.

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
  local main_wt
  main_wt="$(git worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
  [ "$wt" != "$main_wt" ] || die "la tarea está en el worktree principal (--here); cambia de rama a mano"
  if ! git merge-base --is-ancestor "$branch" "$base" && [ "$force" = 0 ]; then
    die "$branch no está integrada en $base; usa --force para quitar el worktree igualmente"
  fi
  git worktree remove "$wt"
  info "worktree $wt eliminado. La rama $branch se conserva (bórrala con: git branch -d $branch)"
}
