# Akua GitHub Actions runner profiles

This is the provider-neutral contract for Akua's stable self-hosted Linux
runner labels. Workflows select capabilities; the implementation behind a
label may change without requiring repository edits.

| Label | Profile | Minimum CPU | Minimum memory | Minimum usable disk | Guaranteed capabilities |
| --- | --- | ---: | ---: | ---: | --- |
| `akua-x64-ci-v2` | Linux x64 standard | 2 vCPU | 4096 MiB | 10240 MiB | ordinary Linux tooling |
| `akua-docker-ci-v2` | Linux x64 Docker | 4 vCPU | 6144 MiB | 15360 MiB | Docker, Buildx, service containers |
| `akua-heavy-ci-v2` | Linux x64 heavy | 4 vCPU | 7168 MiB | 20480 MiB | Docker, Buildx, service containers |

Capacity is shared across these labels and currently capped at **4 concurrent jobs**. This is a safety limit, not a queue-start SLO or a reservation per label.

## Selection rule

1. Use `akua-x64-ci-v2` for ordinary Linux x64 work without containers.
2. Use `akua-docker-ci-v2` for Docker, Buildx or service containers.
3. Use `akua-heavy-ci-v2` when declared CPU, memory or disk requirements exceed the Docker profile, or for known memory-heavy build/test suites.

If a job relies on a resource size, declare it in job-level environment
variables so policy can verify the profile:

```yaml
env:
  AKUA_CI_REQUIRED_VCPU: "4"
  AKUA_CI_REQUIRED_MEMORY_MIB: "7000"
  AKUA_CI_REQUIRED_DISK_MIB: "18000"
```

GitHub-hosted ARM64, Windows and macOS labels remain valid when this catalog
does not provide the required architecture. Never select labels containing
backend/runtime/provider names.

## `akua-x64-ci-v2`

Use for:

- linting, formatting, unit tests and ordinary compilation
- jobs that do not start containers or require large local caches

Do not use for:

- Docker, Buildx and GitHub Actions service containers
- nested virtualization, KVM and architecture-specific non-x64 builds

## `akua-docker-ci-v2`

Use for:

- Docker and Buildx image builds
- integration tests using Docker or GitHub Actions service containers

Do not use for:

- nested virtualization, KVM and architecture-specific non-x64 builds
- workloads declaring resources above this profile; use the heavy profile

## `akua-heavy-ci-v2`

Use for:

- memory-heavy compilation, packaging and browser or integration suites
- Docker jobs whose declared requirements exceed the Docker profile

Do not use for:

- nested virtualization, KVM and architecture-specific non-x64 builds
- workloads requiring more than the stated minimum resource contract

## Versioning and deprecation

The catalog contract is `2.0.0` and
the runner image/toolchain contract is `ubuntu-24.04-v1`.
Additive guarantees may increment the catalog minor version. Reduced
guarantees or removed capabilities require a new workflow label. Deprecated
profiles publish announcement, sunset and replacement metadata before
retirement.

Machine-readable forms: [`runner-profiles.yaml`](runner-profiles.yaml) and
[`runner-profiles.json`](runner-profiles.json).

Provenance: `akua-dev/gitops@ca39219715c3b6723452d8be79689e73470b5810` path
`clusters/agentos/runner-platform/profiles.yaml`, source SHA-256 `5d3c88e7fa34d77209463bd39bcbad592a7d2feda751199add358d5f109bc598`.
