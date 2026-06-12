.PHONY: up down logs test lint validate fmt tf-validate

up: ## build and start the local harness
	docker compose up --build -d

down: ## stop the harness and drop volumes
	docker compose down -v

logs:
	docker compose logs -f

test: ## orchestration unit tests
	cd orchestration && python3 -m pytest

lint:
	cd orchestration && python3 -m ruff check src tests

validate: ## manifest <-> gateway route consistency
	python3 scripts/validate_routes.py

fmt:
	terraform fmt -recursive terraform

tf-validate: ## validate every terraform env without a backend
	@for env in dev staging prod; do \
		echo "== terraform/envs/$$env"; \
		terraform -chdir=terraform/envs/$$env init -backend=false -input=false >/dev/null && \
		terraform -chdir=terraform/envs/$$env validate || exit 1; \
	done
