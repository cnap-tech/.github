#!/usr/bin/env ruby

require "digest"
require "json"
require "optparse"
require "yaml"

class RunnerCatalogValidationError < StandardError; end

class RunnerCatalogValidator
  SOURCE_RELATIVE_PATH = "clusters/agentos/runner-platform/profiles.yaml"
  DOCUMENTATION = "https://github.com/akua-dev/.github/blob/main/RUNNERS.md"
  BASELINE_CAPABILITY = "ordinary build and test tooling"
  CAPABILITY_NAMES = {
    "docker" => "Docker",
    "buildx" => "Buildx",
    "serviceContainers" => "service containers",
    "privilegedContainers" => "privileged containers",
    "ordinaryBuildAndTestTooling" => BASELINE_CAPABILITY
  }.freeze
  PUBLIC_CAPABILITIES = (CAPABILITY_NAMES.values + [BASELINE_CAPABILITY]).freeze
  PROFILE_DEFINITIONS = {
    "akua-x64-ci-v2" => {
      "sourceId" => "linux-x64-standard-v2",
      "sourceClass" => "linux-x64",
      "sourceDisplayName" => "Linux x64 standard",
      "id" => "standard-v2",
      "class" => "standard",
      "displayName" => "Standard"
    },
    "akua-docker-ci-v2" => {
      "sourceId" => "linux-x64-docker-v2",
      "sourceClass" => "docker-x64",
      "sourceDisplayName" => "Linux x64 Docker",
      "id" => "docker-v2",
      "class" => "docker",
      "displayName" => "Docker"
    },
    "akua-heavy-ci-v2" => {
      "sourceId" => "linux-x64-heavy-v2",
      "sourceClass" => "heavy-x64",
      "sourceDisplayName" => "Linux x64 heavy",
      "id" => "heavy-v2",
      "class" => "heavy",
      "displayName" => "Heavy"
    }
  }.freeze
  SOURCE_WORKLOAD_NORMALIZATIONS = {
    "akua-x64-ci-v2" => {
      "source" => {
        "recommended" => [
          "linting, formatting, unit tests and ordinary compilation",
          "jobs that do not start containers or require large local caches"
        ],
        "exclusions" => [
          "Docker, Buildx and GitHub Actions service containers",
          "nested virtualization, KVM and architecture-specific non-x64 builds"
        ]
      },
      "public" => {
        "recommended" => [
          "linting, formatting, unit tests and ordinary compilation",
          "jobs that do not start containers or require large local caches"
        ],
        "exclusions" => [
          "Docker, Buildx and service containers",
          "workloads whose requirements exceed the Standard guarantees"
        ]
      }
    },
    "akua-docker-ci-v2" => {
      "source" => {
        "recommended" => [
          "Docker and Buildx image builds",
          "integration tests using Docker or GitHub Actions service containers"
        ],
        "exclusions" => [
          "nested virtualization, KVM and architecture-specific non-x64 builds",
          "workloads declaring resources above this profile; use the heavy profile"
        ]
      },
      "public" => {
        "recommended" => [
          "Docker and Buildx image builds",
          "integration tests using Docker or service containers"
        ],
        "exclusions" => [
          "workloads whose requirements exceed the Docker guarantees; use Heavy only when all Heavy bounds fit"
        ]
      }
    },
    "akua-heavy-ci-v2" => {
      "source" => {
        "recommended" => [
          "memory-heavy compilation, packaging and browser or integration suites",
          "Docker jobs whose declared requirements exceed the Docker profile"
        ],
        "exclusions" => [
          "nested virtualization, KVM and architecture-specific non-x64 builds",
          "workloads requiring more than the stated minimum resource contract"
        ]
      },
      "public" => {
        "recommended" => [
          "memory-heavy compilation, packaging and browser or integration suites that fit the Heavy guarantees",
          "Docker jobs whose declared requirements exceed Docker but fit Heavy"
        ],
        "exclusions" => [
          "workloads requiring more than %{vcpu} vCPU, %{memoryMiB} MiB memory or %{usableDiskMiB} MiB usable disk; use an external runner or reduce requirements"
        ]
      }
    }
  }.freeze
  SELECTION = {
    "safeMatch" => {
      "resources" => "required-at-most-guaranteed-minimum",
      "capabilities" => "required-subset-of-guaranteed"
    },
    "order" => %w[akua-x64-ci-v2 akua-docker-ci-v2 akua-heavy-ci-v2],
    "noMatch" => "external-runner-or-reduce-requirements"
  }.freeze
  PROFILE_KEYS = %w[capabilities class deprecation displayName id label minimumResources status workload].freeze
  METADATA_KEYS = %w[contractVersion documentation name provenance].freeze
  PROVENANCE_KEYS = %w[path repository revision sha256].freeze
  PUBLIC_API_VERSION = "runners.akua.dev/v1alpha1"
  PUBLIC_KIND = "RunnerProfileCatalog"
  REQUIREMENT_ENVIRONMENT = {
    "cpu" => "AKUA_CI_REQUIRED_VCPU",
    "memoryMiB" => "AKUA_CI_REQUIRED_MEMORY_MIB",
    "diskMiB" => "AKUA_CI_REQUIRED_DISK_MIB"
  }.freeze

  def initialize(candidate_root:, source_root: nil)
    @candidate_root = File.expand_path(candidate_root)
    @source_root = source_root && File.expand_path(source_root)
  end

  def validate!
    catalog = load_catalog
    validate_public_contract!(catalog)
    validate_markdown!(catalog)
    validate_source!(catalog) if @source_root
    catalog
  rescue KeyError, JSON::ParserError, Psych::Exception, Errno::ENOENT => error
    raise RunnerCatalogValidationError, error.message
  end

  private

  def load_catalog
    json = JSON.parse(File.read(File.join(@candidate_root, "runner-profiles.json")))
    yaml = YAML.safe_load(File.read(File.join(@candidate_root, "runner-profiles.yaml")), aliases: false)
    fail_with("JSON and YAML catalogs differ") unless json == yaml
    manifest = JSON.parse(File.read(File.join(@candidate_root, "runner-catalog-manifest.json")))
    fail_with("manifest schema drift") unless manifest.keys.sort == %w[catalog manifestVersion source]
    fail_with("manifest version drift") unless manifest.fetch("manifestVersion") == 1
    fail_with("manifest provenance drift") unless manifest.fetch("source") == json.dig("metadata", "provenance")
    fail_with("manifest catalog drift") unless manifest.fetch("catalog") == json
    fail_with("catalog schema drift") unless json.keys.sort == %w[apiVersion capacity kind metadata policy profiles]
    json
  end

  def validate_public_contract!(catalog)
    metadata = catalog.fetch("metadata")
    fail_with("provider-neutral metadata drift") unless metadata.keys.sort == METADATA_KEYS
    fail_with("catalog api schema drift") unless catalog.fetch("apiVersion") == PUBLIC_API_VERSION && catalog.fetch("kind") == PUBLIC_KIND
    fail_with("catalog contract version drift") unless metadata.fetch("contractVersion") == "2.0.0"
    fail_with("catalog name drift") unless metadata.fetch("name") == "akua-ci-catalog"
    fail_with("documentation drift") unless metadata.fetch("documentation") == DOCUMENTATION

    provenance = metadata.fetch("provenance")
    fail_with("provenance schema drift") unless provenance.keys.sort == PROVENANCE_KEYS
    fail_with("non-canonical provenance") unless provenance.slice("repository", "path") == {
      "repository" => "akua-dev/gitops",
      "path" => SOURCE_RELATIVE_PATH
    }
    fail_with("missing source revision") unless provenance.fetch("revision", "").match?(/\A[0-9a-f]{40}\z/)
    fail_with("missing source SHA-256") unless provenance.fetch("sha256", "").match?(/\A[0-9a-f]{64}\z/)
    capacity = catalog.fetch("capacity")
    expected_capacity = {
      "scope" => "organization",
      "allocation" => "shared",
      "maxConcurrentJobs" => 4,
      "queueSlo" => nil,
      "notes" => [
        "Capacity is shared by all three profiles; a profile label does not reserve a private slot.",
        "Four concurrent jobs are the current safe contract. Six was only a short load experiment."
      ]
    }
    fail_with("unsafe capacity contract") unless capacity == expected_capacity

    policy = catalog.fetch("policy")
    fail_with("selection policy drift") unless policy.keys.sort == %w[requirementEnvironment selection]
    fail_with("requirement environment drift") unless policy.fetch("requirementEnvironment") == REQUIREMENT_ENVIRONMENT
    fail_with("selection policy drift") unless policy.fetch("selection") == SELECTION

    profiles = catalog.fetch("profiles")
    fail_with("stable labels drift") unless profiles.map { |profile| profile.fetch("label") } == SELECTION.fetch("order")
    profiles.each do |profile|
      fail_with("provider-specific profile fields") unless profile.keys.sort == PROFILE_KEYS
      definition = PROFILE_DEFINITIONS.fetch(profile.fetch("label")) { fail_with("stable labels drift") }
      fail_with("public profile identity drift") unless profile.slice("id", "class", "displayName") == definition.slice("id", "class", "displayName")
      fail_with("public profile resources drift") unless profile.fetch("minimumResources").keys.sort == %w[memoryMiB usableDiskMiB vcpu]
      fail_with("public profile resources drift") unless profile.fetch("minimumResources").values.all? { |value| value.is_a?(Integer) && value.positive? }
      capabilities = profile.fetch("capabilities")
      fail_with("public capability schema drift") unless capabilities.keys == ["guaranteed"]
      fail_with("public capability vocabulary drift") unless capabilities.fetch("guaranteed").all? { |capability| PUBLIC_CAPABILITIES.include?(capability) }
      fail_with("missing baseline capability") unless profile.dig("capabilities", "guaranteed").include?(BASELINE_CAPABILITY)
      fail_with("public workload semantics drift") unless profile.fetch("workload") == public_workload_for(profile.fetch("label"), profile.fetch("minimumResources"))
      fail_with("profile status drift") unless profile.fetch("status") == "active"
      fail_with("profile deprecation drift") unless profile.fetch("deprecation") == {
        "deprecated" => false,
        "announcedAt" => nil,
        "sunsetAt" => nil,
        "replacementLabel" => nil
      }
    end
  end

  def validate_markdown!(catalog)
    markdown = File.read(File.join(@candidate_root, "RUNNERS.md"))
    contract_match = markdown.match(/<!-- runner-catalog-contract\s*\n(.*?)\n-->/m)
    fail_with("missing structured catalog contract") unless contract_match
    markdown_contract = YAML.safe_load(contract_match[1], aliases: false)
    fail_with("README contract schema drift") unless markdown_contract.keys.sort == %w[capacity contractVersion provenance selection]
    fail_with("README contract version drift") unless markdown_contract.fetch("contractVersion") == catalog.dig("metadata", "contractVersion")
    fail_with("README capacity drift") unless markdown_contract.fetch("capacity") == catalog.fetch("capacity")
    fail_with("README selection drift") unless markdown_contract.fetch("selection") == catalog.dig("policy", "selection")
    fail_with("README provenance drift") unless markdown_contract.fetch("provenance") == catalog.dig("metadata", "provenance")

    lines = markdown.lines.map(&:chomp)
    contract_matches = markdown.to_enum(:scan, /<!-- runner-catalog-contract\s*\n(.*?)\n-->/m).map { Regexp.last_match }
    fail_with("README contract multiplicity drift") unless contract_matches.length == 1
    header_index = lines.index { |line| line.start_with?("| Label | Profile |") }
    fail_with("missing profile table") unless header_index
    table_lines = lines[(header_index + 2)..].take_while { |line| line.start_with?("| `akua-") }
    table = table_lines.map do |line|
      cells = line.strip.split("|", -1)[1...-1].map(&:strip)
      fail_with("malformed profile table") unless cells.length == 8
      cpu = cells.fetch(2).match?(/\A\d+ vCPU\z/) && cells.fetch(2).to_i
      memory = cells.fetch(3).match?(/\A\d+ MiB\z/) && cells.fetch(3).to_i
      disk = cells.fetch(4).match?(/\A\d+ MiB\z/) && cells.fetch(4).to_i
      fail_with("malformed profile resources") unless cpu && memory && disk
      {
        "label" => cells.fetch(0).delete("`"),
        "displayName" => cells.fetch(1),
        "minimumResources" => { "vcpu" => cpu, "memoryMiB" => memory, "usableDiskMiB" => disk },
        "guaranteed" => cells.fetch(5).split(/,\s*/),
        "status" => cells.fetch(6),
        "deprecation" => cells.fetch(7)
      }
    end
    expected_table = catalog.fetch("profiles").map do |profile|
      {
        "label" => profile.fetch("label"),
        "displayName" => profile.fetch("displayName"),
        "minimumResources" => profile.fetch("minimumResources"),
        "guaranteed" => profile.dig("capabilities", "guaranteed"),
        "status" => profile.fetch("status"),
        "deprecation" => profile.dig("deprecation", "deprecated") ? "deprecated" : "not deprecated"
      }
    end
    fail_with("README profile semantics drift") unless table == expected_table
    fail_with("README document semantics drift") unless markdown_text_model(lines, header_index, table_lines, contract_matches.fetch(0)) == expected_markdown_text_model(catalog)
  end

  def markdown_text_model(lines, header_index, table_lines, contract_match)
    contract_start = lines.index { |line| line == "<!-- runner-catalog-contract" }
    contract_end = lines.index { |line| line == "-->" }
    table_end = header_index + 2 + table_lines.length
    ignored = (contract_start..contract_end).to_a + (header_index...table_end).to_a
    lines.each_with_index.reject { |_line, index| ignored.include?(index) }.map(&:first).reject(&:empty?)
  end

  def expected_markdown_text_model(catalog)
    heavy = catalog.fetch("profiles").find { |profile| profile.fetch("label") == "akua-heavy-ci-v2" }
    heavy_resources = heavy.fetch("minimumResources")
    lines = [
      "# Akua GitHub Actions runner profiles",
      "This provider-neutral catalog defines the stable runner labels and their conservative guarantees.",
      "Workflows select a label by declared resources and capabilities; the implementation behind a label may change without repository edits.",
      "Capacity is shared across all profiles and capped at #{catalog.dig("capacity", "maxConcurrentJobs")} concurrent jobs. A label does not reserve a private slot.",
      "## Selection rules",
      "1. Select the first profile whose guaranteed resources meet the declared requirements and whose capabilities contain every required capability.",
      "2. Use the stable label in workflow configuration; do not infer implementation details from the label.",
      "3. Use `akua-heavy-ci-v2` only when requirements exceed Docker but fit Heavy: #{heavy_resources.fetch("vcpu")} vCPU, #{heavy_resources.fetch("memoryMiB")} MiB memory and #{heavy_resources.fetch("usableDiskMiB")} MiB usable disk.",
      "Requirements above Heavy, or capabilities absent from every profile, require an external runner or reduced requirements.",
      "Required-resource inputs are supplied through AKUA_CI_REQUIRED_VCPU, AKUA_CI_REQUIRED_MEMORY_MIB and AKUA_CI_REQUIRED_DISK_MIB.",
      "## Profile guarantees"
    ]
    catalog.fetch("profiles").each do |profile|
      workload = profile.fetch("workload")
      lines << "## `#{profile.fetch("label")}`"
      lines << "Recommended uses:"
      lines.concat(workload.fetch("recommended").map { |item| "- #{item}" })
      lines << "Exclusions:"
      lines.concat(workload.fetch("exclusions").map { |item| "- #{item}" })
    end
    lines.concat([
      "## Versioning and deprecation",
      "The public contract version is #{catalog.dig("metadata", "contractVersion")}. Profiles are active and not deprecated unless the structured catalog says otherwise.",
      "The machine-readable catalogs and provenance manifest are the canonical serialized projections of this document."
    ])
    lines
  end

  def validate_source!(catalog)
    source_path = File.join(@source_root, SOURCE_RELATIVE_PATH)
    fail_with("canonical source missing") unless File.file?(source_path)
    provenance = catalog.dig("metadata", "provenance")
    fail_with("canonical source hash mismatch") unless Digest::SHA256.file(source_path).hexdigest == provenance.fetch("sha256")
    source = YAML.safe_load(File.read(source_path), aliases: false)
    expected = normalize_source(source, provenance)
    fail_with("canonical source normalization drift") unless catalog == expected
  end

  def normalize_source(source, provenance)
    fail_with("canonical source api schema drift") unless source.fetch("apiVersion") == PUBLIC_API_VERSION && source.fetch("kind") == PUBLIC_KIND
    fail_with("canonical source contract version drift") unless source.dig("metadata", "contractVersion") == "2.0.0"
    {
      "apiVersion" => PUBLIC_API_VERSION,
      "kind" => PUBLIC_KIND,
      "metadata" => {
        "name" => "akua-ci-catalog",
        "contractVersion" => source.dig("metadata", "contractVersion"),
        "documentation" => DOCUMENTATION,
        "provenance" => provenance
      },
      "capacity" => normalize_capacity(source.fetch("capacity")),
      "policy" => {
        "requirementEnvironment" => normalize_requirement_environment(source.dig("policy", "requirementEnvironment")),
        "selection" => SELECTION
      },
      "profiles" => source.fetch("profiles").map { |profile| normalize_profile(profile) }
    }
  end

  def normalize_capacity(capacity)
    expected = {
      "scope" => "organization",
      "allocation" => "shared",
      "maxConcurrentJobs" => 4,
      "queueSlo" => nil,
      "notes" => [
        "Capacity is shared by all three profiles; a profile label does not reserve a private slot.",
        "Four concurrent jobs are the current safe contract. Six was only a short load experiment."
      ]
    }
    fail_with("canonical source capacity drift") unless capacity == expected
    expected
  end

  def normalize_requirement_environment(environment)
    fail_with("canonical source requirement environment drift") unless environment == REQUIREMENT_ENVIRONMENT
    REQUIREMENT_ENVIRONMENT
  end

  def normalize_profile(source_profile)
    label = source_profile.fetch("label")
    definition = PROFILE_DEFINITIONS.fetch(label) { fail_with("canonical source profile label drift") }
    expected_source_identity = {
      "id" => definition.fetch("sourceId"),
      "class" => definition.fetch("sourceClass"),
      "displayName" => definition.fetch("sourceDisplayName")
    }
    fail_with("canonical source profile identity drift") unless source_profile.slice(*expected_source_identity.keys) == expected_source_identity
    resources = source_profile.fetch("minimumResources")
    fail_with("canonical source resource schema drift") unless resources.is_a?(Hash) && resources.keys.sort == %w[memoryMiB usableDiskMiB vcpu]
    fail_with("canonical source resource schema drift") unless resources.values.all? { |value| value.is_a?(Integer) && value.positive? }
    {
      "id" => definition.fetch("id"),
      "label" => label,
      "class" => definition.fetch("class"),
      "displayName" => definition.fetch("displayName"),
      "status" => source_profile.fetch("status"),
      "minimumResources" => resources,
      "capabilities" => { "guaranteed" => normalize_capabilities(source_profile.fetch("capabilities")) },
      "workload" => normalize_workload(source_profile.fetch("workload"), label, resources),
      "deprecation" => source_profile.fetch("deprecation").transform_values { |value| value == "" ? nil : value }
    }
  end

  def normalize_capabilities(capabilities)
    fail_with("source capability schema drift") unless capabilities.is_a?(Hash)
    fail_with("source capability schema drift") unless capabilities.keys.all? { |key| CAPABILITY_NAMES.key?(key) }
    result = CAPABILITY_NAMES.each_with_object([]) do |(key, name), values|
      value = capabilities.fetch(key, false)
      fail_with("source capability schema drift") unless value == true || value == false
      values << name if value
    end
    fail_with("source capability not allowlisted") unless result.all? { |capability| PUBLIC_CAPABILITIES.include?(capability) }
    fail_with("source missing baseline capability") unless result.include?(BASELINE_CAPABILITY)
    result
  end

  def normalize_workload(workload, label, resources)
    normalization = SOURCE_WORKLOAD_NORMALIZATIONS.fetch(label) { fail_with("source profile label not allowlisted") }
    fail_with("canonical source workload drift") unless workload == normalization.fetch("source")
    public_workload_for(label, resources)
  end

  def public_workload_for(label, resources)
    normalization = SOURCE_WORKLOAD_NORMALIZATIONS.fetch(label) { fail_with("source profile label not allowlisted") }
    public_workload = normalization.fetch("public").each_with_object({}) do |(key, values), copy|
      copy[key] = values.dup
    end
    return public_workload unless label == "akua-heavy-ci-v2"

    public_workload["exclusions"] = public_workload.fetch("exclusions").map do |exclusion|
      format(
        exclusion,
        vcpu: resources.fetch("vcpu"),
        memoryMiB: resources.fetch("memoryMiB"),
        usableDiskMiB: resources.fetch("usableDiskMiB")
      )
    end
    public_workload
  end

  def fail_with(message)
    raise RunnerCatalogValidationError, message
  end
end

options = { candidate_root: ".", source_root: nil }
OptionParser.new do |parser|
  parser.on("--candidate-root PATH") { |path| options[:candidate_root] = path }
  parser.on("--source-root PATH") { |path| options[:source_root] = path }
end.parse!

begin
  RunnerCatalogValidator.new(**options).validate!
rescue RunnerCatalogValidationError => error
  warn error.message
  exit 1
end
