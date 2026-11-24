# agentflow

Flujo de trabajo para que **Claude Code y Codex colaboren en un mismo repositorio** sin pisarse. Funciona igual desde la CLI o desde las apps de escritorio, porque todo pasa por archivos y por git, no por el chat.

## Capas

| Capa | Dónde vive | Quién la mantiene | Ejemplo |
|---|---|---|---|
| 0. Máquina | `~/.codex/config.toml`, `~/.claude/settings.json` | Tú, una vez por máquina | Modelo, autenticación, proyectos *trusted* |
| 1. **Flujo** (este kit) | `~/Source/agentflow`, copiado en `.agentflow/` de cada repo | Este repositorio | Protocolo, roles, scripts `af`, plantillas |
| 2. Proyecto | `AGENTS.md` (fuera del bloque gestionado), `CLAUDE.md`, `.agentflow/config`, `.codex/config.toml`, `.claude/settings.json` | Cada proyecto | Stack, comandos, datos sensibles, foco de revisión |
| 3. Tarea | `docs/agents/tasks/<slug>/` en la rama de la tarea | Los agentes | `PLAN.md`, `HANDOFF.md`, `REVIEW.md` |

La capa 1 es lo único que se reutiliza tal cual. Al actualizar el kit, `af install` reemplaza `.agentflow/` y el bloque `<!-- agentflow:begin -->` de `AGENTS.md`, sin tocar lo que es del proyecto.

## Instalar en un proyecto

```bash
~/Source/agentflow/bin/agentflow install /ruta/al/repo
cd /ruta/al/repo
.agentflow/bin/af doctor
```

Después completa las secciones `AF:COMPLETAR` de `AGENTS.md` y define `AF_CHECK_CMD` en `.agentflow/config`.

La copia en `.agentflow/` se commitea. Así el repo es autosuficiente: las Routines en la nube, la CI o Codex Cloud la encuentran sin depender de tu máquina.

## Modo local (repos de equipo)

Cuando el repositorio es de un equipo y solo deben llegar los cambios, instala con `--local`:

```bash
~/Source/agentflow/bin/agentflow install /ruta/al/repo --local
```

- `.agentflow/`, `AGENTS.md`, `CLAUDE.md`, `.claude/settings.local.json` y la carpeta de tareas se excluyen en `.git/info/exclude`, que comparten todos los worktrees. Si alguna de esas rutas ya está versionada, `install` se niega.
- `af new-task` enlaza esas rutas desde el checkout principal en cada worktree. Las tareas viven en un solo lugar y sobreviven a `af clean`, que solo borra los enlaces.
- `HANDOFF.md` no se commitea: `af handoff-check` compara su fecha de modificación con la de los archivos que cambió la tarea.
- Los ajustes de Claude van en `.claude/settings.local.json`, con la atribución de commits y PRs desactivada. No se crea `.codex/config.toml`, porque Codex solo revisa y `af review` lo fuerza a solo lectura.

Opciones útiles en `.agentflow/config` para repos de equipo:

| Variable | Para qué | Ejemplo |
|---|---|---|
| `AF_BRANCH_TEMPLATE` / `AF_BRANCH_TYPE` | Ramas con la convención del equipo, sin prefijo de agente | `"{type}/{slug}"` / `feature` |
| `AF_BASE` / `AF_FETCH_BASE` | Ramificar desde una base remota actualizada | `origin/main` / `1` |
| `AF_WORKTREE_SETUP` | Preparar cada worktree nuevo | `"pnpm install --frozen-lockfile --prefer-offline"` |
| `AF_CLEAN_TARGETS` | Ramas donde `af clean` busca la tarea integrada (detecta squash) | `"origin/develop origin/uat"` |

## Ciclo de una tarea

```bash
af new-task importar-padron            # rama feat/importar-padron + worktree ../repo-importar-padron
cd ../repo-importar-padron && claude    # PLAN.md → aprobación → implementación → HANDOFF.md
af review                               # Codex en solo lectura → REVIEW.md
# Claude responde y corrige cada hallazgo; se repite hasta que no queden P0 ni P1
af clean importar-padron                # después de que integres la rama
```

Para trabajo mecánico largo, Codex es el autor y Claude revisa: `af new-task migrar-tests --author codex`.

Con plantilla de ramas: `af new-task SD2-123-login --type fix` crea `fix/SD2-123-login`.

## Pruebas del kit

`tests/smoke.sh` recorre los dos modos en repos temporales con un revisor simulado (no llama a ningún modelo).

## Garantías

- **El revisor no escribe.** `af review` llama a `codex exec review` con `sandbox_mode="read-only"` (o a `claude -p` sin herramientas de edición), y el script escribe `REVIEW.md`. Esto vale aunque tu configuración global de Codex sea permisiva.
- **El revisor no es el autor.** `af review` lo rechaza salvo que pases `--force-same`.
- **HANDOFF no se queda atrás.** `af handoff-check` falla si hay código más nuevo que `HANDOFF.md`, y en Claude Code un hook `Stop` lo exige antes de terminar el turno.
- **Nada de LLM en hooks de git.** Los hooks solo hacen cosas deterministas. La revisión se lanza a mano.
