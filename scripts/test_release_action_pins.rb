#!/usr/bin/env ruby

require "yaml"

repository_root = File.expand_path("..", __dir__)
release_workflow = ARGV.fetch(0, File.join(repository_root, ".github/workflows/release.yml"))
expected_ref = "maxim-lobanov/setup-xcode@ed7a3b1fda3918c0306d1b724322adc0b8cc0a90"

workflow = YAML.safe_load(
  File.read(release_workflow),
  permitted_classes: [],
  permitted_symbols: [],
  aliases: false
)
setup_xcode_refs = []

visit = lambda do |value|
  case value
  when Hash
    value.each do |key, child|
      if key.to_s == "uses" && child.is_a?(String) && child.downcase.start_with?("maxim-lobanov/setup-xcode@")
        setup_xcode_refs << child
      end
      visit.call(child)
    end
  when Array
    value.each { |child| visit.call(child) }
  end
end

visit.call(workflow)

unless setup_xcode_refs == [expected_ref]
  abort "release workflow must contain exactly one setup-xcode action pinned to #{expected_ref}"
end
