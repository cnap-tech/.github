# Akua GitHub Actions runner profiles

This is the provider-neutral contract for Akua's stable self-hosted runner
labels. Workflows select guaranteed capabilities and resources; the
implementation behind a label may change without requiring repository edits.

| Label | Profile | Minimum CPU | Minimum memory | Minimum usable disk | Guaranteed capabilities | Status | Deprecation |
| --- | --- | ---: | ---: | ---: | --- | --- | --- |
| `akua-x64-ci-v2` | Standard | 2 vCPU | 4096 MiB | 10240 MiB | ordinary build and test tooling | active | not deprecated |
| `akua-docker-ci-v2` | Docker | 4 vCPU | 6144 MiB | 15360 MiB | Docker, Buildx, service containers, privileged containers, ordinary build and test tooling | active | not deprecated |
| `akua-heavy-ci-v2` | Heavy | 4 vCPU | 7168 MiB | 20480 MiB | Docker, Buildx, service containers, privileged containers, ordinary build and test tooling | active | not deprecated |

Capacity is shared across these labels and currently capped at **4 concurrent
jobs**. This is a safety limit, not a queue-start SLO or a reservation per
label.

## Selection rule

A profile is a safe match only when every declared resource is no greater than
that profile's guaranteed minimum and every required capability is guaranteed.
Select the least capable matching profile in the order shown above. If no
catalog profile matches, use an external runner or reduce the requirements;
never choose an under-provisioned profile.

1. Use `akua-x64-ci-v2` for ordinary work without containers when its resource
   requirements fit the Standard guarantees.
2. Use `akua-docker-ci-v2` for Docker, Buildx or service containers, and for
   other work whose requirements exceed Standard but fit the Docker guarantees.
3. Use `akua-heavy-ci-v2` only when requirements exceed Docker but fit all Heavy
   guarantees: **4 vCPU, 7168 MiB memory and 20480 MiB usable disk**. A known
   heavy suite must also be checked against those bounds. Requirements above
   Heavy are explicitly unsupported by this catalog and require an external
   runner or reduced requirements.

If a job relies on a resource size, declare it in job-level environment
variables so policy can verify the profile:

```yaml
env:
  AKUA_CI_REQUIRED_VCPU: "4"
  AKUA_CI_REQUIRED_MEMORY_MIB: "7000"
  AKUA_CI_REQUIRED_DISK_MIB: "18000"
```

## `akua-x64-ci-v2`

Use for:

- linting, formatting, unit tests and ordinary compilation
- jobs that do not start containers or require large local caches

Do not use for:

- Docker, Buildx and service containers
- workloads whose requirements exceed the Standard guarantees

## `akua-docker-ci-v2`

Use for:

- Docker and Buildx image builds
- integration tests using Docker or service containers

Do not use for:

- workloads whose requirements exceed the Docker guarantees; use Heavy only
  when all Heavy bounds fit

## `akua-heavy-ci-v2`

Use for:

- memory-heavy compilation, packaging and browser or integration suites that
  fit the Heavy guarantees
- Docker jobs whose declared requirements exceed Docker but fit Heavy

Do not use for:

- workloads requiring more than 4 vCPU, 7168 MiB memory or 20480 MiB usable
  disk; use an external runner or reduce requirements

## Versioning and deprecation

The catalog contract is `2.0.0`. Additive guarantees may increment the catalog
minor version. Reduced guarantees or removed capabilities require a new
workflow label. Deprecated profiles publish announcement, sunset and
replacement metadata before retirement.

Machine-readable forms: [`runner-profiles.yaml`](runner-profiles.yaml) and
[`runner-profiles.json`](runner-profiles.json).

<!-- runner-catalog-contract
contractVersion: 2.0.0
capacity:
  scope: organization
  allocation: shared
  maxConcurrentJobs: 4
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
  revision: ca39219715c3b6723452d8be79689e73470b5810
  sha256: 5d3c88e7fa34d77209463bd39bcbad592a7d2feda751199add358d5f109bc598
-->
