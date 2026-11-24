# shellcheck shell=bash
# Funciones compartidas por todos los comandos de agentflow.
# Nota: todo corre con `set -euo pipefail`. Evita `| head` sobre salidas que
# pueden ser grandes: si el lector termina antes, el escritor muere por SIGPIPE
# y pipefail convierte eso en un error. Usa awk, que drena la entrada.

AF_VERSION="$(tr -d '[:space:]' < "$AF_HOME/VERSION")"

# Archivos de la metodología que, en modo local, nunca entran al repositorio.
# La carpeta de tareas (AF_TASKS_DIR) se agrega siempre a esta lista.
AF_LOCAL_PATHS_DEFAULT=".agentflow AGENTS.md CLAUDE.md .claude/settings.local.json"

die()  { printf 'af: error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'af: aviso: %s\n' "$*" >&2; }
info() { printf 'af: %s\n' "$*"; }

af_help() {
  cat <<EOF
agentflow $AF_VERSION: flujo Claude Code + Codex por archivos y git.

Uso: af <comando> [opciones]

  install [DIR] [--local]     Instala o actualiza el flujo en el repo DIR (por defecto, el actual).
                              Con --local, nada de la metodología entra al repositorio
  new-task SLUG [--author claude|codex] [--type TIPO] [--base RAMA] [--here] [--no-setup]
                              Crea rama, worktree y carpeta de la tarea (PLAN, HANDOFF, TASK)
  review [SLUG] [--reviewer claude|codex] [--ronda-extra]
                              Revisión de solo lectura por el agente que NO es el autor -> REVIEW.md
                              (máximo AF_REVIEW_MAX_RONDAS rondas; después decide el usuario)
  handoff-check [SLUG] [--hook]
                              Falla si HANDOFF.md no refleja los últimos cambios de la tarea
  status                      Lista las tareas abiertas en todos los worktrees
  check                       Ejecuta la verificación del proyecto (AF_CHECK_CMD)
  clean SLUG [--force]        Quita el worktree de una tarea ya integrada
  doctor                      Diagnostica herramientas, configuración y riesgos de permisos
  version                     Muestra la versión

Configuración del proyecto: .agentflow/config
EOF
}

af_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || die "no estás dentro de un repositorio git"
}

# Checkout principal del repositorio (el primero de `git worktree list`).
af_main_root() {
  git worktree list --porcelain | awk '/^worktree / && !d { print substr($0, 10); d = 1 }'
}

# Carga la configuración del proyecto con valores por defecto. Define ROOT y MAIN_ROOT.
af_load_config() {
  ROOT="$(af_repo_root)"
  MAIN_ROOT="$(af_main_root)"
  AF_BASE=main
  AF_TASKS_DIR=docs/agents/tasks
  AF_WORKTREE_ROOT=..
  AF_CHECK_CMD=""
  AF_REVIEW_FOCUS=""
  AF_DEFAULT_AUTHOR=claude
  AF_CODEX_REVIEW_ARGS=""
  AF_REVIEW_MAX_RONDAS=3
  AF_LOCAL=0
  AF_LOCAL_PATHS="$AF_LOCAL_PATHS_DEFAULT"
  AF_BRANCH_TEMPLATE=""
  AF_BRANCH_TYPE=feature
  AF_FETCH_BASE=0
  AF_WORKTREE_SETUP=""
  AF_CLEAN_TARGETS=""
  AF_CLEAN_DISPOSABLE=""
  # Un worktree sin capa enlazada usa la configuración del checkout principal
  # (la configuración es del repositorio, no de cada worktree).
  if [ -f "$ROOT/.agentflow/config" ]; then
    # shellcheck disable=SC1091
    . "$ROOT/.agentflow/config"
  elif [ -f "$MAIN_ROOT/.agentflow/config" ]; then
    # shellcheck disable=SC1091
    . "$MAIN_ROOT/.agentflow/config"
  fi
  AF_TASKS_DIR="${AF_TASKS_DIR%/}"
}

af_other() {
  case "$1" in
    claude) echo codex ;;
    codex)  echo claude ;;
    *) die "agente desconocido: $1 (usa claude o codex)" ;;
  esac
}

# af_branch_for AUTOR SLUG [TIPO]
# Con AF_BRANCH_TEMPLATE (p. ej. "{type}/{slug}") la rama no depende del autor.
# Sin plantilla se conserva el esquema clásico: feat/<slug> o codex/<slug>.
af_branch_for() {
  local author="$1" slug="$2" type="${3:-$AF_BRANCH_TYPE}" b
  if [ -n "${AF_BRANCH_TEMPLATE:-}" ]; then
    b="${AF_BRANCH_TEMPLATE//\{slug\}/$slug}"
    b="${b//\{type\}/$type}"
    echo "$b"; return
  fi
  case "$author" in
    claude) echo "feat/$slug" ;;
    codex)  echo "codex/$slug" ;;
    *) die "agente desconocido: $author" ;;
  esac
}

af_current_branch() { git rev-parse --abbrev-ref HEAD 2>/dev/null || true; }

# af_task_get ARCHIVO_TASK CLAVE
af_task_get() { awk -v k="$2=" 'index($0, k) == 1 && !d { print substr($0, length(k) + 1); d = 1 }' "$1"; }

# Ref usable para la base de una tarea: la rama base si aún existe, si no el
# SHA registrado al crearla (las tareas anteriores a v0.3.0 no lo tienen).
af_task_base_ref() {
  local taskf="$1" base sha
  base="$(af_task_get "$taskf" base)"
  sha="$(af_task_get "$taskf" base_sha)"
  if git rev-parse --verify --quiet "$base^{commit}" >/dev/null; then echo "$base"
  elif [ -n "$sha" ] && git rev-parse --verify --quiet "$sha^{commit}" >/dev/null; then echo "$sha"
  else die "la base '$base' de la tarea ya no existe${sha:+ y tampoco su SHA $sha}"
  fi
}

# Slug de la tarea de la rama actual: se busca el TASK cuya rama coincide; si no
# hay, se cae al esquema clásico feat/* o codex/*. Requiere af_load_config.
af_slug_from_branch() {
  local b f
  b="$(af_current_branch)"
  [ -n "$b" ] && [ "$b" != HEAD ] || { echo ""; return; }
  for f in "$ROOT/$AF_TASKS_DIR"/*/TASK; do
    [ -f "$f" ] || continue
    if [ "$(af_task_get "$f" branch)" = "$b" ]; then
      af_task_get "$f" slug; return
    fi
  done
  case "$b" in
    feat/*|codex/*) echo "${b#*/}" ;;
    *) echo "" ;;
  esac
}

# Ruta del worktree donde está desprotegida una rama (vacío si no hay).
af_worktree_for_branch() {
  git worktree list --porcelain | awk -v b="refs/heads/$1" '
    /^worktree /{ w = substr($0, 10) }
    $0 == "branch " b { print w }'
}

# Busca el archivo TASK de una tarea. Candidatos: los worktrees que tienen
# desprotegida la rama que ese mismo TASK declara (descarta copias históricas
# de tareas ya integradas). Gana el del worktree actual; si hay varios y
# ninguno es el actual, es ambiguo. Sin candidatos, la carpeta central (modo
# local) o la del repo actual.
af_find_task() {
  local slug="$1" w b f found="" n=0
  while IFS=$'\t' read -r w b; do
    f="$w/$AF_TASKS_DIR/$slug/TASK"
    if [ -f "$f" ] && [ "refs/heads/$(af_task_get "$f" branch)" = "$b" ]; then
      if [ "$w" = "$ROOT" ]; then echo "$f"; return; fi
      found="$f"; n=$((n + 1))
    fi
  done < <(git worktree list --porcelain | awk '/^worktree /{ w = substr($0, 10) } /^branch /{ print w "\t" substr($0, 8) }')
  [ "$n" -le 1 ] || die "la tarea '$slug' está activa en $n worktrees; ejecuta el comando desde el de la tarea"
  if [ -n "$found" ]; then echo "$found"; return; fi
  for f in "$MAIN_ROOT/$AF_TASKS_DIR/$slug/TASK" "$ROOT/$AF_TASKS_DIR/$slug/TASK"; do
    if [ -f "$f" ]; then echo "$f"; return; fi
  done
  echo ""
}

# Rutas locales (modo local), una por línea: AF_LOCAL_PATHS + AF_TASKS_DIR.
af_local_paths() {
  local -a ps; local p
  read -r -a ps <<< "$AF_LOCAL_PATHS"
  for p in "${ps[@]}"; do echo "${p%/}"; done
  echo "$AF_TASKS_DIR"
}

# Rutas locales que git NO ignora en DIR (una por línea; vacío = todo bien).
af_local_not_ignored() {
  local dir="$1" p
  while IFS= read -r p; do
    git -C "$dir" check-ignore -q -- "$p" || echo "$p"
  done < <(af_local_paths)
}

# Enlaza en el worktree WT las rutas locales del checkout principal MAIN.
# Reutiliza los enlaces que ya apuntan bien y registra en AF_CREATED_LINKS los
# que crea esta invocación, para que el llamador pueda retirarlos si algo falla.
# Así cada worktree ve reglas, kit y tareas sin versionarlos, y borrar el
# worktree solo quita los enlaces. Devuelve 1 (con aviso) si no puede.
AF_CREATED_LINKS=()
af_link_local_paths() {
  local wt="$1" main="$2" p src dst
  while IFS= read -r p; do
    src="$main/$p"; dst="$wt/$p"
    [ -e "$src" ] || { warn "no existe $p en el checkout principal (af install --local)"; return 1; }
    if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then continue; fi
    if [ -e "$dst" ] || [ -L "$dst" ]; then
      warn "$p ya existe en $wt y no es un enlace a $src; muévelo y reintenta"; return 1
    fi
    mkdir -p "$(dirname "$dst")"
    ln -s "$src" "$dst"
    AF_CREATED_LINKS+=("$dst")
  done < <(af_local_paths)
}

# Retira los enlaces creados por af_link_local_paths en esta invocación.
af_unlink_created() {
  local l
  for l in "${AF_CREATED_LINKS[@]}"; do
    if [ -L "$l" ]; then rm -f "$l"; fi
  done
  AF_CREATED_LINKS=()
}

# 0 si la ruta local P del worktree WT es un enlace a su original en MAIN_ROOT.
af_is_local_link() { [ -L "$1/$2" ] && [ "$(readlink "$1/$2")" = "$MAIN_ROOT/$2" ]; }

# Fecha de modificación con fracción de segundo; 0 si no existe.
af_mtime() {
  LC_ALL=C stat -c %.9Y "$1" 2>/dev/null || LC_ALL=C stat -f %Fm "$1" 2>/dev/null || echo 0
}

# Fecha de una ruta cambiada: la del archivo, o la del directorio existente más
# cercano si fue borrada o renombrada (borrar o mover cambia la fecha del directorio).
af_path_mtime() {
  local f="$1"
  while [ ! -e "$f" ] && [ ! -L "$f" ] && [ "$f" != . ] && [ "$f" != / ]; do f="$(dirname "$f")"; done
  af_mtime "$f"
}

# 0 si la fecha A es posterior a B (compara con decimales).
af_newer() { LC_ALL=C awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 > b + 0) }'; }

# af_task_changed_files BASE SALIDA [PATHSPEC...]
# Escribe en SALIDA, separados por NUL, los archivos que la tarea cambió respecto
# a BASE: commiteados desde el merge-base (borrados y ambos lados de un renombre
# incluidos) y los que tienen cambios sin commitear. Falla si git falla.
af_task_changed_files() {
  local base="$1" out="$2" e skip=0 tmp; shift 2
  git diff --name-only --no-renames -z "$base...HEAD" -- "$@" > "$out" || return 1
  tmp="$(mktemp)"
  git status --porcelain -z --untracked-files=all -- "$@" > "$tmp" || { rm -f "$tmp"; return 1; }
  while IFS= read -r -d '' e; do
    if [ "$skip" = 1 ]; then skip=0; printf '%s\0' "$e" >> "$out"; continue; fi   # origen de un renombre
    case "${e:0:1}" in R|C) skip=1 ;; esac
    printf '%s\0' "${e:3}" >> "$out"
  done < "$tmp"
  rm -f "$tmp"
}

# Actualiza una ref remota (p. ej. origin/develop) si AF_FETCH_BASE=1. Nunca falla.
af_fetch_ref() {
  local r="$1"
  [ "$AF_FETCH_BASE" = 1 ] && [[ $r == */* ]] || return 0
  git remote | awk -v r="${r%%/*}" '$0 == r { f = 1 } END { exit !f }' || return 0
  git fetch -q "${r%%/*}" "+refs/heads/${r#*/}:refs/remotes/$r" 2>/dev/null \
    || warn "no se pudo actualizar $r (¿sin red o sin VPN?); se usa la copia local"
}

# 0 si el contenido de RAMA ya está en DESTINO: por ascendencia o, para merges
# con squash, porque fusionar RAMA en DESTINO no cambiaría el árbol de DESTINO.
# Si DESTINO volvió a tocar esas líneas después del squash, no se detecta.
af_contains() {
  local branch="$1" target="$2" t
  git rev-parse --verify --quiet "$target^{commit}" >/dev/null || return 1
  git merge-base --is-ancestor "$branch" "$target" && return 0
  t="$(git merge-tree --write-tree "$target" "$branch" 2>/dev/null | awk 'NR == 1')" || return 1
  [ -n "$t" ] && [ "$t" = "$(git rev-parse "$target^{tree}")" ]
}

# Archivos ignorados del worktree WT que NO son enlaces locales verificados ni salidas
# regenerables (AF_CLEAN_DISPOSABLE). `git worktree remove` los borraría sin avisar.
af_user_artifacts() {
  local wt="$1" e p g ok lp locals
  local -a globs
  read -r -a globs <<< "$AF_CLEAN_DISPOSABLE"
  locals="$(af_local_paths)"
  while IFS= read -r -d '' e; do
    p="${e%/}"
    # Un directorio listado que no está ignorado es solo contenedor de lo ignorado.
    if [ "$e" != "$p" ] && ! git -C "$wt" check-ignore -q -- "$p"; then continue; fi
    ok=0
    if [ "$AF_LOCAL" = 1 ]; then
      while IFS= read -r lp; do
        if [ "$p" = "$lp" ] && af_is_local_link "$wt" "$p"; then ok=1; fi
      done <<< "$locals"
    fi
    for g in "${globs[@]}"; do
      # shellcheck disable=SC2053
      if [[ $p == $g || $p == $g/* ]]; then ok=1; fi
    done
    [ "$ok" = 1 ] || echo "$p"
  done < <(git -C "$wt" ls-files -z --others --ignored --exclude-standard --directory)
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
      -e "s|{{HANDOFF_POLICY}}|${R_HANDOFF_POLICY:-}|g" \
      "$1" > "$2"
}
