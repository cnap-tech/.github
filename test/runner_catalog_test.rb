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

  def setup
    @root = File.expand_path("..", __dir__)
    @catalog = JSON.parse(File.read(File.join(@root, "runner-profiles.json")))
  end

  def test_public_validator_accepts_current_contract
    assert_validator_success(@root)
  end

  def test_public_validator_rejects_stale_markdown
    with_candidate do |candidate|
      markdown_path = File.join(candidate, "RUNNERS.md")
      markdown = File.read(markdown_path).sub("7168 MiB", "7169 MiB")
      File.write(markdown_path, markdown)
      assert_validator_failure(candidate, "README profile semantics drift")
    end
  end

  def test_public_validator_rejects_stale_manifest
    with_candidate do |candidate|
      manifest_path = File.join(candidate, "runner-catalog-manifest.json")
      manifest = JSON.parse(File.read(manifest_path))
      manifest.fetch("catalog").fetch("profiles").last.fetch("minimumResources")["vcpu"] = 5
      File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
      assert_validator_failure(candidate, "manifest catalog drift")
    end
  end

  def test_trusted_validator_rejects_source_overclaim_without_explicit_baseline
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("capabilities").delete("ordinary build and test tooling")
      File.write(source_file, YAML.dump(source_catalog))
      update_provenance(candidate, Digest::SHA256.file(source_file).hexdigest)
      assert_validator_failure(candidate, "source missing baseline capability", source)
    end
  end

  def test_public_validator_rejects_extra_provenance_fields
    with_candidate do |candidate|
      update_provenance(candidate, @catalog.dig("metadata", "provenance", "sha256"), "provider" => "example")
      assert_validator_failure(candidate, "provenance schema drift")
    end
  end

  def test_public_validator_rejects_forbidden_implementation_values
    with_candidate do |candidate|
      catalog = JSON.parse(File.read(File.join(candidate, "runner-profiles.json")))
      catalog.fetch("profiles").last.fetch("workload").fetch("recommended") << "Kubernetes-backed builds"
      write_catalog(candidate, catalog)
      assert_validator_failure(candidate, "runtime or provider detail in public catalog")
    end
  end

  def test_trusted_validator_rejects_fabricated_provenance
    with_source_candidate do |candidate, source|
      update_provenance(candidate, "a" * 64)
      assert_validator_failure(candidate, "canonical source hash mismatch", source)
    end
  end

  def test_trusted_validator_rejects_stale_source_semantics
    with_source_candidate do |candidate, source|
      source_file = File.join(source, SOURCE_PATH)
      source_catalog = YAML.safe_load(File.read(source_file), aliases: false)
      source_catalog.fetch("profiles").last.fetch("minimumResources")["vcpu"] = 5
      File.write(source_file, YAML.dump(source_catalog))
      update_provenance(candidate, Digest::SHA256.file(source_file).hexdigest)
      assert_validator_failure(candidate, "canonical source normalization drift", source)
    end
  end

  private

  def with_candidate
    Dir.mktmpdir do |directory|
      candidate = File.join(directory, "candidate")
      FileUtils.cp_r(@root, candidate)
      yield candidate
    end
  end

  def with_source_candidate
    with_candidate do |candidate|
      source = File.join(candidate, "source")
      source_file = File.join(source, SOURCE_PATH)
      FileUtils.mkdir_p(File.dirname(source_file))
      File.write(source_file, YAML.dump(source_fixture))
      update_provenance(candidate, Digest::SHA256.file(source_file).hexdigest)
      yield candidate, source
    end
  end

  def source_fixture
    source = Marshal.load(Marshal.dump(@catalog))
    source.fetch("metadata").delete("name")
    source.fetch("metadata").delete("documentation")
    source.fetch("metadata").delete("provenance")
    source.fetch("policy").delete("selection")
    source.fetch("profiles").each do |profile|
      profile["id"] = profile.fetch("id")
      profile["class"] = profile.fetch("class")
      profile["capabilities"] = profile.dig("capabilities", "guaranteed")
    end
    source
  end

  def update_provenance(candidate, sha256, extra = {})
    provenance = @catalog.fetch("metadata").fetch("provenance").merge("sha256" => sha256).merge(extra)
    json_path = File.join(candidate, "runner-profiles.json")
    json = JSON.parse(File.read(json_path))
    json.fetch("metadata")["provenance"] = provenance
    File.write(json_path, JSON.pretty_generate(json) + "\n")
    File.write(File.join(candidate, "runner-profiles.yaml"), YAML.dump(json))
    markdown_path = File.join(candidate, "RUNNERS.md")
    markdown = File.read(markdown_path).sub(/sha256: [0-9a-f]+/, "sha256: #{sha256}")
    File.write(markdown_path, markdown)
    manifest_path = File.join(candidate, "runner-catalog-manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    manifest["source"] = provenance
    manifest.fetch("catalog")["metadata"]["provenance"] = provenance
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
  end

  def write_catalog(candidate, catalog)
    File.write(File.join(candidate, "runner-profiles.json"), JSON.pretty_generate(catalog) + "\n")
    File.write(File.join(candidate, "runner-profiles.yaml"), YAML.dump(catalog))
    manifest_path = File.join(candidate, "runner-catalog-manifest.json")
    manifest = JSON.parse(File.read(manifest_path))
    manifest["catalog"] = catalog
    manifest["source"] = catalog.dig("metadata", "provenance")
    File.write(manifest_path, JSON.pretty_generate(manifest) + "\n")
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
