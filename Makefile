CONTAINER_ENGINE ?= podman
IMAGE_NAME ?= mock-app:latest
CONTAINER_NAME ?= mock-app-local
PORT ?= 8080

.PHONY: help

help: ## Display available make targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ==============================================================================
# Toolchain & Validation
# ==============================================================================
.PHONY: tools-install lint-yaml lint-k8s lint test-rules test validate

tools-install: ## Install required CLI tools using mise
	mise install

lint-yaml: ## Validate YAML formatting and syntax with yamllint
	@echo "Running yamllint..."
	mise exec -- yamllint -c .yamllint.yaml manifests tests/promtool

lint-k8s: ## Validate Kubernetes resource schemas with kubeconform
	@echo "Running kubeconform on manifests..."
	find manifests/ -name "*.yaml" ! -name "values*.yaml" | xargs mise exec -- kubeconform -summary -ignore-missing-schemas

lint: lint-yaml lint-k8s ## Run all static linters

test-rules: ## Run promtool unit tests against recording and alerting rules
	@echo "Testing PromQL rules using promtool..."
	mise exec -- promtool test rules tests/promtool/recording-rules-test.yaml
	mise exec -- promtool test rules tests/promtool/burn-rates-test.yaml

test: test-rules ## Run Go unit tests and PromQL rule tests
	@echo "Running unit tests in workloads/mock-app..."
	(cd workloads/mock-app && go test -v -race ./...)

validate: lint test ## Run complete local validation suite (lint and test)

# ==============================================================================
# Workload Container Management
# ==============================================================================
.PHONY: docker-build docker-run docker-logs docker-stop clean

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

# ==============================================================================
# Cluster Operations & Observability
# ==============================================================================
.PHONY: bootstrap port-forward logs-webhook-sink teardown

bootstrap: ## Idempotently provision namespaces, deploy kube-prometheus-stack, and apply base manifests
	@bash scripts/bootstrap.sh

port-forward: ## Forward Prometheus (9090), Alertmanager (9093), and Grafana (3000)
	@echo "Forwarding observability UIs (Press Ctrl+C to stop):"
	@echo "  - Prometheus:   http://localhost:9090"
	@echo "  - Alertmanager: http://localhost:9093"
	@echo "  - Grafana:      http://localhost:3000 (admin/admin)"
	@bash -c "trap 'kill \$$(jobs -p) 2>/dev/null' EXIT INT TERM; \
		kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090 >/dev/null 2>&1 & \
		kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093 >/dev/null 2>&1 & \
		kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80 >/dev/null 2>&1 & \
		wait"

logs-webhook-sink: ## Follow live incoming alert payloads in the webhook sink
	kubectl logs -n monitoring -l app=webhook-sink -f

teardown: ## Remove base observability stack and tenant namespaces
	@echo "Uninstalling kube-prometheus-stack..."
	-helm uninstall kube-prometheus-stack -n monitoring
	@echo "Deleting tenant and monitoring namespaces..."
	-kubectl delete namespace tenant-checkout tenant-inventory monitoring
