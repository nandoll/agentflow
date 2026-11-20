# shellcheck shell=bash
# af review [SLUG] [--reviewer claude|codex] [--force-same] [--ronda-extra]
# Revisión de SOLO LECTURA del diff rama..base por el agente que no es el autor.
# Quien escribe REVIEW.md es este script, nunca el revisor.

cmd_review() {
  af_load_config
  local slug="" reviewer="" force_same=0 extra=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --reviewer) reviewer="${2:?falta el valor de --reviewer}"; shift ;;
      --force-same) force_same=1 ;;
      --ronda-extra) extra=1 ;;
      -*) die "opción desconocida: $1" ;;
      *) slug="$1" ;;
    esac
    shift
  done
  [ -n "$slug" ] || slug="$(af_slug_from_branch)"
  [ -n "$slug" ] || die "indica la tarea: af review SLUG (o ejecútalo dentro de su worktree)"

  local taskf; taskf="$(af_find_task "$slug")"
  [ -n "$taskf" ] || die "no encuentro la tarea '$slug' (¿existe su TASK?)"
  local author base branch wt tdir
  author="$(af_task_get "$taskf" author)"
  base="$(af_task_get "$taskf" base)"
  branch="$(af_task_get "$taskf" branch)"
  [ -n "$reviewer" ] || reviewer="$(af_task_get "$taskf" reviewer)"
  [ -n "$reviewer" ] || reviewer="$(af_other "$author")"
  if [ "$reviewer" = "$author" ] && [ "$force_same" = 0 ]; then
    die "el revisor ($reviewer) es el autor de la tarea; usa --force-same solo si es intencional"
  fi

  wt="$(af_worktree_for_branch "$branch")"
  [ -n "$wt" ] || die "la rama $branch no está desprotegida en ningún worktree"
  cd "$wt"
  tdir="$AF_TASKS_DIR/$slug"

  local ahead; ahead="$(git rev-list --count "$base..HEAD")"
  [ "$ahead" -gt 0 ] || die "la rama $branch no tiene commits sobre $base; no hay nada que revisar"
  if [ -n "$(git status --porcelain -- . ":(exclude)$tdir")" ]; then
    warn "hay cambios sin commitear: la revisión solo cubre lo commiteado en $base..HEAD"
  fi

  local review="$tdir/REVIEW.md" round=1 head prompt out
  [ -f "$review" ] && round=$(( $(grep -c '^## Ronda ' "$review" || true) + 1 ))
  if [ "$round" -gt "$AF_REVIEW_MAX_RONDAS" ] && [ "$extra" = 0 ]; then
    die "ya hubo $((round - 1)) rondas (máximo AF_REVIEW_MAX_RONDAS=$AF_REVIEW_MAX_RONDAS). Los P0/P1 pendientes los decide el usuario; si pide otra ronda: af review --ronda-extra"
  fi
  local previas=""
  [ "$round" -gt 1 ] && previas="
Esta es la ronda $round. Lee $tdir/REVIEW.md: tiene las rondas anteriores y la **Respuesta:** del autor a cada hallazgo.
- No repitas ni reabras hallazgos ya respondidos. Solo si una respuesta es incorrecta o el arreglo quedó incompleto, abre una sección '### [Px] Reabierto: título' que diga qué respuesta y por qué falla.
- Concéntrate en el código nuevo desde la ronda anterior y en lo que esos cambios pudieron romper.
"
  head="$(git rev-parse --short HEAD)"
  out="$(mktemp)"

  prompt="Eres el REVISOR de la tarea '$slug' (autor: $author). Trabajas en solo lectura: no modifiques archivos.
Revisa el diff de la rama $branch contra $base ($ahead commits): obténlo con 'git diff $base...HEAD' y 'git log --oneline $base..HEAD', y abre los archivos completos cuando haga falta contexto.
Lee primero AGENTS.md (reglas del proyecto) y $tdir/PLAN.md (criterios de aceptación).
Prioriza: errores de corrección, seguridad, casos borde, incumplimientos de AGENTS.md y criterios de aceptación no cumplidos.
${previas}${AF_REVIEW_FOCUS:+Foco específico del proyecto: $AF_REVIEW_FOCUS
}Formato de salida en Markdown y en español:
- Un hallazgo por sección '### [P0|P1|P2|P3] título corto', con: archivo:línea, escenario concreto que falla, sugerencia.
- La severidad combina impacto y PROBABILIDAD en la operación real del proyecto (datos, entorno y uso descritos en AGENTS.md y PLAN.md):
  P0 = pérdida o corrupción de datos, o fuga de datos sensibles, alcanzable en operación normal.
  P1 = fallo que ocurrirá con datos o uso reales plausibles, o incumplimiento de un criterio de PLAN.md o de una regla de AGENTS.md.
  P2 = solo ocurre con un entorno manipulado, una configuración inusual o una coincidencia improbable; o riesgo o deuda relevante.
  P3 = menor o de estilo.
  En cada P0 y P1, agrega una línea 'Plausibilidad:' que explique por qué ocurriría en la operación real. Si no puedes justificarla, es P2.
- Al final, '### Veredicto': 'aprobable', 'aprobable con cambios' o 'no aprobable', y qué criterios de PLAN.md quedan sin cumplir.
Cita los archivos con rutas relativas a la raíz del repo (el worktree se borra al cerrar la tarea).
No repitas el diff ni elogies; si no hay hallazgos, dilo."

  info "ronda $round: $reviewer revisa $branch vs $base ($ahead commits) en $wt"
  case "$reviewer" in
    codex)
      command -v codex >/dev/null || die "codex no está instalado"
      # Solo lectura explícita: no depende de la configuración global del usuario.
      # (`codex exec review --base` no admite instrucciones propias, por eso se usa exec.)
      # shellcheck disable=SC2086
      codex exec -s read-only -c 'approval_policy="never"' \
        --ephemeral $AF_CODEX_REVIEW_ARGS -o "$out" "$prompt" </dev/null >"$out.log" 2>&1 \
        || { cat "$out.log" >&2; die "codex review falló (log completo arriba)"; }
      ;;
    claude)
      command -v claude >/dev/null || die "claude no está instalado"
      claude -p "$prompt" \
        --allowedTools 'Read,Grep,Glob,Bash(git diff:*),Bash(git log:*),Bash(git show:*)' \
        --disallowedTools 'Edit,Write,NotebookEdit' >"$out" 2>"$out.log" \
        || { cat "$out.log" >&2; die "claude -p falló (log completo arriba)"; }
      ;;
    *) die "revisor desconocido: $reviewer" ;;
  esac
  [ -s "$out" ] || { cat "$out.log" >&2; die "el revisor no devolvió texto"; }

  [ -f "$review" ] || cat > "$review" <<EOF
# REVIEW: $slug

Cada ronda la genera \`af review\` (el revisor trabaja en solo lectura).
El autor responde debajo de cada hallazgo con **Respuesta:** \`Aplicado en <sha>\` o \`Descartado: <motivo>\`.
EOF
  {
    printf '\n## Ronda %s · %s · revisor: %s · `%s..%s`\n\n' "$round" "$(date '+%F %H:%M')" "$reviewer" "$base" "$head"
    cat "$out"
    printf '\n'
  } >> "$review"
  rm -f "$out" "$out.log"
  info "hallazgos en $wt/$review (ronda $round)"
  info "siguiente: el autor ($author) responde cada hallazgo y aplica lo que corresponda"
}
