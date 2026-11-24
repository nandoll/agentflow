# shellcheck shell=bash
# af handoff-check [SLUG] [--hook]
#
# La comprobación corre en el worktree donde está desprotegida la rama de la
# tarea, se invoque desde donde se invoque.
#
# Modo versionado: HANDOFF.md está al día si (a) tiene cambios sin commitear, o
# (b) su último commit es igual o posterior al último commit de código y no hay
# código sin commitear.
# Modo local (AF_LOCAL=1): HANDOFF.md no se versiona, así que se compara su fecha
# de modificación con la de los archivos que la tarea cambió (commiteados desde
# la base o sin commitear; para borrados y renombres, la del directorio).
# Commitear no cambia esas fechas, así que el orden natural (código, HANDOFF,
# commit) pasa. Límite conocido: un cambio solo del índice que no toca el
# archivo (p. ej. `git rm --cached`) no cambia ninguna fecha y no se detecta.
#
# Con --hook (hook Stop de Claude Code) sale con 2 para pedir que lo actualice,
# y respeta stop_hook_active para no entrar en bucle.

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
    # En el hook, cualquier fallo inesperado bloquea (salida 2) en vez de pasar
    # como error no bloqueante; stop_hook_active evita el bucle.
    trap 'rc=$?; if [ "$rc" != 0 ] && [ "$rc" != 2 ]; then printf "af: handoff-check falló (código %s); revísalo con: .agentflow/bin/af handoff-check\n" "$rc" >&2; exit 2; fi' EXIT
  fi

  af_load_config
  [ -n "$slug" ] || slug="$(af_slug_from_branch)"
  if [ -z "$slug" ]; then
    [ "$hook" = 1 ] || info "la rama actual no es de una tarea: nada que comprobar"
    return 0
  fi
  local taskf; taskf="$(af_find_task "$slug")"
  if [ -z "$taskf" ]; then
    [ "$hook" = 1 ] && return 0
    die "no encuentro la tarea '$slug'"
  fi
  local branch wt base tdir handoff
  branch="$(af_task_get "$taskf" branch)"
  wt="$(af_worktree_for_branch "$branch")"
  if [ -z "$wt" ]; then
    [ "$hook" = 1 ] && return 0
    die "la rama $branch de la tarea '$slug' no está desprotegida en ningún worktree"
  fi
  cd "$wt"
  base="$(af_task_base_ref "$taskf")"
  tdir="$AF_TASKS_DIR/$slug"
  if [ "$AF_LOCAL" = 1 ]; then handoff="$MAIN_ROOT/$tdir/HANDOFF.md"; else handoff="$tdir/HANDOFF.md"; fi

  local problem=""
  if [ "$AF_LOCAL" = 1 ]; then
    local f m newest=0 has_code=0 hm list
    list="$(mktemp)"
    af_task_changed_files "$base" "$list" . ":(exclude)$tdir" \
      || { rm -f "$list"; die "git falló al listar los cambios de la tarea contra $base"; }
    while IFS= read -r -d '' f; do
      has_code=1
      m="$(af_path_mtime "$f")"
      if af_newer "$m" "$newest"; then newest="$m"; fi
    done < "$list"
    rm -f "$list"
    if [ "$has_code" = 1 ]; then
      if [ ! -f "$handoff" ]; then
        problem="falta HANDOFF.md y la tarea ya tiene cambios"
      else
        hm="$(af_mtime "$handoff")"
        if af_newer "$newest" "$hm"; then
          problem="hay archivos de la tarea modificados después de la última edición de HANDOFF.md"
        elif grep -q 'AF:PENDIENTE' "$handoff"; then
          problem="HANDOFF.md aún tiene marcas AF:PENDIENTE"
        fi
      fi
    fi
  else
    local last_code last_handoff dirty_code dirty_handoff
    last_code="$(git log -1 --format=%ct "$base..HEAD" -- . ":(exclude)$tdir")"
    last_handoff="$(git log -1 --format=%ct "$base..HEAD" -- "$handoff")"
    dirty_code="$(git status --porcelain -- . ":(exclude)$tdir" | awk 'NR == 1')"
    dirty_handoff="$(git status --porcelain -- "$handoff" | awk 'NR == 1')"
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
  fi

  if [ -z "$problem" ]; then
    [ "$hook" = 1 ] || info "HANDOFF.md de '$slug' al día"
    return 0
  fi
  local how="y commitéalo con el código"
  if [ "$AF_LOCAL" = 1 ]; then how="(es local: no se commitea)"; fi
  local msg="HANDOFF.md de la tarea '$slug' está desactualizado: $problem. Actualiza $handoff (Estado, Hecho, Siguiente paso, Decisiones, Cómo verificar) $how antes de terminar."
  if [ "$hook" = 1 ]; then
    printf '%s\n' "$msg" >&2
    exit 2
  fi
  die "$msg"
}
