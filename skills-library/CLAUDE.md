# CLAUDE.md

This project's conventions for AI coding agents live in [AGENT.md](AGENT.md), imported below so they apply whether you open the repo root or `skills-library/` as your workspace.

@AGENT.md

## Quick reminders

- **Read `.claude/skills/config.md` first** for CLI paths, build context, platform/DB/LLM/email credentials. It is the single source of truth; never hardcode these. `config.md` is gitignored — `config.example.md` is the template.
- **New Flogo apps go in the `FLOGO_APPS_DIR` folder** (default `../../Flogo_Apps` relative to `config.md` → `skills-library/Flogo_Apps/`) — never at the `skills-library/` root or the repo root.
- The task-specific recipes are the skills under `.claude/skills/` — they load automatically when relevant.
