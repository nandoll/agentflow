#!/usr/bin/env bash
# Prueba de humo de agentflow: modo versionado y modo local en repos temporales.
# Usa un revisor simulado (codex/claude falsos en PATH): no llama a ningún modelo.
# Uso: tests/smoke.sh
set -euo pipefail

KIT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0
# t DESCRIPCIÓN CÓDIGO: evalúa CÓDIGO; si falla, muestra su salida y aborta.
t() {
  if eval "$2" >"$TMP/out" 2>&1; then pass=$((pass + 1)); printf '  ok  %s\n' "$1"
  else printf "  FALLA  %s\n" "$1" >&2; sed 's/^/        /' "$TMP/out" >&2; exit 1; fi
}
# Salida de un comando que debe fallar (sin que pipefail interfiera).
err_of() { "$@" 2>&1 || true; }
doctor_ok() { local o; o="$(.agentflow/bin/af doctor)" && ! grep -q FALTA <<< "$o"; }

# Revisor simulado: escribe un veredicto en el archivo de -o (codex) o en stdout (claude).
mkdir -p "$TMP/bin"
cat > "$TMP/bin/codex" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = -o ] && { out="$2"; shift; }; shift; done
printf '### [P3] detalle\nsin impacto\n\n### Veredicto\naprobable\n' > "$out"
STUB
printf '#!/usr/bin/env bash\nprintf "### Veredicto\\naprobable\\n"\n' > "$TMP/bin/claude"
chmod +x "$TMP/bin/codex" "$TMP/bin/claude"
export PATH="$TMP/bin:$PATH"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

new_repo() {
  git init -q -b main "$1"
  mkdir -p "$1/src"; echo base > "$1/app.txt"; echo uno > "$1/src/a.txt"; echo "/node_modules" > "$1/.gitignore"
  git -C "$1" add -A && git -C "$1" commit -q -m "chore: base"
}
set_cfg() { echo "$1" >> .agentflow/config; }
done_handoff() { sed -i.bak 's/AF:PENDIENTE/hecho/g' "$1" && rm -f "$1.bak"; }

echo "Modo versionado (esquema clásico)"
R="$TMP/clasico"; new_repo "$R"; cd "$R"
t "install" '"$KIT/bin/agentflow" install .'
set_cfg 'AF_CHECK_CMD="true"'
git add -A && git commit -q -m "chore: agentflow"
t "protocolo versionado sin marcas de modo" 'grep -q "^2\. \*\*El contexto viaja por archivos y git" AGENTS.md && ! grep -q "@@" AGENTS.md'
t "new-task" '.agentflow/bin/af new-task demo'
W="$TMP/clasico-demo"
t "rama feat/demo y TASK con base_sha" '[ "$(git -C "$W" rev-parse --abbrev-ref HEAD)" = feat/demo ] && grep -q "^base_sha=" "$W/docs/agents/tasks/demo/TASK"'
cd "$W"
echo cambio >> app.txt && git commit -qam "feat: cambio"
t "handoff-check falla sin HANDOFF commiteado" '! .agentflow/bin/af handoff-check'
done_handoff docs/agents/tasks/demo/HANDOFF.md; git add -A && git commit -q -m "docs: handoff"
t "handoff-check pasa con HANDOFF commiteado" '.agentflow/bin/af handoff-check'
t "review ronda 1 (codex simulado)" '.agentflow/bin/af review && grep -q "^## Ronda 1" docs/agents/tasks/demo/REVIEW.md'
git add -A && git commit -q -m "docs: review"
cd "$R" && git merge -q --no-ff feat/demo -m "merge demo"
t "clean tras merge" '.agentflow/bin/af clean demo && [ ! -d "$W" ]'

echo "Modo local (plantilla de ramas, base main, squash en otra rama)"
R="$TMP/equipo"; new_repo "$R"; cd "$R"
git branch develop
printf '/scripts/local.cjs\n' >> .git/info/exclude   # artefacto local del usuario
mkdir -p .codex   # carpeta preexistente sin config: no debe tocarse
t "install --local" '"$KIT/bin/agentflow" install . --local'
set_cfg 'AF_BRANCH_TEMPLATE="{type}/{slug}"'
set_cfg 'AF_CHECK_CMD="true"'
set_cfg 'AF_CLEAN_TARGETS="develop"'
set_cfg 'AF_CLEAN_DISPOSABLE="node_modules"'
set_cfg 'AF_WORKTREE_SETUP="mkdir -p node_modules && touch node_modules/.ok"'
t "git no ve nada de la metodología" '[ -z "$(git status --porcelain)" ]'
t "sin .codex/config.toml y con settings.local.json" '[ ! -e .codex/config.toml ] && [ -f .claude/settings.local.json ]'
t "protocolo local sin marcas de modo" 'grep -q "^6\. \*\*Capa local" AGENTS.md && ! grep -q "@@" AGENTS.md'
t "doctor sin FALTA" 'doctor_ok'
t "new-task SD2-7-login --type fix" '.agentflow/bin/af new-task SD2-7-login --type fix'
W="$TMP/equipo-SD2-7-login"; H="$R/docs/agents/tasks/SD2-7-login/HANDOFF.md"
t "rama fix/SD2-7-login sin prefijo de agente" '[ "$(git -C "$W" rev-parse --abbrev-ref HEAD)" = fix/SD2-7-login ]'
t "rama sin upstream" '[ -z "$(git -C "$W" config --get branch.fix/SD2-7-login.merge || true)" ]'
t "enlaces locales en el worktree" '[ -L "$W/AGENTS.md" ] && [ -L "$W/.agentflow" ] && [ -L "$W/CLAUDE.md" ] && [ -L "$W/.claude/settings.local.json" ] && [ -L "$W/docs/agents/tasks" ]'
t "tarea en la carpeta central" '[ -f "$H" ] && [ "$(readlink "$W/docs/agents/tasks")" = "$R/docs/agents/tasks" ]'
t "AF_WORKTREE_SETUP ejecutado" '[ -f "$W/node_modules/.ok" ]'
t "worktree limpio para git" '[ -z "$(git -C "$W" status --porcelain)" ]'
cd "$W"
t "doctor en el worktree sin FALTA" 'doctor_ok'
t "status lista la tarea" '.agentflow/bin/af status | grep -q "SD2-7-login.*fix/SD2-7-login"'
t "handoff-check pasa recién creada (sin código)" '.agentflow/bin/af handoff-check'
echo cambio >> app.txt
t "handoff-check falla con código y HANDOFF sin completar" '! .agentflow/bin/af handoff-check'
t "handoff-check SLUG desde el checkout principal mira el worktree de la tarea" '! (cd "$R" && .agentflow/bin/af handoff-check SD2-7-login)'
touch "$H"
t "handoff-check falla por AF:PENDIENTE aunque HANDOFF sea más nuevo" 'err_of .agentflow/bin/af handoff-check | grep -q PENDIENTE && ! .agentflow/bin/af handoff-check'
done_handoff "$H"
t "handoff-check pasa tras completar HANDOFF (sin esperar un segundo)" '.agentflow/bin/af handoff-check'
echo otro >> app.txt
t "handoff-check falla con código más nuevo que HANDOFF" 'err_of .agentflow/bin/af handoff-check | grep -q "modificados después" && ! .agentflow/bin/af handoff-check'
t "hook Stop bloquea con salida 2" 'echo "{}" | .agentflow/bin/af handoff-check --hook; [ $? = 2 ]'
t "hook respeta stop_hook_active" 'echo "{\"stop_hook_active\": true}" | .agentflow/bin/af handoff-check --hook'
touch "$H"
git commit -qam "fix(login): handle expired session"
t "commitear después del HANDOFF no lo desactualiza" '.agentflow/bin/af handoff-check'
git rm -q src/a.txt
t "un borrado posterior al HANDOFF lo desactualiza" '! .agentflow/bin/af handoff-check'
git reset -q --hard HEAD; touch "$H"
git mv src/a.txt src/b.txt
t "un renombre posterior al HANDOFF lo desactualiza" '! .agentflow/bin/af handoff-check'
git reset -q --hard HEAD; rm -f src/b.txt; touch "$H"
mv "$H" "$H.bak"
t "falta HANDOFF con cambios: falla explícito" 'err_of .agentflow/bin/af handoff-check | grep -q "falta HANDOFF"'
mv "$H.bak" "$H"; touch "$H"
t "los commits solo traen cambios" '[ "$(git log --name-only --format= main..HEAD | sort -u)" = app.txt ]'
t "review escribe REVIEW.md en la carpeta central, sin avisos" '! .agentflow/bin/af review 2>&1 | grep -q aviso && grep -q "^## Ronda 1" "$R/docs/agents/tasks/SD2-7-login/REVIEW.md"'
t "clean se niega si no está integrada" '! .agentflow/bin/af clean SD2-7-login && [ -d "$W" ]'
cd "$R"
git checkout -q develop && git merge -q --squash fix/SD2-7-login >/dev/null && git commit -q -m "fix(login): handle expired session" && git checkout -q main
mkdir -p "$W/scripts" && echo "x" > "$W/scripts/local.cjs"
t "clean se detiene ante artefactos ignorados del usuario" 'err_of .agentflow/bin/af clean SD2-7-login | grep -q "scripts/local.cjs" && [ -f "$W/scripts/local.cjs" ]'
mv "$W/scripts/local.cjs" "$TMP/local.cjs"
t "clean detecta el squash en develop (node_modules es desechable)" '.agentflow/bin/af clean SD2-7-login && [ ! -d "$W" ]'
t "clean no borra los originales enlazados" '[ -f "$R/docs/agents/tasks/SD2-7-login/REVIEW.md" ] && [ -f "$R/AGENTS.md" ] && [ -f "$R/CLAUDE.md" ] && [ -d "$R/.agentflow/lib" ] && [ -f "$R/.claude/settings.local.json" ]'
t "no reutiliza el slug de una tarea cerrada" '! .agentflow/bin/af new-task SD2-7-login --type fix'
t "reinstalar es idempotente" '.agentflow/bin/af install --local && [ "$(grep -c "^/AGENTS.md$" .git/info/exclude)" = 1 ] && [ -z "$(git status --porcelain)" ]'

echo "Modo local: base temporal que desaparece"
git branch tmp-base main
t "new-task desde una base temporal" '.agentflow/bin/af new-task SD2-8-tmp --base tmp-base --no-setup'
W="$TMP/equipo-SD2-8-tmp"
git branch -q -D tmp-base
echo z >> "$W/app.txt"
t "handoff-check usa el SHA registrado si la base ya no existe" 'err_of .agentflow/bin/af handoff-check SD2-8-tmp | grep -q "modificados después\|PENDIENTE"'
git -C "$W" checkout -q -- app.txt
t "clean --force quita el worktree sin artefactos" '.agentflow/bin/af clean SD2-8-tmp --force && [ ! -d "$W" ]'

echo "Modo local: protecciones"
t "install --local se niega desde un worktree" 'git worktree add -q "$TMP/wt-x" -b x main && ! (cd "$TMP/wt-x" && "$KIT/bin/agentflow" install . --local) && [ ! -e "$TMP/wt-x/.agentflow" ]'
git worktree remove "$TMP/wt-x"
git worktree add -q "$TMP/base-claude" -b base-claude main
( cd "$TMP/base-claude" && printf '@AGENTS.md\n' > CLAUDE.md && git add -f CLAUDE.md && git commit -q -m "docs: claude" )
git worktree remove "$TMP/base-claude"
t "new-task se niega si la base versiona una ruta local" 'err_of .agentflow/bin/af new-task SD2-9-x --base base-claude --no-setup | grep -q "versiona CLAUDE.md" && ! git rev-parse -q --verify refs/heads/feature/SD2-9-x'
set_cfg 'AF_WORKTREE_ROOT=.'
t "new-task se niega a anidar un worktree no ignorado" 'err_of .agentflow/bin/af new-task SD2-10-x --no-setup | grep -q "dentro del repo"'
set_cfg 'AF_WORKTREE_ROOT=..'

echo "Modo local: ronda 2"
cp .gitignore .gitignore.bak && printf '!/docs/agents/tasks\n' >> .gitignore
t "new-task se niega si el checkout principal dejó de ignorar las tareas, sin crear rama" 'err_of .agentflow/bin/af new-task SD2-12-x --no-setup | grep -q "no ignora" && ! git rev-parse -q --verify refs/heads/feature/SD2-12-x'
mv .gitignore.bak .gitignore
git worktree add -q "$TMP/neg-base" -b neg-base main
( cd "$TMP/neg-base" && printf '!/CLAUDE.md\n' >> .gitignore && git commit -qam "chore: gitignore" )
git worktree remove "$TMP/neg-base"
t "si la base no ignora una ruta local, deshace rama y worktree" 'err_of .agentflow/bin/af new-task SD2-13-x --base neg-base --no-setup | grep -q "Se deshizo" && ! git rev-parse -q --verify refs/heads/feature/SD2-13-x && [ ! -e "$TMP/equipo-SD2-13-x" ]'
git worktree add -q "$TMP/viejo" -b viejo main
t "--here en un worktree previo usa la config del principal y enlaza la capa" '(cd "$TMP/viejo" && "$R/.agentflow/bin/af" new-task SD2-14-here --here) && [ "$(git -C "$TMP/viejo" rev-parse --abbrev-ref HEAD)" = feature/SD2-14-here ] && [ -L "$TMP/viejo/.agentflow" ] && [ -f "$R/docs/agents/tasks/SD2-14-here/TASK" ]'
git worktree add -q "$TMP/choque" -b choque main
echo "mío" > "$TMP/choque/AGENTS.md"
t "--here con un AGENTS.md suelto falla y no deja enlaces a medias" '(cd "$TMP/choque" && err_of "$R/.agentflow/bin/af" new-task SD2-16-here --here) | grep -q "Se deshizo" && [ ! -L "$TMP/choque/.agentflow" ] && [ "$(cat "$TMP/choque/AGENTS.md")" = "mío" ] && [ "$(git -C "$TMP/choque" rev-parse --abbrev-ref HEAD)" = choque ]'
mv "$TMP/choque/AGENTS.md" "$TMP/AGENTS.respaldo"
t "el reintento completa todos los enlaces" '(cd "$TMP/choque" && "$R/.agentflow/bin/af" new-task SD2-16-here --here) && for p in .agentflow AGENTS.md CLAUDE.md .claude/settings.local.json docs/agents/tasks; do [ -L "$TMP/choque/$p" ] || exit 1; done'
.agentflow/bin/af new-task SD2-15-real --no-setup >/dev/null
W="$TMP/equipo-SD2-15-real"
rm "$W/docs/agents/tasks" && mkdir -p "$W/docs/agents/tasks/x" && echo nota > "$W/docs/agents/tasks/x/HANDOFF.md"
t "clean --force se detiene si la carpeta de tareas es un directorio real" 'err_of .agentflow/bin/af clean SD2-15-real --force | grep -q "docs/agents/tasks" && [ -f "$W/docs/agents/tasks/x/HANDOFF.md" ]'
rm -rf "$W/docs/agents/tasks" && ln -s "$R/docs/agents/tasks" "$W/docs/agents/tasks"
sed -i.bak '/^base_sha=/d' "$R/docs/agents/tasks/SD2-15-real/TASK" && rm -f "$R/docs/agents/tasks/SD2-15-real/TASK.bak"
sed -i.bak 's/^base=.*/base=rama-podada/' "$R/docs/agents/tasks/SD2-15-real/TASK" && rm -f "$R/docs/agents/tasks/SD2-15-real/TASK.bak"
t "el hook bloquea (salida 2) si la comprobación falla por un error" '(cd "$W" && echo "{}" | .agentflow/bin/af handoff-check --hook); [ $? = 2 ]'

echo "Modo local sobre rutas que no se pueden ocultar"
R="$TMP/versionado"; new_repo "$R"; cd "$R"
echo "@AGENTS.md" > CLAUDE.md && git add CLAUDE.md && git commit -q -m "docs: claude"
t "se niega si CLAUDE.md está versionado, sin dejar rastro" '! "$KIT/bin/agentflow" install . --local && [ ! -d .agentflow ]'
R="$TMP/negacion"; new_repo "$R"; cd "$R"
printf '!/CLAUDE.md\n' >> .gitignore && git commit -qam "chore: gitignore"
t "se niega si una negación de .gitignore anula la exclusión" 'err_of "$KIT/bin/agentflow" install . --local | grep -q "no queda ignorado" && [ ! -d .agentflow ]'

echo "$pass comprobaciones en verde"
