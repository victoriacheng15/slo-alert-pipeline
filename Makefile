.PHONY: help test docker-build docker-run docker-stop docker-logs clean bootstrap port-forward-prometheus port-forward-alertmanager port-forward-grafana logs-webhook-sink teardown

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

bootstrap: ## Idempotently provision namespaces, deploy kube-prometheus-stack, and apply base manifests
	@bash scripts/bootstrap.sh

port-forward-prometheus: ## Forward Prometheus UI to localhost:9090
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

port-forward-alertmanager: ## Forward Alertmanager UI to localhost:9093
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-alertmanager 9093:9093

port-forward-grafana: ## Forward Grafana UI to localhost:3000 (admin/admin)
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

logs-webhook-sink: ## Follow live incoming alert payloads in the webhook sink
	kubectl logs -n monitoring -l app=webhook-sink -f

teardown: ## Remove base observability stack and tenant namespaces
	@echo "Uninstalling kube-prometheus-stack..."
	-helm uninstall kube-prometheus-stack -n monitoring
	@echo "Deleting tenant and monitoring namespaces..."
	-kubectl delete namespace tenant-checkout tenant-inventory monitoring

clean: docker-stop ## Clean up local artifacts and containers
	@echo "Cleanup completed."
