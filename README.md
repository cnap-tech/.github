# Akua GitHub Organization Profile

This repository maintains the public GitHub organization profile for `akua-dev`.

The rendered organization profile lives in
[profile/README.md](profile/README.md).

The organization-wide, provider-neutral GitHub Actions runner contract is
published in [RUNNERS.md](RUNNERS.md), with machine-readable
[YAML](runner-profiles.yaml) and [JSON](runner-profiles.json) catalogs. Their
canonical source and generator live in the private `akua-dev/gitops`
repository; provenance is embedded in every generated artifact.

Publication is fail-closed until the trusted provenance workflow is already
installed on the base branch. The first catalog pull request therefore requires
a separately merged bootstrap of
[runner-catalog-trusted.yml](.github/workflows/runner-catalog-trusted.yml);
the ordinary pull-request workflow has no private-source credentials and cannot
replace that boundary.
