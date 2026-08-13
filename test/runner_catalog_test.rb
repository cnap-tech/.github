require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class RunnerCatalogTest < Minitest::Test
  SCRIPT = File.expand_path("../script/validate_runner_catalog.rb", __dir__)
  SOURCE_PATH = "clusters/agentos/runner-platform/profiles.yaml"
  DOCUMENTATION = "https://github.com/akua-dev/.github/blob/main/RUNNERS.md"
  BASELINE = "ordinary build and test tooling"
  REVISION = "a" * 40
  SHA256 = "0" * 64
  PROVENANCE = {
    "repository" => "akua-dev/gitops",
    "path" => SOURCE_PATH,
    "revision" => REVISION,
    "sha256" => SHA256
  }.freeze
  CAPACITY = {
    "scope" => "organization",
    "allocation" => "shared",
    "maxConcurrentJobs" => 4,
    "queueSlo" => nil,
    "notes" => [
      "Capacity is shared by all three profiles; a profile label does not reserve a private slot.",
      "Four concurrent jobs are the current safe contract. Six was only a short load experiment."
    ]
  }.freeze
  SELECTION = {
    "safeMatch" => {
      "resources" => "required-at-most-guaranteed-minimum",
      "capabilities" => "required-subset-of-guaranteed"
    },
    "order" => %w[akua-x64-ci-v2 akua-docker-ci-v2 akua-heavy-ci-v2],
    "noMatch" => "external-runner-or-reduce-requirements"
  }.freeze
  REQUIREMENT_ENVIRONMENT = {
    "cpu" => "AKUA_CI_REQUIRED_VCPU",
    "memoryMiB" => "AKUA_CI_REQUIRED_MEMORY_MIB",
    "diskMiB" => "AKUA_CI_REQUIRED_DISK_MIB"
  }.freeze
  SOURCE_IDENTITIES = {
    "akua-x64-ci-v2" => ["linux-x64-standard-v2", "linux-x64", "Linux x64 standard", "standard-v2", "standard", "Standard"],
    "akua-docker-ci-v2" => ["linux-x64-docker-v2", "docker-x64", "Linux x64 Docker", "docker-v2", "docker", "Docker"],
    "akua-heavy-ci-v2" => ["linux-x64-heavy-v2", "heavy-x64", "Linux x64 heavy", "heavy-v2", "heavy", "Heavy"]
  }.freeze
  SOURCE_WORKLOADS = {
    "akua-x64-ci-v2" => {
      "recommended" => [
        "linting, formatting, unit tests and ordinary compilation",
        "jobs that do not start containers or require large local caches"
      ],
      "exclusions" => [
        "Docker, Buildx and GitHub Actions service containers",
        "nested virtualization, KVM and architecture-specific non-x64 builds"
      ]
    },
    "akua-docker-ci-v2" => {
      "recommended" => [
        "Docker and Buildx image builds",
        "integration tests using Docker or GitHub Actions service containers"
      ],
      "exclusions" => [
        "nested virtualization, KVM and architecture-specific non-x64 builds",
        "workloads declaring resources above this profile; use the heavy profile"
      ]
    },
    "akua-heavy-ci-v2" => {
      "recommended" => [
        "memory-heavy compilation, packaging and browser or integration suites",
        "Docker jobs whose declared requirements exceed the Docker profile"
      ],
      "exclusions" => [
        "nested virtualization, KVM and architecture-specific non-x64 builds",
        "workloads requiring more than the stated minimum resource contract"
      ]
    }
  }.freeze

  def test_public_validator_accepts_fixture_contract
    with_candidate { |candidate| assert_validator_success(candidate) }
  end

  def test_public_validator_rejects_stale_markdown
    with_candidate do |candidate|
      path = File.join(candidate, "RUNNERS.md")
      File.write(path, File.read(path).sub("7168 MiB", "7169 MiB"))
      assert_validator_failure(candidate, "README profile semantics drift")
    end
  end

  def test_public_validator_rejects_extra_markdown_contract_keys
    with_candidate do |candidate|
      path = File.join(candidate, "RUNNERS.md")
      File.write(path, File.read(path).sub("contractVersion: 2.0.0\n", "contractVersion: 2.0.0\nprovider: example\n"))
      assert_validator_failure(candidate, "README contract schema drift")
    end
  end

  def test_public_validator_rejects_stale_manifest
    with_candidate do |candidate|
      path = File.join(candidate, "runner-catalog-manifest.json")
      manifest = JSON.parse(File.read(path))
      manifest.fetch("catalog").fetch("profiles").last.fetch("minimumResources")["vcpu"] = 5
      File.write(path, JSON.pretty_generate(manifest) + "\n")
      assert_validator_failure(candidate, "manifest catalog drift")
    end
  end

  def test_public_validator_rejects_extra_provenance_fields
    with_candidate do |candidate|
      catalog = read_catalog(candidate)
      catalog.fetch("metadata").fetch("provenance")["provider"] = "example"
      write_candidate(candidate, catalog)
      assert_validator_failure(candidate, "provenance schema drift")
    end
  end

  def test_public_validator_rejects_provider_specific_public_workload_values
    with_candidate do |candidate|
      catalog = read_catalog(candidate)
      catalog.fetch("profiles").last.fetch("workload").fetch("recommended") << "provider-backed builds"
      write_candidate(candidate, catalog)
      assert_validator_failure(candidate, "public workload semantics drift")
    end
  end

  def test_trusted_validator_rejects_truthy_non_boolean_capabilities
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("capabilities")["docker"] = "false"
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      assert_validator_failure(candidate, "source capability schema drift", source)
    end
  end

  def test_trusted_validator_rejects_missing_baseline_capability
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("capabilities").delete("ordinaryBuildAndTestTooling")
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      assert_validator_failure(candidate, "source missing baseline capability", source)
    end
  end

  def test_trusted_validator_rejects_source_workload_drift
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("workload").fetch("recommended")[0] = "provider-backed compilation"
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      assert_validator_failure(candidate, "canonical source workload drift", source)
    end
  end

  def test_trusted_validator_rejects_provider_specific_source_identity
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last["class"] = "aws-x64"
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      assert_validator_failure(candidate, "canonical source profile identity drift", source)
    end
  end

  def test_trusted_validator_rejects_stale_source_resources
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("minimumResources")["vcpu"] = 5
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      assert_validator_failure(candidate, "canonical source normalization drift", source)
    end
  end

  private

  def with_candidate
    Dir.mktmpdir do |directory|
      candidate = File.join(directory, "candidate")
      FileUtils.mkdir_p(candidate)
      write_candidate(candidate, public_catalog)
      yield candidate
    end
  end

  def with_source_candidate
    with_candidate do |candidate|
      source = File.join(candidate, "source")
      source_file = File.join(source, SOURCE_PATH)
      FileUtils.mkdir_p(File.dirname(source_file))
      File.write(source_file, YAML.dump(source_catalog))
      update_source_hash(candidate, source_file)
      yield candidate, source
    end
  end

  def public_catalog(provenance = PROVENANCE)
    {
      "apiVersion" => "runners.akua.dev/v1alpha1",
      "kind" => "RunnerProfileCatalog",
      "metadata" => {
        "name" => "akua-ci-catalog",
        "contractVersion" => "2.0.0",
        "documentation" => DOCUMENTATION,
        "provenance" => provenance
      },
      "capacity" => CAPACITY,
      "policy" => {
        "requirementEnvironment" => REQUIREMENT_ENVIRONMENT,
        "selection" => SELECTION
      },
      "profiles" => public_profiles
    }
  end

  def public_profiles
    SOURCE_IDENTITIES.map do |label, values|
      source_id, source_class, source_name, id, profile_class, display_name = values
      capabilities = if label == "akua-x64-ci-v2"
        [BASELINE]
      else
        ["Docker", "Buildx", "service containers", "privileged containers", BASELINE]
      end
      resources = {
        "akua-x64-ci-v2" => { "vcpu" => 2, "memoryMiB" => 4096, "usableDiskMiB" => 10240 },
        "akua-docker-ci-v2" => { "vcpu" => 4, "memoryMiB" => 6144, "usableDiskMiB" => 15360 },
        "akua-heavy-ci-v2" => { "vcpu" => 4, "memoryMiB" => 7168, "usableDiskMiB" => 20480 }
      }.fetch(label)
      {
        "id" => id,
        "label" => label,
        "class" => profile_class,
        "displayName" => display_name,
        "status" => "active",
        "minimumResources" => resources,
        "capabilities" => { "guaranteed" => capabilities },
        "workload" => public_workload(label),
        "deprecation" => { "deprecated" => false, "announcedAt" => nil, "sunsetAt" => nil, "replacementLabel" => nil }
      }
    end
  end

  def public_workload(label)
    {
      "akua-x64-ci-v2" => {
        "recommended" => [
          "linting, formatting, unit tests and ordinary compilation",
          "jobs that do not start containers or require large local caches"
        ],
        "exclusions" => [
          "Docker, Buildx and service containers",
          "workloads whose requirements exceed the Standard guarantees"
        ]
      },
      "akua-docker-ci-v2" => {
        "recommended" => [
          "Docker and Buildx image builds",
          "integration tests using Docker or service containers"
        ],
        "exclusions" => [
          "workloads whose requirements exceed the Docker guarantees; use Heavy only when all Heavy bounds fit"
        ]
      },
      "akua-heavy-ci-v2" => {
        "recommended" => [
          "memory-heavy compilation, packaging and browser or integration suites that fit the Heavy guarantees",
          "Docker jobs whose declared requirements exceed Docker but fit Heavy"
        ],
        "exclusions" => [
          "workloads requiring more than 4 vCPU, 7168 MiB memory or 20480 MiB usable disk; use an external runner or reduce requirements"
        ]
      }
    }.fetch(label)
  end

  def source_catalog
    catalog = public_catalog
    catalog.fetch("metadata").delete("name")
    catalog.fetch("metadata").delete("documentation")
    catalog.fetch("metadata").delete("provenance")
    catalog.fetch("policy").delete("selection")
    catalog["profiles"] = catalog.fetch("profiles").map do |profile|
      label = profile.fetch("label")
      source_id, source_class, source_name = SOURCE_IDENTITIES.fetch(label)
      capability_hash = {
        "docker" => profile.dig("capabilities", "guaranteed").include?("Docker"),
        "buildx" => profile.dig("capabilities", "guaranteed").include?("Buildx"),
        "serviceContainers" => profile.dig("capabilities", "guaranteed").include?("service containers"),
        "privilegedContainers" => profile.dig("capabilities", "guaranteed").include?("privileged containers"),
        "ordinaryBuildAndTestTooling" => true
      }
      profile.merge(
        "id" => source_id,
        "class" => source_class,
        "displayName" => source_name,
        "capabilities" => capability_hash,
        "workload" => SOURCE_WORKLOADS.fetch(label)
      )
    end
    catalog
  end

  def write_candidate(candidate, catalog)
    File.write(File.join(candidate, "runner-profiles.json"), JSON.pretty_generate(catalog) + "\n")
    File.write(File.join(candidate, "runner-profiles.yaml"), YAML.dump(catalog))
    manifest = { "manifestVersion" => 1, "source" => catalog.dig("metadata", "provenance"), "catalog" => catalog }
    File.write(File.join(candidate, "runner-catalog-manifest.json"), JSON.pretty_generate(manifest) + "\n")
    File.write(File.join(candidate, "RUNNERS.md"), markdown_for(catalog))
  end

  def markdown_for(catalog)
    rows = catalog.fetch("profiles").map do |profile|
      resources = profile.fetch("minimumResources")
      capabilities = profile.dig("capabilities", "guaranteed").join(", ")
      deprecated = profile.dig("deprecation", "deprecated") ? "deprecated" : "not deprecated"
      "| `#{profile.fetch("label")}` | #{profile.fetch("displayName")} | #{resources.fetch("vcpu")} vCPU | #{resources.fetch("memoryMiB")} MiB | #{resources.fetch("usableDiskMiB")} MiB | #{capabilities} | #{profile.fetch("status")} | #{deprecated} |"
    end
    contract = {
      "contractVersion" => catalog.dig("metadata", "contractVersion"),
      "capacity" => catalog.fetch("capacity"),
      "selection" => catalog.dig("policy", "selection"),
      "provenance" => catalog.dig("metadata", "provenance")
    }
    contract_yaml = YAML.dump(contract).sub("---\n", "").lines.map { |line| "      #{line}" }.join
    <<~MARKDOWN
      # Akua GitHub Actions runner profiles

      | Label | Profile | Minimum CPU | Minimum memory | Minimum usable disk | Guaranteed capabilities | Status | Deprecation |
      | --- | --- | ---: | ---: | ---: | --- | --- | --- |
      #{rows.join("\n")}

      <!-- runner-catalog-contract
      #{contract_yaml.chomp}
      -->
    MARKDOWN
  end

  def read_catalog(candidate)
    JSON.parse(File.read(File.join(candidate, "runner-profiles.json")))
  end

  def update_source_hash(candidate, source_file)
    catalog = read_catalog(candidate)
    provenance = catalog.fetch("metadata").fetch("provenance").merge("sha256" => Digest::SHA256.file(source_file).hexdigest)
    catalog.fetch("metadata")["provenance"] = provenance
    write_candidate(candidate, catalog)
  end

  def assert_validator_success(candidate)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, SCRIPT, "--candidate-root", candidate)
    assert status.success?, "#{stdout}\n#{stderr}"
  end

  def assert_validator_failure(candidate, message, source = nil)
    args = [RbConfig.ruby, SCRIPT, "--candidate-root", candidate]
    args.concat(["--source-root", source]) if source
    stdout, stderr, status = Open3.capture3(*args)
    refute status.success?, stdout
    assert_includes stderr, message
  end
end
