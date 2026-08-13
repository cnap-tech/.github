# Akua GitHub Actions runner profiles

This provider-neutral catalog defines the stable runner labels and their conservative guarantees.
Workflows select a label by declared resources and capabilities; the implementation behind a label may change without repository edits.
Capacity is shared across all profiles and capped at 4 concurrent jobs. A label does not reserve a private slot.

<!-- runner-catalog-contract
contractVersion: 2.0.0
capacity:
  scope: organization
  allocation: shared
  maxConcurrentJobs: 4
  queueSlo: 
  notes:
  - Capacity is shared by all three profiles; a profile label does not reserve a private
    slot.
  - Four concurrent jobs are the current safe contract. Six was only a short load
    experiment.
selection:
  safeMatch:
    resources: required-at-most-guaranteed-minimum
    capabilities: required-subset-of-guaranteed
  order:
  - akua-x64-ci-v2
  - akua-docker-ci-v2
  - akua-heavy-ci-v2
  noMatch: external-runner-or-reduce-requirements
provenance:
  repository: akua-dev/gitops
  path: clusters/agentos/runner-platform/profiles.yaml
  revision: 59234e828aa544b2079404ffccd12d334567c0ac
  sha256: 00a7ffd62374be2919214455967c06befc4f29c9425b682e07290e5606bca7e5
-->

## Selection rules

1. Select the first profile whose guaranteed resources meet the declared requirements and whose capabilities contain every required capability.
2. Use the stable label in workflow configuration; do not infer implementation details from the label.
3. Use `akua-heavy-ci-v2` only when requirements exceed Docker but fit Heavy: 4 vCPU, 7168 MiB memory and 20480 MiB usable disk.
Requirements above Heavy, or capabilities absent from every profile, require an external runner or reduced requirements.
Required-resource inputs are supplied through AKUA_CI_REQUIRED_VCPU, AKUA_CI_REQUIRED_MEMORY_MIB and AKUA_CI_REQUIRED_DISK_MIB.

## Profile guarantees

| Label | Profile | Minimum CPU | Minimum memory | Minimum usable disk | Guaranteed capabilities | Status | Deprecation |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| `akua-x64-ci-v2` | Standard | 2 vCPU | 4096 MiB | 10240 MiB | ordinary build and test tooling | active | not deprecated |
| `akua-docker-ci-v2` | Docker | 4 vCPU | 6144 MiB | 15360 MiB | Docker, Buildx, service containers, privileged containers, ordinary build and test tooling | active | not deprecated |
| `akua-heavy-ci-v2` | Heavy | 4 vCPU | 7168 MiB | 20480 MiB | Docker, Buildx, service containers, privileged containers, ordinary build and test tooling | active | not deprecated |

## `akua-x64-ci-v2`

Recommended uses:
- linting, formatting, unit tests and ordinary compilation
- jobs that do not start containers or require large local caches

Exclusions:
- Docker, Buildx and service containers
- workloads whose requirements exceed the Standard guarantees

## `akua-docker-ci-v2`

Recommended uses:
- Docker and Buildx image builds
- integration tests using Docker or service containers

Exclusions:
- workloads whose requirements exceed the Docker guarantees; use Heavy only when all Heavy bounds fit

## `akua-heavy-ci-v2`

Recommended uses:
- memory-heavy compilation, packaging and browser or integration suites that fit the Heavy guarantees
- Docker jobs whose declared requirements exceed Docker but fit Heavy

Exclusions:
- workloads requiring more than 4 vCPU, 7168 MiB memory or 20480 MiB usable disk; use an external runner or reduce requirements

## Versioning and deprecation

The public contract version is 2.0.0. Profiles are active and not deprecated unless the structured catalog says otherwise.
The machine-readable catalogs and provenance manifest are the canonical serialized projections of this document.

