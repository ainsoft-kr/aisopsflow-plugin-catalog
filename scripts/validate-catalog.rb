#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

compatibility_files = Dir.glob("compatibility/*.yaml")
abort("missing compatibility baseline") if compatibility_files.empty?

schema_path = "schemas/plugin-manifest-v1.yaml"
abort("missing manifest schema") unless File.file?(schema_path)
schema = YAML.safe_load(File.read(schema_path), permitted_classes: [], permitted_symbols: [], aliases: false)

def assert_type!(value, expected, path)
  ok =
    case expected
    when "object" then value.is_a?(Hash)
    when "array" then value.is_a?(Array)
    when "string" then value.is_a?(String)
    else false
    end
  abort("type mismatch at #{path}: expected #{expected}") unless ok
end

def validate_node!(node, schema, path)
  assert_type!(node, schema.fetch("type"), path) if schema["type"]

  if schema["const"]
    abort("invalid value at #{path}: expected #{schema['const']}") unless node == schema["const"]
  end

  if schema["min_length"]
    abort("value too short at #{path}") unless node.length >= schema["min_length"]
  end

  if schema["pattern"]
    abort("pattern mismatch at #{path}") unless Regexp.new(schema["pattern"]).match?(node)
  end

  if schema["type"] == "object"
    required = schema.fetch("required", [])
    missing = required.reject { |key| node.key?(key) }
    abort("missing keys at #{path}: #{missing.join(', ')}") unless missing.empty?

    properties = schema.fetch("properties", {})
    properties.each do |key, child_schema|
      next unless node.key?(key)

      validate_node!(node[key], child_schema, "#{path}.#{key}")
    end
  end

  if schema["type"] == "array"
    if schema["min_items"]
      abort("not enough items at #{path}") unless node.length >= schema["min_items"]
    end

    if schema["items"]
      node.each_with_index do |item, index|
        validate_node!(item, schema["items"], "#{path}[#{index}]")
      end
    end
  end
end

manifest_files = Dir.glob("plugins/**/*.yaml")
abort("no plugin manifests found") if manifest_files.empty?

manifest_files.each do |path|
  doc = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  validate_node!(doc, schema, path)
end
