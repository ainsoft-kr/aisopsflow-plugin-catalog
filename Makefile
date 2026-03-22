SHELL := /bin/bash
COMMA := ,

CATALOG_BASE_URL ?= http://127.0.0.1:3100
CATALOG_TOKEN ?= dev-token
CATALOG_DB ?= plugin-catalog.db
CATALOG_ARTIFACT_ROOT ?= ./artifacts

PLUGIN_NAME ?= http-client
PLUGIN_VERSION ?= 0.1.0
PUBLISHER ?= aisopsflow
RUNTIME ?= node
PLATFORM ?= linux-amd64
ENTRYPOINT ?= dist/runner-entrypoint.js
CAPABILITIES ?= http.request
BUNDLE_PATH ?= /tmp/$(PLUGIN_NAME)-$(PLUGIN_VERSION).tar.gz
OUTPUT_PATH ?= plugins/official/$(PLUGIN_NAME).yaml
CHANNEL ?= stable

CORE_BASE_URL ?=
CORE_BEARER_TOKEN ?=

.PHONY: help validate server-build server-run export publish-export promote resolve smoke-test

help:
	@echo "Targets:"
	@echo "  make validate"
	@echo "  make server-build"
	@echo "  make server-run"
	@echo "  make export"
	@echo "  make publish-export"
	@echo "  make promote"
	@echo "  make resolve"
	@echo "  make smoke-test"
	@echo ""
	@echo "Common vars:"
	@echo "  CATALOG_BASE_URL=$(CATALOG_BASE_URL)"
	@echo "  CATALOG_TOKEN=$(CATALOG_TOKEN)"
	@echo "  PLUGIN_NAME=$(PLUGIN_NAME)"
	@echo "  PLUGIN_VERSION=$(PLUGIN_VERSION)"
	@echo "  PLATFORM=$(PLATFORM)"
	@echo "  CHANNEL=$(CHANNEL)"
	@echo "  BUNDLE_PATH=$(BUNDLE_PATH)"

validate:
	ruby scripts/validate-catalog.rb

server-build:
	cd server && stack build --fast

server-run:
	cd server && \
	PLUGIN_CATALOG_BASE_URL="$(CATALOG_BASE_URL)" \
	PLUGIN_CATALOG_UPLOAD_TOKEN="$(CATALOG_TOKEN)" \
	PLUGIN_CATALOG_DB="$(CATALOG_DB)" \
	PLUGIN_CATALOG_ARTIFACT_ROOT="$(CATALOG_ARTIFACT_ROOT)" \
	stack exec aisopsflow-plugin-catalog-server

export:
	bash scripts/export-catalog-manifest.sh \
		"$(CATALOG_BASE_URL)" \
		"$(PLUGIN_NAME)" \
		"$(PLUGIN_VERSION)" \
		"$(OUTPUT_PATH)"

publish-export:
	bash scripts/publish-and-export.sh \
		"$(CATALOG_BASE_URL)" \
		"$(CATALOG_TOKEN)" \
		"$(PLUGIN_NAME)" \
		"$(PLUGIN_VERSION)" \
		"$(PUBLISHER)" \
		"$(RUNTIME)" \
		"$(PLATFORM)" \
		"$(ENTRYPOINT)" \
		"$(CAPABILITIES)" \
		"$(BUNDLE_PATH)" \
		"$(OUTPUT_PATH)"

promote:
	curl --fail --silent --show-error \
		-X POST \
		-H "Content-Type: application/json" \
		-d '{"channel":"$(CHANNEL)"}' \
		"$(CATALOG_BASE_URL)/api/plugins/$(PLUGIN_NAME)/$(PLUGIN_VERSION)/promote"
	@echo

resolve:
	curl --fail --silent --show-error \
		"$(CATALOG_BASE_URL)/api/resolve/$(firstword $(subst $(COMMA), ,$(CAPABILITIES)))?platform=$(PLATFORM)&channel=$(CHANNEL)"
	@echo

smoke-test:
	bash scripts/smoke-test.sh \
		"$(CATALOG_BASE_URL)" \
		"$(CATALOG_TOKEN)" \
		"$(PLUGIN_NAME)" \
		"$(PLUGIN_VERSION)" \
		"$(PUBLISHER)" \
		"$(RUNTIME)" \
		"$(PLATFORM)" \
		"$(ENTRYPOINT)" \
		"$(CAPABILITIES)" \
		"$(BUNDLE_PATH)" \
		"$(CORE_BASE_URL)" \
		"$(CORE_BEARER_TOKEN)"
