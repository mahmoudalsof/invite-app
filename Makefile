# Local development. Postgres runs in Docker Compose; the Go service runs on the host.
# Tools are run at pinned versions with `go run`, so nothing needs installing globally.

GOOSE_VERSION        := v3.30.1
SQLC_VERSION         := v1.31.1

POSTGRES_PORT ?= 5432
DATABASE_URL  ?= postgres://invite:invite@localhost:$(POSTGRES_PORT)/invite?sslmode=disable
export DATABASE_URL

MIGRATIONS := db/migrations
GOOSE      := cd server && go run github.com/pressly/goose/v3/cmd/goose@$(GOOSE_VERSION) -dir $(MIGRATIONS) postgres "$(DATABASE_URL)"
SQLC       := cd server && go run github.com/sqlc-dev/sqlc/cmd/sqlc@$(SQLC_VERSION)

.PHONY: help db-up db-down db-reset migrate migrate-down migrate-status migrate-new migrate-check \
        sqlc generate test run build

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

db-up: ## Start Postgres 18 and wait until it is ready
	docker compose up -d --wait postgres

db-down: ## Stop Postgres (keeps data)
	docker compose down

db-reset: ## Stop Postgres and delete its data volume
	docker compose down -v

migrate: ## Apply all migrations
	$(GOOSE) up

migrate-down: ## Roll back the last migration
	$(GOOSE) down

migrate-status: ## Show migration status
	$(GOOSE) status

migrate-new: ## Create a migration: make migrate-new name=add_things
	@test -n "$(name)" || (echo "usage: make migrate-new name=add_things" && exit 1)
	$(GOOSE) create $(name) sql

migrate-check: ## Round-trip every migration: up, down to zero, up again
	$(GOOSE) up
	$(GOOSE) reset
	$(GOOSE) up

sqlc: ## Generate Go query code from db/queries (needs server/sqlc.yaml)
	$(SQLC) generate

generate: sqlc ## Run all code generation (sqlc, then go generate for oapi-codegen)
	cd server && go generate ./...

test: ## Run Go tests (needs `make db-up`)
	cd server && go test ./...

run: ## Run the server on the host
	cd server && go run ./cmd/server

build: ## Build the server binary into server/bin/
	cd server && go build -o bin/server ./cmd/server
