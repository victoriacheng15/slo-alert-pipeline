.PHONY: help test docker-build docker-run docker-stop docker-logs clean

CONTAINER_ENGINE ?= podman
IMAGE_NAME ?= mock-app:latest
CONTAINER_NAME ?= mock-app-local
PORT ?= 8080

help: ## Display available make targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

test: ## Run local Go unit tests
	@echo "Running unit tests in workloads/mock-app..."
	(cd workloads/mock-app && go test -v -race ./...)

docker-build: ## Build the mock-app container image
	@echo "Building container image $(IMAGE_NAME) using $(CONTAINER_ENGINE)..."
	$(CONTAINER_ENGINE) build -t $(IMAGE_NAME) -f workloads/mock-app/Dockerfile workloads/mock-app

docker-run: ## Run the container locally on port 8080
	@echo "Starting container $(CONTAINER_NAME) on port $(PORT)..."
	$(CONTAINER_ENGINE) run -d --rm \
		--name $(CONTAINER_NAME) \
		-p $(PORT):8080 \
		$(IMAGE_NAME)
	@echo "Service running at http://localhost:$(PORT)"
	@echo "Metrics endpoint: http://localhost:$(PORT)/metrics"
	@echo "Health endpoint:  http://localhost:$(PORT)/healthz"

docker-logs: ## Follow logs of the running container
	$(CONTAINER_ENGINE) logs -f $(CONTAINER_NAME)

docker-stop: ## Stop the running container
	@echo "Stopping container $(CONTAINER_NAME)..."
	-$(CONTAINER_ENGINE) stop $(CONTAINER_NAME)

clean: docker-stop ## Clean up local artifacts and containers
	@echo "Cleanup completed."
