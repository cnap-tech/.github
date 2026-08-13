# Akua GitHub Organization Profile

This repository maintains the public GitHub organization profile for `akua-dev`.

The rendered organization profile lives in
[profile/README.md](profile/README.md).

This change installs the base-owned, secret-free validation infrastructure for
the provider-neutral runner catalog. It intentionally publishes no runner
catalog yet.

After this bootstrap merges to `main`, create the follow-up catalog publication
change from that merge commit. That change adds `RUNNERS.md`,
`runner-profiles.yaml`, `runner-profiles.json`, and
`runner-catalog-manifest.json`; its pull request is then checked by the
base-owned [`runner-catalog-trusted.yml`](.github/workflows/runner-catalog-trusted.yml)
workflow against the private `akua-dev/gitops` source.
