# Temporal Design Patterns — Solution Architect Toolkit

Research notes and a Claude skill for designing Temporal Workflow architectures, derived from the [temporal-sa/temporal-design-patterns](https://github.com/temporal-sa/temporal-design-patterns) catalog and the published Temporal Cloud limits.

| Path | What it is |
| :--- | :--- |
| [temporal-design-patterns.md](temporal-design-patterns.md) | Pattern selection guide for solution architects: decision rules, limits, combinations, review checklist |
| [doc-result.md](doc-result.md) | Evidence pack: sources, conflicts found in the catalog, open questions |
| [skills/temporal-designer/](skills/temporal-designer/) | Claude skill for designing, reviewing and implementing Temporal solutions (Java first) |
| [tasks.md](tasks.md) | The research brief that produced these files |

## Using the skill

```bash
# Personal install (~/.claude/skills), no clone needed
curl -fsSL https://raw.githubusercontent.com/lmquanacs/temporal-design-pattern/main/install.sh | bash

# Into the current project (.claude/skills)
curl -fsSL https://raw.githubusercontent.com/lmquanacs/temporal-design-pattern/main/install.sh | bash -s -- --project

# From a clone
./install.sh                    # or: ./install.sh --project /path/to/project
./install.sh --uninstall        # remove (add --project for a project install)
```

Re-running replaces the skill and moves the previous copy to `.claude/skill-backups/`. Set `TEMPORAL_DESIGNER_REF` to install a specific branch or tag. Restart Claude Code afterwards. The skill triggers on requests such as "design a Temporal workflow for…", "which Temporal pattern…", or "review this workflow design".

## Caveats

- Java snippets are illustrative and have not been compiled; check them against your `temporal-sdk` version.
- Limits and feature status were checked on 2026-10-25 against https://docs.temporal.io/cloud/limits and change over time.
