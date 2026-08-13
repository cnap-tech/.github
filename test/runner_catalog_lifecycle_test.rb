require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class RunnerCatalogLifecycleTest < Minitest::Test
  SCRIPT = File.expand_path("../script/check_runner_catalog_lifecycle.rb", __dir__)
  FILES = %w[RUNNERS.md runner-catalog-manifest.json runner-profiles.json runner-profiles.yaml].freeze

  def test_bootstrap_without_catalog_skips_source_validation
    with_roots do |previous, current|
      assert_action(previous, current, "skip")
    end
  end

  def test_partial_catalog_fails_closed_before_publication
    with_roots do |previous, current|
      File.write(File.join(current, "runner-profiles.json"), "{}")
      assert_failure(previous, current, "current catalog is partial")
    end
  end

  def test_complete_publication_is_validated
    with_roots do |previous, current|
      write_catalog(current)
      assert_action(previous, current, "validate")
    end
  end

  def test_published_catalog_remains_validated
    with_roots do |previous, current|
      write_catalog(previous)
      write_catalog(current)
      assert_action(previous, current, "validate")
    end
  end

  def test_published_catalog_cannot_be_fully_deleted
    with_roots do |previous, current|
      write_catalog(previous)
      assert_failure(previous, current, "published catalog cannot be deleted or partial")
    end
  end

  def test_published_catalog_cannot_become_partial
    with_roots do |previous, current|
      write_catalog(previous)
      write_catalog(current)
      File.delete(File.join(current, "RUNNERS.md"))
      assert_failure(previous, current, "published catalog cannot be deleted or partial")
    end
  end

  private

  def with_roots
    Dir.mktmpdir do |directory|
      previous = File.join(directory, "previous")
      current = File.join(directory, "current")
      FileUtils.mkdir_p(previous)
      FileUtils.mkdir_p(current)
      yield previous, current
    end
  end

  def write_catalog(root)
    FILES.each { |path| File.write(File.join(root, path), "catalog\n") }
  end

  def assert_action(previous, current, expected)
    stdout, stderr, status = execute_lifecycle(previous, current)
    assert status.success?, stderr
    assert_equal expected, stdout.strip
  end

  def assert_failure(previous, current, message)
    stdout, stderr, status = execute_lifecycle(previous, current)
    refute status.success?, stdout
    assert_includes stderr, message
  end

  def execute_lifecycle(previous, current)
    Open3.capture3(
      RbConfig.ruby,
      SCRIPT,
      "--previous-root", previous,
      "--current-root", current
    )
  end
end
