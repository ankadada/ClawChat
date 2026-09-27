# Skill examples

`github`, `translator`, and `code-review` are **not bundled in-app skills**.
They used to ship as locked presets; the I4 skill disposition moved them out.

They live here as plain examples you can copy into your workspace if you want
them:

- `github/SKILL.md` — curl + `GITHUB_TOKEN` recipe for the GitHub API.
  It is a script, not a phone sense, so the app no longer ships it as a
  built-in skill.
- `translator/SKILL.md` — prompt-only translation instructions. It needs no
  extra runtime, so a built-in tile added nothing.
- `code-review/SKILL.md` — code review guidance. ClawChat is a personal agent,
  not an engineering coding product, so this left the bundle.

To use one, copy the `SKILL.md` into the workspace skills directory
(`/root/workspace/skills/<name>/SKILL.md`). Workspace skills are inspected and
require the same explicit consent as any other legacy skill, and a skill file
still cannot grant `phone_send` or bypass Ask.
