# Project agent memory

This repository maintains the public GitHub organization profile for `akua-dev`.
The rendered profile content lives in `profile/README.md`.

## Runner profile contract

Use `RUNNERS.md` to select stable GitHub Actions labels. Agents should express
required capabilities and resources, never ARC, Firecracker, Kata, Kubernetes,
cloud-provider or node implementation details. `runner-profiles.yaml` and
`runner-profiles.json` are generated from `akua-dev/gitops`; do not edit them or
`RUNNERS.md` directly.

## Profile README guidance

- Keep `profile/README.md` closely aligned with a shorter version of the
  product/docs quickstart, not a long marketing page.
- Optimize for less text, clearer scanning, and direct paths for builders to
  understand what Akua is and where to start.
- Keep the hero image, including its GitHub-safe baked-in frame, at the top
  unless the captain changes the design.
- Do not duplicate the hero headline immediately below the image.
- Link out to `https://akua.dev`, full docs, and quickstart pages instead of
  copying long sections into the profile.
- Store profile-specific assets under `profile/assets/` and use descriptive alt
  text for images.

## Validation

- After README changes, scan for broken relative asset links.
- Preview rendered Markdown before shipping visual changes.

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this
project.
Do not repeat what the codebase already shows; point to the authoritative file or
command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar and keep entries concise.
