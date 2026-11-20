@AGENTS.md

## Solo para Claude Code

- Las reglas compartidas están en `AGENTS.md` (importado arriba). No dupliques reglas aquí: si una regla aplica también a Codex, va en `AGENTS.md`.
- Para escribir `PLAN.md`, usa el modo plan y detente hasta que el usuario lo apruebe.
- Al terminar un bloque de trabajo, actualiza `HANDOFF.md`. El hook `Stop` (`af handoff-check --hook`) te lo pedirá si se te olvida.
- Para la revisión cruzada, ejecuta `.agentflow/bin/af review`: llama a Codex en solo lectura y deja los hallazgos en `REVIEW.md`. Luego responde cada hallazgo allí.
