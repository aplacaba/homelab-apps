ROOTS = . grafana

.PHONY: init fmt-check validate lint install-hooks

init:
	terraform init -backend=false

fmt-check:
	terraform fmt -check -diff -recursive

validate:
	@set -e; for r in $(ROOTS); do \
	  echo "=== $$r ==="; \
	  terraform -chdir=$$r init -backend=false; \
	  terraform -chdir=$$r validate; \
	done

lint: fmt-check validate

install-hooks:
	git config core.hooksPath .githooks
	@echo "Hooks installed from .githooks/"
