require "json"
require "minitest/autorun"
require "yaml"

class RunnerCatalogTest < Minitest::Test
  def setup
    @catalog = JSON.parse(File.read("runner-profiles.json"))
    @yaml_catalog = YAML.safe_load(File.read("runner-profiles.yaml"), aliases: false)
    @profiles = @catalog.fetch("profiles")
  end

  def test_machine_catalogs_are_the_same_contract
    assert_equal @catalog, @yaml_catalog
    assert_equal "akua-ci-catalog", @catalog.dig("metadata", "name")
  end

  def test_capabilities_are_compositional_for_docker_and_heavy
    %w[akua-docker-ci-v2 akua-heavy-ci-v2].each do |label|
      capabilities = profile(label).dig("capabilities", "guaranteed")
      assert_includes capabilities, "ordinary build and test tooling"
      assert_includes capabilities, "Docker"
    end
  end

  def test_heavy_is_not_a_match_above_its_guaranteed_resources
    refute safe_match?(profile("akua-heavy-ci-v2"), { "vcpu" => 5, "memoryMiB" => 7168, "usableDiskMiB" => 20480 }, ["Docker"])
    assert_equal "external-runner-or-reduce-requirements", @catalog.dig("policy", "selection", "noMatch")
  end

  def test_capacity_is_shared_and_exactly_four
    assert_equal "organization", @catalog.dig("capacity", "scope")
    assert_equal "shared", @catalog.dig("capacity", "allocation")
    assert_equal 4, @catalog.dig("capacity", "maxConcurrentJobs")
  end

  private

  def profile(label)
    @profiles.find { |candidate| candidate.fetch("label") == label }
  end

  def safe_match?(candidate, resources, capabilities)
    guaranteed_resources = candidate.fetch("minimumResources")
    guaranteed_capabilities = candidate.dig("capabilities", "guaranteed")
    resources.all? { |key, value| value <= guaranteed_resources.fetch(key) } &&
      capabilities.all? { |capability| guaranteed_capabilities.include?(capability) }
  end
end
