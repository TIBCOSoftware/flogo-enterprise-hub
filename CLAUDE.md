# CLAUDE.md

**flogo-enterprise-hub** collects TIBCO Flogo enterprise assets: reusable AI-agent **skills** under [`skills-library/.claude/skills/`](skills-library/.claude/skills/), runnable **demos** under [`samples/`](samples/), and custom **connector extensions** under `extensions/`.

The project-level conventions for building, testing, and deploying Flogo apps live in [`skills-library/AGENT.md`](skills-library/AGENT.md), imported below so they apply from the repo root exactly as they do when you open `skills-library/` as your workspace.

@skills-library/AGENT.md

## Quick reminders

- **Read `skills-library/.claude/skills/config.md` first** for CLI paths, build context, and platform/DB/LLM/email credentials — the single source of truth; never hardcode these. It is gitignored; `config.example.md` is the template.
- **New Flogo apps go in the `FLOGO_APPS_DIR` folder** (default `../../Flogo_Apps` relative to `config.md` → `skills-library/Flogo_Apps/`) — never at the repo root or the `skills-library/` root.
- **Never create a `.claude/` folder at the repo root.** The skills live at `skills-library/.claude/skills/`; keep them there.
- The task-specific recipes are the skills under `skills-library/.claude/skills/` — they load automatically when you work on files under `skills-library/`.
