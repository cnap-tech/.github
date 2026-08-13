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
    "privilegedContainers" => "privileged containers"
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
  BANNED_PUBLIC_KEYS = %w[allowedExternalLabelPatterns imageContractVersion platform runtimeSpecificLabelPatterns].freeze

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
    json
  end

  def validate_public_contract!(catalog)
    metadata = catalog.fetch("metadata")
    fail_with("provider-neutral metadata drift") unless metadata.keys.sort == METADATA_KEYS
    fail_with("catalog name drift") unless metadata.fetch("name") == "akua-ci-catalog"
    fail_with("documentation drift") unless metadata.fetch("documentation") == DOCUMENTATION

    provenance = metadata.fetch("provenance")
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
    fail_with("selection policy drift") unless policy.fetch("selection") == SELECTION

    profiles = catalog.fetch("profiles")
    fail_with("stable labels drift") unless profiles.map { |profile| profile.fetch("label") } == SELECTION.fetch("order")
    profiles.each do |profile|
      fail_with("provider-specific profile fields") unless profile.keys.sort == PROFILE_KEYS
      fail_with("missing baseline capability") unless profile.dig("capabilities", "guaranteed").include?(BASELINE_CAPABILITY)
      fail_with("profile status drift") unless profile.fetch("status") == "active"
      fail_with("profile deprecation drift") unless profile.fetch("deprecation") == {
        "deprecated" => false,
        "announcedAt" => nil,
        "sunsetAt" => nil,
        "replacementLabel" => nil
      }
      fail_with("runtime or provider detail in public catalog") if contains_banned_key?(profile)
    end
  end

  def validate_markdown!(catalog)
    markdown = File.read(File.join(@candidate_root, "RUNNERS.md"))
    contract_match = markdown.match(/<!-- runner-catalog-contract\s*\n(.*?)\n-->/m)
    fail_with("missing structured catalog contract") unless contract_match
    markdown_contract = YAML.safe_load(contract_match[1], aliases: false)
    fail_with("README contract version drift") unless markdown_contract.fetch("contractVersion") == catalog.dig("metadata", "contractVersion")
    fail_with("README capacity drift") unless markdown_contract.fetch("capacity") == catalog.fetch("capacity")
    fail_with("README selection drift") unless markdown_contract.fetch("selection") == catalog.dig("policy", "selection")
    fail_with("README provenance drift") unless markdown_contract.fetch("provenance") == catalog.dig("metadata", "provenance")

    header_index = markdown.lines.index { |line| line.start_with?("| Label | Profile |") }
    fail_with("missing profile table") unless header_index
    table_lines = markdown.lines[(header_index + 2)..].take_while { |line| line.start_with?("| `akua-") }
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
    {
      "apiVersion" => source.fetch("apiVersion"),
      "kind" => source.fetch("kind"),
      "metadata" => {
        "name" => "akua-ci-catalog",
        "contractVersion" => source.dig("metadata", "contractVersion"),
        "documentation" => DOCUMENTATION,
        "provenance" => provenance
      },
      "capacity" => normalize_capacity(source.fetch("capacity")),
      "policy" => {
        "requirementEnvironment" => source.dig("policy", "requirementEnvironment"),
        "selection" => SELECTION
      },
      "profiles" => source.fetch("profiles").map { |profile| normalize_profile(profile) }
    }
  end

  def normalize_capacity(capacity)
    capacity.slice("scope", "allocation", "maxConcurrentJobs", "queueSlo", "notes")
  end

  def normalize_profile(source_profile)
    label = source_profile.fetch("label")
    display_name = source_profile.fetch("displayName").sub(/\ALinux x64 /i, "").split.map(&:capitalize).join(" ")
    normalized_class = source_profile.fetch("class").sub(/\Alinux-x64\z/, "standard").sub(/-x64\z/, "")
    {
      "id" => source_profile.fetch("id").sub(/\Alinux-x64-/, ""),
      "label" => label,
      "class" => normalized_class,
      "displayName" => display_name,
      "status" => source_profile.fetch("status"),
      "minimumResources" => source_profile.fetch("minimumResources"),
      "capabilities" => { "guaranteed" => normalize_capabilities(source_profile.fetch("capabilities")) },
      "workload" => normalize_workload(source_profile.fetch("workload"), label, display_name),
      "deprecation" => source_profile.fetch("deprecation").transform_values { |value| value == "" ? nil : value }
    }
  end

  def normalize_capabilities(capabilities)
    result = if capabilities.is_a?(Array)
      capabilities.dup
    else
      CAPABILITY_NAMES.filter_map { |key, name| name if capabilities.fetch(key, false) }
    end
    result << BASELINE_CAPABILITY unless result.include?(BASELINE_CAPABILITY)
    result
  end

  def normalize_workload(workload, label, display_name)
    recommended = workload.fetch("recommended").map { |text| text.gsub("GitHub Actions ", "") }
    if label == "akua-heavy-ci-v2"
      recommended[0] = "#{recommended.fetch(0)} that fit the Heavy guarantees" unless recommended.fetch(0).include?("fit the Heavy guarantees")
      recommended[1] = recommended.fetch(1).sub("the Docker profile", "Docker") + " but fit Heavy" unless recommended.fetch(1).include?("fit Heavy")
    end
    exclusions = workload.fetch("exclusions").reject { |text| text.match?(/nested virtualization|KVM|architecture-specific/i) }
    exclusions.map! do |text|
      case text
      when /workloads declaring resources above this profile; use the heavy profile/i
        "workloads whose requirements exceed the Docker guarantees; use Heavy only when all Heavy bounds fit"
      when /workloads requiring more than the stated minimum resource contract/i
        "workloads requiring more than 4 vCPU, 7168 MiB memory or 20480 MiB usable disk; use an external runner or reduce requirements"
      else
        text
      end
    end
    if label == "akua-x64-ci-v2"
      exclusions << "workloads whose requirements exceed the Standard guarantees" unless exclusions.any? { |text| text.include?("requirements exceed") }
    end
    { "recommended" => recommended, "exclusions" => exclusions }
  end

  def contains_banned_key?(value)
    case value
    when Hash
      value.any? { |key, child| BANNED_PUBLIC_KEYS.include?(key) || contains_banned_key?(child) }
    when Array
      value.any? { |child| contains_banned_key?(child) }
    else
      false
    end
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
