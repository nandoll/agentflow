# shellcheck shell=bash
# af status: tareas abiertas en todos los worktrees del repo.

cmd_status() {
  af_load_config
  local found=0 w b taskf slug author reviewer branch rounds hand
  printf '%-28s %-7s %-8s %-30s %-6s %s\n' TAREA AUTOR REVISOR RAMA RONDAS WORKTREE
  while IFS=$'\t' read -r w b; do
    for taskf in "$w/$AF_TASKS_DIR"/*/TASK; do
      [ -f "$taskf" ] || continue
      branch="$(af_task_get "$taskf" branch)"
      [ "refs/heads/$branch" = "$b" ] || continue   # solo la tarea propia de cada worktree
      slug="$(af_task_get "$taskf" slug)"
      author="$(af_task_get "$taskf" author)"
      reviewer="$(af_task_get "$taskf" reviewer)"
      rounds=0
      [ -f "$(dirname "$taskf")/REVIEW.md" ] && rounds="$(grep -c '^## Ronda ' "$(dirname "$taskf")/REVIEW.md" || true)"
      hand="$(cd "$w" && "$AF_HOME/bin/agentflow" handoff-check "$slug" >/dev/null 2>&1 && echo ok || echo '!handoff')"
      printf '%-28s %-7s %-8s %-30s %-6s %s %s\n' "$slug" "$author" "$reviewer" "$branch" "$rounds" "$w" "$([ "$hand" = ok ] || echo "$hand")"
      found=1
    done
  done < <(git worktree list --porcelain | awk '/^worktree /{w=substr($0,10)} /^branch /{print w "\t" substr($0,8)}')
  [ "$found" = 1 ] || info "no hay tareas abiertas (crea una con: af new-task SLUG)"
}
