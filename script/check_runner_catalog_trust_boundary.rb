#!/usr/bin/env ruby

require "digest"
require "optparse"
require "yaml"

class RunnerCatalogTrustBoundaryError < StandardError; end

class RunnerCatalogTrustBoundary
  TRUST_FILES = [
    ".github/workflows/runner-catalog-trusted.yml",
    "script/check_runner_catalog_trust_boundary.rb",
    "script/check_runner_catalog_lifecycle.rb",
    "script/validate_runner_catalog.rb"
  ].freeze
  CATALOG_FILES = %w[RUNNERS.md runner-catalog-manifest.json runner-profiles.json runner-profiles.yaml].freeze
  TRUSTED_WORKFLOW_PATHS = [
    *CATALOG_FILES,
    "script/validate_runner_catalog.rb",
    "script/check_runner_catalog_lifecycle.rb",
    "script/check_runner_catalog_trust_boundary.rb",
    ".github/workflows/runner-catalog.yml",
    ".github/workflows/runner-catalog-trusted.yml"
  ].freeze

  def initialize(trusted_root:, candidate_root:)
    @trusted_root = File.expand_path(trusted_root)
    @candidate_root = File.expand_path(candidate_root)
  end

  def validate!
    trusted_workflow = parse_workflow(@trusted_root)
    candidate_workflow = parse_workflow(@candidate_root)
    validate_workflow_model!(trusted_workflow)
    fail_with("trusted workflow semantic drift") unless workflow_model(trusted_workflow) == workflow_model(candidate_workflow)
    TRUST_FILES.each do |path|
      trusted = File.join(@trusted_root, path)
      candidate = File.join(@candidate_root, path)
      fail_with("trusted boundary file missing: #{path}") unless File.file?(trusted) && File.file?(candidate)
      fail_with("trusted boundary file modified: #{path}") unless Digest::SHA256.file(trusted).hexdigest == Digest::SHA256.file(candidate).hexdigest
    end
    true
  rescue KeyError, Psych::Exception, Errno::ENOENT => error
    raise RunnerCatalogTrustBoundaryError, error.message
  end

  private

  def parse_workflow(root)
    path = File.join(root, TRUST_FILES.first)
    fail_with("trusted workflow missing") unless File.file?(path)
    YAML.safe_load(File.read(path), aliases: false)
  end

  def workflow_model(workflow)
    trigger = workflow.fetch(true)
    verify = workflow.fetch("jobs").fetch("verify")
    {
      "pullRequestTargetPaths" => trigger.fetch("pull_request_target").fetch("paths").sort,
      "pushPaths" => trigger.fetch("push").fetch("paths").sort,
      "verifyIf" => verify.fetch("if"),
      "verifySteps" => verify.fetch("steps").map { |step| step_model(step) }
    }
  end

  def step_model(step)
    {
      "name" => step.fetch("name", nil),
      "uses" => step.fetch("uses", nil),
      "run" => step.fetch("run", nil),
      "if" => step.fetch("if", nil),
      "with" => step.fetch("with", {}).slice("ref", "path", "repository", "token", "ssh-key", "persist-credentials", "sparse-checkout", "sparse-checkout-cone-mode")
    }
  end

  def validate_workflow_model!(workflow)
    model = workflow_model(workflow)
    expected_paths = TRUSTED_WORKFLOW_PATHS.sort
    fail_with("trusted workflow catalog paths drift") unless model.fetch("pullRequestTargetPaths") == expected_paths
    fail_with("trusted workflow push paths drift") unless model.fetch("pushPaths") == (expected_paths + ["test/runner_catalog_lifecycle_test.rb", "test/runner_catalog_test.rb", "test/runner_catalog_trust_boundary_test.rb"]).sort
    fail_with("trusted workflow verify trigger drift") unless model.fetch("verifyIf") == "github.event_name == 'pull_request_target'"
    steps = workflow.fetch("jobs").fetch("verify").fetch("steps")
    boundary_index = steps.index { |step| step.fetch("name", "") == "Verify trusted boundary" }
    tests_index = steps.index { |step| step.fetch("name", "") == "Exercise base-owned infrastructure" }
    source_index = steps.index { |step| step.fetch("with", {}).fetch("repository", nil) == "akua-dev/gitops" }
    fail_with("trusted workflow boundary step missing") unless boundary_index
    fail_with("base-owned infrastructure tests missing") unless tests_index
    fail_with("trusted source checkout missing") unless source_index
    fail_with("trusted workflow boundary ordering drift") unless boundary_index < source_index && tests_index < source_index
    fail_with("trusted boundary must use base-owned files") unless steps.fetch(boundary_index).fetch("run") == "ruby .trusted/script/check_runner_catalog_trust_boundary.rb --trusted-root .trusted --candidate-root .candidate"
    fail_with("base-owned tests must run from trusted root") unless steps.fetch(tests_index).fetch("run") == "cd .trusted && ruby test/runner_catalog_test.rb && ruby test/runner_catalog_lifecycle_test.rb && ruby test/runner_catalog_trust_boundary_test.rb"
    source_auth = steps.fetch(source_index).fetch("with", {})
    fail_with("trusted source must use the read-only deploy key") unless source_auth.fetch("ssh-key", nil) == "${{ secrets.GITOPS_READ_SSH_KEY }}" && !source_auth.key?("token")
  end

  def fail_with(message)
    raise RunnerCatalogTrustBoundaryError, message
  end
end

options = {}
OptionParser.new do |parser|
  parser.on("--trusted-root PATH") { |path| options[:trusted_root] = path }
  parser.on("--candidate-root PATH") { |path| options[:candidate_root] = path }
end.parse!

begin
  abort "missing trust-boundary roots" unless options.keys.sort == %i[candidate_root trusted_root]
  RunnerCatalogTrustBoundary.new(**options).validate!
  puts "trusted"
rescue RunnerCatalogTrustBoundaryError => error
  warn error.message
  exit 1
end
