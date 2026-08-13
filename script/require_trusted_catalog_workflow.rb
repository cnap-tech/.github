#!/usr/bin/env ruby

require "optparse"

TRUSTED_WORKFLOW = ".github/workflows/runner-catalog-trusted.yml"

options = { base_root: "." }
OptionParser.new do |parser|
  parser.on("--base-root PATH") { |path| options[:base_root] = path }
end.parse!

workflow = File.join(options.fetch(:base_root), TRUSTED_WORKFLOW)
unless File.file?(workflow)
  warn "trusted runner catalog workflow is not installed on the base commit"
  exit 1
end
