require "digest"
require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class RunnerCatalogTrustBoundaryTest < Minitest::Test
  SCRIPT = File.expand_path("../script/check_runner_catalog_trust_boundary.rb", __dir__)
  TRUST_FILES = [
    ".github/workflows/runner-catalog-trusted.yml",
    "script/check_runner_catalog_trust_boundary.rb",
    "script/check_runner_catalog_lifecycle.rb",
    "script/validate_runner_catalog.rb"
  ].freeze
  CATALOG_FILES = %w[RUNNERS.md runner-catalog-manifest.json runner-profiles.json runner-profiles.yaml].freeze
  WORKFLOW_PATHS = [
    *CATALOG_FILES,
    "script/validate_runner_catalog.rb",
    "script/check_runner_catalog_lifecycle.rb",
    "script/check_runner_catalog_trust_boundary.rb",
    ".github/workflows/runner-catalog.yml",
    ".github/workflows/runner-catalog-trusted.yml"
  ].freeze

  def test_current_trust_root_accepts_itself
    stdout, stderr, status = execute(Dir.pwd, Dir.pwd)
    assert status.success?, stderr
    assert_equal "trusted", stdout.strip
  end

  def test_unchanged_fixture_trust_root_passes
    with_roots do |trusted, candidate|
      write_trust_root(trusted)
      FileUtils.cp_r("#{trusted}/.", candidate)
      assert_success(trusted, candidate)
    end
  end

  def test_weakened_fixture_workflow_fails_semantically
    with_roots do |trusted, candidate|
      write_trust_root(trusted)
      FileUtils.cp_r("#{trusted}/.", candidate)
      workflow_path = File.join(candidate, ".github/workflows/runner-catalog-trusted.yml")
      workflow = YAML.safe_load(File.read(workflow_path), aliases: false)
      workflow.fetch("jobs").fetch("verify").fetch("steps").delete_if { |step| step.fetch("name", "") == "Verify trusted boundary" }
      File.write(workflow_path, YAML.dump(workflow))
      assert_failure(trusted, candidate, "trusted workflow semantic drift")
    end
  end

  def test_modified_fixture_verifier_fails_integrity_check
    with_roots do |trusted, candidate|
      write_trust_root(trusted)
      FileUtils.cp_r("#{trusted}/.", candidate)
      File.open(File.join(candidate, "script/validate_runner_catalog.rb"), "a") { |file| file.puts("changed") }
      assert_failure(trusted, candidate, "trusted boundary file modified: script/validate_runner_catalog.rb")
    end
  end

  def test_deleted_fixture_trust_workflow_fails_integrity_check
    with_roots do |trusted, candidate|
      write_trust_root(trusted)
      FileUtils.cp_r("#{trusted}/.", candidate)
      File.delete(File.join(candidate, ".github/workflows/runner-catalog-trusted.yml"))
      assert_failure(trusted, candidate, "trusted workflow missing")
    end
  end

  private

  def workflow
    {
      true => {
        "pull_request_target" => { "paths" => WORKFLOW_PATHS },
        "push" => { "branches" => ["main"], "paths" => WORKFLOW_PATHS + ["test/runner_catalog_test.rb", "test/runner_catalog_lifecycle_test.rb", "test/runner_catalog_trust_boundary_test.rb"] }
      },
      "jobs" => {
        "verify" => {
          "if" => "github.event_name == 'pull_request_target'",
          "steps" => [
            { "name" => "Verify trusted boundary", "run" => "ruby .trusted/script/check_runner_catalog_trust_boundary.rb --trusted-root .trusted --candidate-root .candidate" },
            { "name" => "Exercise base-owned infrastructure", "run" => "cd .trusted && ruby test/runner_catalog_test.rb && ruby test/runner_catalog_lifecycle_test.rb && ruby test/runner_catalog_trust_boundary_test.rb" },
            { "name" => "Checkout canonical runner source", "uses" => "actions/checkout@v6", "with" => { "repository" => "akua-dev/gitops", "ssh-key" => "${{ secrets.GITOPS_READ_SSH_KEY }}" } }
          ]
        }
      }
    }
  end

  def with_roots
    Dir.mktmpdir do |directory|
      trusted = File.join(directory, "trusted")
      candidate = File.join(directory, "candidate")
      FileUtils.mkdir_p(trusted)
      FileUtils.mkdir_p(candidate)
      yield trusted, candidate
    end
  end

  def write_trust_root(root)
    FileUtils.mkdir_p(File.join(root, ".github/workflows"))
    FileUtils.mkdir_p(File.join(root, "script"))
    File.write(File.join(root, ".github/workflows/runner-catalog-trusted.yml"), YAML.dump(workflow))
    TRUST_FILES.drop(1).each { |path| File.write(File.join(root, path), "base-owned\n") }
  end

  def execute(trusted, candidate)
    Open3.capture3(RbConfig.ruby, SCRIPT, "--trusted-root", trusted, "--candidate-root", candidate)
  end

  def assert_success(trusted, candidate)
    stdout, stderr, status = execute(trusted, candidate)
    assert status.success?, stderr
    assert_equal "trusted", stdout.strip
  end

  def assert_failure(trusted, candidate, message)
    stdout, stderr, status = execute(trusted, candidate)
    refute status.success?, stdout
    assert_includes stderr, message
  end
end
