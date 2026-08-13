#!/usr/bin/env ruby

require "optparse"

class RunnerCatalogLifecycleError < StandardError; end

class RunnerCatalogLifecycle
  FILES = %w[RUNNERS.md runner-catalog-manifest.json runner-profiles.json runner-profiles.yaml].freeze

  def initialize(previous_root:, current_root:)
    @previous_root = File.expand_path(previous_root)
    @current_root = File.expand_path(current_root)
  end

  def action
    previous = state(@previous_root)
    current = state(@current_root)
    case [previous, current]
    when %w[absent absent], %w[absent complete], %w[complete complete]
      previous == "absent" && current == "absent" ? "skip" : "validate"
    when ["partial", "absent"], ["partial", "partial"], ["partial", "complete"]
      fail_with("previous catalog is partial")
    when ["absent", "partial"]
      fail_with("current catalog is partial")
    when ["complete", "absent"], ["complete", "partial"]
      fail_with("published catalog cannot be deleted or partial")
    else
      fail_with("unsupported catalog lifecycle transition")
    end
  end

  private

  def state(root)
    present = FILES.count { |path| File.file?(File.join(root, path)) }
    return "absent" if present.zero?
    return "complete" if present == FILES.length

    "partial"
  end

  def fail_with(message)
    raise RunnerCatalogLifecycleError, message
  end
end

options = {}
OptionParser.new do |parser|
  parser.on("--previous-root PATH") { |path| options[:previous_root] = path }
  parser.on("--current-root PATH") { |path| options[:current_root] = path }
end.parse!

begin
  abort "missing lifecycle roots" unless options.keys.sort == %i[current_root previous_root]
  puts RunnerCatalogLifecycle.new(**options).action
rescue RunnerCatalogLifecycleError => error
  warn error.message
  exit 1
end
