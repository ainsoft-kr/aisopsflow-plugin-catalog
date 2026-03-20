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
    when "integer" then value.is_a?(Integer)
    when "boolean" then value == true || value == false
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

def sibling_sdk_root
  File.expand_path("../../aisopsflow-plugin-sdk", __dir__)
end

def official_source_path(name)
  candidates = [name]
  candidates << name.sub(/\Achannel-/, "") if name.start_with?("channel-")
  candidates.each do |candidate|
    candidate_paths = [
      File.join(sibling_sdk_root, "examples/node", candidate, "src/runner-entrypoint.ts"),
      File.join(sibling_sdk_root, "examples/node", candidate, "src/index.ts"),
      File.join(sibling_sdk_root, "examples/node", candidate, "src/index.js")
    ]
    found = candidate_paths.find { |candidate_path| File.file?(candidate_path) }
    return found if found
  end
  File.join(sibling_sdk_root, "examples/node", name, "src/runner-entrypoint.ts")
end

def build_compatibility_index(files)
  files.each_with_object({}) do |path, acc|
    doc = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
    matrix = doc.fetch("compatibility_matrix", {})
    api = matrix["runner_plugin_api"]
    next unless api.is_a?(String) && !api.empty?

    acc[api] = path
  end
end

def validate_policy!(path, manifest, compatibility_index, failures, warnings)
  name = manifest.fetch("name")
  image = manifest.fetch("image")
  verification = manifest["verification"].is_a?(Hash) ? manifest["verification"] : {}
  compatibility = manifest.fetch("compatibility")
  capabilities = manifest.fetch("capabilities")

  unless image.match?(/(:[A-Za-z0-9._-]+|@sha256:[a-fA-F0-9]{64})$/)
    failures << "#{path}: image must use a tag or digest reference"
  end

  runner_plugin_api = compatibility["runner_plugin_api"]
  unless compatibility_index.key?(runner_plugin_api)
    failures << "#{path}: missing compatibility baseline for runner_plugin_api=#{runner_plugin_api}"
  end

  if manifest["publisher"] == "aisopsflow" && verification["status"] == "official"
    source_path = official_source_path(name)
    if !File.file?(source_path)
      failures << "#{path}: official plugin source not found at #{source_path}"
    else
      source_text = File.read(source_path)
      unless source_text.include?("startStdioJsonRuntime") || source_text.include?("requireInternalAuthJson")
        failures << "#{path}: official plugin source does not expose a recognized runtime entrypoint"
      end
    end
  end

  signed_image = verification["signed_image"]
  signature_ref = verification["signature_ref"]
  if verification["status"] == "official"
    if signed_image.nil? || signature_ref.nil?
      failures << "#{path}: signed image evidence must declare signed_image and signature_ref"
    elsif signed_image["verified"] != true
      failures << "#{path}: signed image evidence must be marked verified"
    elsif !File.file?(signature_artifact_path(signature_ref))
      failures << "#{path}: signature evidence not found at #{signature_ref}"
    end

    vulnerabilities = verification["vulnerabilities"]
    if !vulnerabilities.is_a?(Hash)
      failures << "#{path}: vulnerability scan result must be declared"
    elsif !File.file?(artifact_path(vulnerabilities["report_ref"]))
      failures << "#{path}: vulnerability report not found at #{vulnerabilities['report_ref']}"
    elsif vulnerabilities["critical"].to_i > 0
      failures << "#{path}: critical vulnerabilities declared: #{vulnerabilities['critical']}"
    end
  end
end

def artifact_path(ref)
  File.expand_path(ref, Dir.pwd)
end

def signature_artifact_path(ref)
  artifact_path(ref)
end

manifest_files = Dir.glob("plugins/**/*.yaml")
abort("no plugin manifests found") if manifest_files.empty?

compatibility_index = build_compatibility_index(compatibility_files)
failures = []
warnings = []

manifest_files.each do |path|
  doc = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)
  begin
    validate_node!(doc, schema, path)
    validate_policy!(path, doc, compatibility_index, failures, warnings)
  rescue SystemExit => e
    failures << e.message
  end
end

warnings.each do |warning|
  warn("warning: #{warning}")
end

abort(failures.join("\n")) unless failures.empty?
