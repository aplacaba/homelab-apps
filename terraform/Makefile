.PHONY: init fmt-check validate lint install-hooks

init:
	terraform init

fmt-check:
	terraform fmt -check -diff -recursive

validate:
	terraform validate

lint: fmt-check validate

install-hooks:
	git config core.hooksPath .githooks
	@echo "Hooks installed from .githooks/"
