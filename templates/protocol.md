<!-- agentflow:begin v{{VERSION}} · bloque gestionado: no lo edites a mano, se reemplaza con `af install` -->
## Flujo de trabajo entre agentes (agentflow v{{VERSION}})

Este bloque es igual en todos los proyectos que usan agentflow. Las reglas propias del proyecto están arriba y **tienen prioridad** si hay conflicto.

### Principios

1. **Una sola fuente de reglas:** este `AGENTS.md`. `CLAUDE.md` solo lo importa y agrega notas exclusivas de Claude.
@@tracked 2. **El contexto viaja por archivos y git, nunca por el chat.** Lo que el otro agente necesita saber va en los archivos de la tarea.
@@local 2. **El contexto viaja por archivos, nunca por el chat.** Lo que el otro agente necesita saber va en los archivos de la tarea.
3. **Quien revisa nunca es quien escribió.** El autor de una tarea no revisa su propio código.
4. **Los roles no cambian dentro de una tarea.** Si hace falta cambiarlos, se cierra la tarea y se abre otra.
5. **Un solo agente escribe en cada worktree.** El revisor trabaja en solo lectura.
@@local 6. **Capa local: la metodología no entra al repositorio.** `AGENTS.md`, `CLAUDE.md`, `.agentflow/` y la carpeta de tareas están excluidos de git, y cada worktree los ve por enlaces al checkout principal. Al repositorio solo llegan los cambios: ningún commit, rama ni MR menciona agentes, tareas, planes, revisiones ni este flujo, y no se agregan trailers de coautoría.

### Roles por defecto

| Fase | Responsable | Salida |
|---|---|---|
| Plan | Autor (Claude por defecto) | `PLAN.md` con criterios de aceptación verificables. **Se detiene hasta que el usuario lo apruebe** |
| Implementación | Autor | Commits pequeños en la rama de la tarea, con `af check` en verde |
| Revisión | El otro agente, en solo lectura | `REVIEW.md` (lo escribe `af review`, no el revisor) |
| Correcciones | Autor | Respuesta a cada hallazgo: `Aplicado en <sha>` o `Descartado: <motivo>` |
| Tareas mecánicas largas (tests, migraciones, refactors) | Codex como autor (`af new-task --author codex`) | Las revisa Claude |
| Merge, push y PR | **El usuario** (o un agente con su pedido explícito) | |

### Archivos de una tarea (`{{TASKS_DIR}}/<slug>/`)

- `TASK`: metadatos (autor, revisor, rama, base). Lo crea `af new-task`; no se edita.
- `PLAN.md`: objetivo, pasos, criterios de aceptación y lo que queda fuera de alcance.
- `HANDOFF.md`: estado, qué se hizo, siguiente paso, decisiones y cómo verificar. **Es lo primero que lee cualquier agente que retome la tarea.**
- `REVIEW.md`: rondas de revisión y respuestas del autor.
@@local
@@local Son locales: viven en el checkout principal, sobreviven a `af clean` y nunca se commitean.

### Ciclo de una tarea

@@tracked 1. `af new-task <slug> [--author codex]`: crea la rama de la tarea, su worktree hermano y la carpeta de la tarea.
@@local 1. `af new-task <slug> [--type <tipo>] [--author codex]`: crea la rama de la tarea desde la base, su worktree hermano con los enlaces locales y la carpeta de la tarea.
2. El autor lee `AGENTS.md` y `HANDOFF.md`, escribe `PLAN.md` y **se detiene** para que el usuario lo apruebe.
3. El autor implementa en commits pequeños. Antes de cada commit, `af check` debe pasar.
@@tracked 4. Al cerrar cada bloque de trabajo, el autor actualiza `HANDOFF.md` y lo commitea **junto con** el código. `af handoff-check` debe pasar.
@@local 4. Al cerrar cada bloque de trabajo, el autor actualiza `HANDOFF.md` (sin commitearlo). `af handoff-check` debe pasar.
5. `af review` genera una ronda en `REVIEW.md` con el otro agente en solo lectura.
6. El autor responde cada hallazgo y aplica lo que corresponda. Se repiten 5 y 6 hasta que no queden P0 ni P1, con un máximo de `AF_REVIEW_MAX_RONDAS` rondas (3 por defecto). Si al llegar al máximo quedan P0 o P1, **los decide el usuario**: aceptar el riesgo, corregir o pedir otra ronda con `af review --ronda-extra`.
7. El usuario integra la rama. `af clean <slug>` quita el worktree.

### Severidad de los hallazgos

La severidad combina impacto y **probabilidad en la operación real** del proyecto:

| Nivel | Criterio |
|---|---|
| P0 | Pérdida o corrupción de datos, o fuga de datos sensibles, alcanzable en operación normal |
| P1 | Fallo que ocurrirá con datos o uso reales plausibles, o incumplimiento de un criterio de `PLAN.md` o de una regla de este archivo |
| P2 | Solo ocurre con un entorno manipulado, una configuración inusual o una coincidencia improbable; o riesgo o deuda relevante |
| P3 | Menor o de estilo |

Cada P0 y P1 justifica su plausibilidad. Un hallazgo ya respondido no se reabre, salvo que la respuesta sea incorrecta.

### Reglas para cualquier agente

- **Al empezar**, lee el `HANDOFF.md` de la tarea antes de tocar nada.
- Trabaja **solo** dentro del worktree de tu tarea y no modifiques carpetas de otras tareas.
- No hagas `push`, `merge`, `rebase` de ramas compartidas, `reset --hard` ni borres ramas sin pedido explícito del usuario.
- **Como revisor**, no edites archivos: solo produces hallazgos.
- Commits con Conventional Commits (`tipo(alcance): resumen`), uno por cambio lógico.
@@local - Nunca agregues al índice de git las rutas de la capa local (no uses `git add -f` sobre ellas).
- No escribas secretos ni datos personales en los archivos de la tarea.
- Si algo del plan no se puede cumplir, anótalo en `HANDOFF.md` (sección *Bloqueos*) y detente. No amplíes el alcance por tu cuenta.
- Si una regla de este bloque choca con una del proyecto, manda la del proyecto.

### Comandos (`.agentflow/bin/af`)

| Comando | Para qué |
|---|---|
| `af new-task <slug> [--type <tipo>] [--author claude\|codex]` | Abrir una tarea |
| `af check` | Lint y tests del proyecto |
| `af handoff-check` | Comprobar que `HANDOFF.md` está al día |
| `af review [<slug>] [--ronda-extra]` | Revisión cruzada en solo lectura → `REVIEW.md` |
| `af status` | Tareas abiertas en todos los worktrees |
| `af clean <slug>` | Quitar el worktree de una tarea integrada |
| `af doctor` | Diagnóstico de herramientas y permisos |
<!-- agentflow:end -->
