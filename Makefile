# Front door for the day-to-day commands. `make help` lists them.
#
#   make audit   read-only "am I in sync?" check (scripts/audit.sh)
#   make lint    what CI runs: yamllint + ansible-lint
#   make test    bats tests under tests/

.PHONY: help audit lint test

help:
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | sed 's/:.*## /\t/' | sort

audit: ## Compare this Mac against the playbook config (read-only). Args: AUDIT_ARGS="--section brew --strict"
	scripts/audit.sh $(AUDIT_ARGS)

lint: ## Run the CI linters (yamllint + ansible-lint)
	yamllint .
	ansible-lint

test: ## Run the bats test suite
	bats tests/
