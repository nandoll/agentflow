# shellcheck shell=bash
# af new-task SLUG [--author claude|codex] [--base RAMA] [--here]

cmd_new_task() {
  af_load_config
  local slug="" author="$AF_DEFAULT_AUTHOR" base="$AF_BASE" here=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --author) author="${2:?falta el valor de --author}"; shift ;;
      --base)   base="${2:?falta el valor de --base}"; shift ;;
      --here)   here=1 ;;
      -*) die "opción desconocida: $1" ;;
      *) [ -z "$slug" ] || die "sobra el argumento: $1"; slug="$1" ;;
    esac
    shift
  done
  [ -n "$slug" ] || die "uso: af new-task SLUG [--author claude|codex] [--base RAMA] [--here]"
  [[ $slug =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "el slug solo admite minúsculas, dígitos y guiones: $slug"

  local reviewer branch wt
  reviewer="$(af_other "$author")"
  branch="$(af_branch_for "$author" "$slug")"

  git rev-parse --verify --quiet "$base^{commit}" >/dev/null \
    || die "la rama base '$base' no tiene commits; haz el commit inicial primero"
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
    && die "la rama $branch ya existe"

  if [ "$here" = 1 ]; then
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "hay cambios sin commitear; no se puede cambiar de rama aquí"
    git -C "$ROOT" switch -c "$branch" "$base" >/dev/null
    wt="$ROOT"
  else
    local wroot
    case "$AF_WORKTREE_ROOT" in
      /*) wroot="$AF_WORKTREE_ROOT" ;;
      *)  wroot="$(cd "$ROOT/$AF_WORKTREE_ROOT" && pwd)" ;;
    esac
    wt="$wroot/$(basename "$ROOT")-$slug"
    [ -e "$wt" ] && die "ya existe $wt"
    git -C "$ROOT" worktree add -q -b "$branch" "$wt" "$base"
  fi

  local tdir="$wt/$AF_TASKS_DIR/$slug" t="$ROOT/.agentflow/templates"
  [ -d "$t" ] || t="$AF_HOME/templates"
  mkdir -p "$tdir"
  R_SLUG="$slug" R_AUTHOR="$author" R_REVIEWER="$reviewer" R_BRANCH="$branch" \
    R_BASE="$base" R_DATE="$(date +%F)"
  export R_SLUG R_AUTHOR R_REVIEWER R_BRANCH R_BASE R_DATE
  af_render "$t/task/PLAN.md" "$tdir/PLAN.md"
  af_render "$t/task/HANDOFF.md" "$tdir/HANDOFF.md"
  cat > "$tdir/TASK" <<EOF
slug=$slug
author=$author
reviewer=$reviewer
branch=$branch
base=$base
created=$(date +%F)
EOF

  info "tarea '$slug' creada"
  info "  rama:     $branch (desde $base)"
  info "  worktree: $wt"
  info "  autor:    $author · revisor: $reviewer"
  echo
  echo "Siguiente:"
  echo "  cd $wt && $author"
  echo "  y pídele: \"lee AGENTS.md y $AF_TASKS_DIR/$slug/HANDOFF.md; escribe PLAN.md para <objetivo> y detente para que lo apruebe\""
}
