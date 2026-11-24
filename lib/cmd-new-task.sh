# shellcheck shell=bash
# af new-task SLUG [--author claude|codex] [--type TIPO] [--base RAMA] [--here] [--no-setup]
#
# Todo lo que se puede validar se valida antes de crear la rama. Lo que solo se
# puede validar después (el .gitignore de la base, los enlaces) deshace la rama
# y el worktree creados por esta misma invocación si falla.

cmd_new_task() {
  af_load_config
  local slug="" author="$AF_DEFAULT_AUTHOR" base="$AF_BASE" here=0 type="$AF_BRANCH_TYPE" setup=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --author) author="${2:?falta el valor de --author}"; shift ;;
      --base)   base="${2:?falta el valor de --base}"; shift ;;
      --type)   type="${2:?falta el valor de --type}"; shift ;;
      --here)   here=1 ;;
      --no-setup) setup=0 ;;
      -*) die "opción desconocida: $1" ;;
      *) [ -z "$slug" ] || die "sobra el argumento: $1"; slug="$1" ;;
    esac
    shift
  done
  [ -n "$slug" ] || die "uso: af new-task SLUG [--author claude|codex] [--type TIPO] [--base RAMA] [--here] [--no-setup]"
  [[ $slug =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || die "el slug solo admite letras, dígitos y guiones: $slug"
  [[ $type =~ ^[a-z][a-z0-9-]*$ ]] || die "el tipo solo admite minúsculas, dígitos y guiones: $type"

  local reviewer branch wt base_sha
  reviewer="$(af_other "$author")"
  branch="$(af_branch_for "$author" "$slug" "$type")"
  git check-ref-format --branch "$branch" >/dev/null 2>&1 || die "nombre de rama inválido: $branch (revisa AF_BRANCH_TEMPLATE)"

  # Base remota (p. ej. origin/main): se actualiza antes de ramificar si AF_FETCH_BASE=1.
  af_fetch_ref "$base"
  base_sha="$(git rev-parse --verify --quiet "$base^{commit}")" \
    || die "la rama base '$base' no existe o no tiene commits"
  git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
    && die "la rama $branch ya existe"

  if [ "$AF_LOCAL" = 1 ]; then
    [ ! -e "$MAIN_ROOT/$AF_TASKS_DIR/$slug" ] \
      || die "ya existe la tarea $AF_TASKS_DIR/$slug (en modo local las tareas cerradas se conservan; usa otro slug)"
    # Los documentos se escriben en el checkout principal: ahí tienen que seguir ignorados.
    local leaks; leaks="$(af_local_not_ignored "$MAIN_ROOT")"
    [ -z "$leaks" ] || die "en $MAIN_ROOT git no ignora: $(echo "$leaks" | tr '\n' ' ')(¿una negación en .gitignore?)"
    # Si la base versiona alguna ruta local, el checkout la sobrescribiría o la expondría.
    local -a lp; local in_base
    mapfile -t lp < <(af_local_paths)
    in_base="$(git ls-tree -r --name-only "$base_sha" -- "${lp[@]}" | awk 'NR == 1')"
    [ -z "$in_base" ] || die "la base $base versiona $in_base: el modo local no puede ocultarlo"
  fi

  local prev="" link=0
  if [ "$here" = 1 ]; then
    [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "hay cambios sin commitear; no se puede cambiar de rama aquí"
    prev="$(git -C "$ROOT" symbolic-ref -q --short HEAD || git -C "$ROOT" rev-parse HEAD)"
    wt="$ROOT"
    # Un worktree vinculado recibe (o completa) la capa enlazada.
    if [ "$AF_LOCAL" = 1 ] && [ "$ROOT" != "$MAIN_ROOT" ]; then link=1; fi
  else
    local wroot
    case "$AF_WORKTREE_ROOT" in
      /*) wroot="$AF_WORKTREE_ROOT" ;;
      *)  wroot="$(cd "$MAIN_ROOT/$AF_WORKTREE_ROOT" && pwd)" ;;
    esac
    wt="$wroot/$(basename "$MAIN_ROOT")-$slug"
    [ -e "$wt" ] && die "ya existe $wt"
    # Un worktree dentro del checkout principal tiene que quedar ignorado ahí,
    # o un `git add -A` lo registraría como repo anidado.
    case "$wt/" in
      "$MAIN_ROOT"/*)
        git -C "$MAIN_ROOT" check-ignore -q -- "${wt#"$MAIN_ROOT"/}" \
          || die "el worktree $wt quedaría dentro del repo sin estar ignorado; cambia AF_WORKTREE_ROOT o ignóralo"
        ;;
    esac
    if [ "$AF_LOCAL" = 1 ]; then link=1; fi
  fi

  # --- A partir de aquí se crea la rama: cualquier fallo deshace lo creado. ---
  if [ "$here" = 1 ]; then
    git -C "$ROOT" switch -q --no-track --no-overwrite-ignore -c "$branch" "$base_sha"
  else
    git -C "$ROOT" worktree add -q --no-track -b "$branch" "$wt" "$base_sha"
  fi
  local failed=""
  if [ "$link" = 1 ] && ! af_link_local_paths "$wt" "$MAIN_ROOT"; then
    failed="no se pudo enlazar la capa local en $wt"
  fi
  if [ -z "$failed" ] && [ "$AF_LOCAL" = 1 ]; then
    # El .gitignore de la base puede diferir del checkout principal: se comprueba en el worktree.
    leaks="$(af_local_not_ignored "$wt")"
    [ -z "$leaks" ] || failed="en $wt git no ignora: $(echo "$leaks" | tr '\n' ' ')(¿una negación en el .gitignore de $base?)"
  fi
  if [ -n "$failed" ]; then
    if [ "$here" = 1 ]; then
      af_unlink_created
      git -C "$ROOT" switch -q --no-overwrite-ignore "$prev" 2>/dev/null || git -C "$ROOT" switch -q --detach "$prev"
    else
      git -C "$ROOT" worktree remove --force "$wt"
    fi
    git -C "$ROOT" branch -q -D "$branch"
    die "$failed. Se deshizo la rama $branch$([ "$here" = 1 ] || echo " y su worktree")"
  fi

  # En modo local, la tarea vive siempre en la carpeta central del checkout principal.
  local tdir t="$MAIN_ROOT/.agentflow/templates"
  if [ "$AF_LOCAL" = 1 ]; then tdir="$MAIN_ROOT/$AF_TASKS_DIR/$slug"; else tdir="$wt/$AF_TASKS_DIR/$slug"; fi
  [ -d "$t" ] || t="$AF_HOME/templates"
  mkdir -p "$tdir"
  if [ "$AF_LOCAL" = 1 ]; then
    R_HANDOFF_POLICY="Actualízalo al cerrar cada bloque de trabajo. Es local: no se commitea ni se menciona en commits, ramas ni MRs."
  else
    R_HANDOFF_POLICY="Actualízalo al cerrar cada bloque de trabajo y commitéalo junto con el código."
  fi
  R_SLUG="$slug" R_AUTHOR="$author" R_REVIEWER="$reviewer" R_BRANCH="$branch" \
    R_BASE="$base" R_DATE="$(date +%F)"
  export R_SLUG R_AUTHOR R_REVIEWER R_BRANCH R_BASE R_DATE R_HANDOFF_POLICY
  af_render "$t/task/PLAN.md" "$tdir/PLAN.md"
  af_render "$t/task/HANDOFF.md" "$tdir/HANDOFF.md"
  cat > "$tdir/TASK" <<EOF
slug=$slug
author=$author
reviewer=$reviewer
branch=$branch
base=$base
base_sha=$base_sha
created=$(date +%F)
EOF

  info "tarea '$slug' creada"
  info "  rama:     $branch (desde $base, ${base_sha:0:9})"
  info "  worktree: $wt"
  info "  autor:    $author · revisor: $reviewer"
  if [ "$AF_LOCAL" = 1 ]; then info "  tarea:    $tdir (local, fuera de git)"; fi

  if [ "$here" = 0 ] && [ "$setup" = 1 ] && [ -n "$AF_WORKTREE_SETUP" ]; then
    info "preparando el worktree: $AF_WORKTREE_SETUP"
    ( cd "$wt" && bash -c "$AF_WORKTREE_SETUP" ) \
      || warn "la preparación del worktree falló; repítela a mano en $wt"
  fi

  echo
  echo "Siguiente:"
  printf '  cd %q && %s\n' "$wt" "$author"
  echo "  y pídele: \"lee AGENTS.md y $AF_TASKS_DIR/$slug/HANDOFF.md; escribe PLAN.md para <objetivo> y detente para que lo apruebe\""
}
