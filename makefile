# v3.0.0
.SILENT: image release docker-run validate
.PHONY: image validate build

ifneq (,$(wildcard ./config.ini))
include config.ini
endif

DOCKER_CONTEXT ?= .
DOCKERFILE     ?= Dockerfile
ENV_FILE       ?= env

# defining CONTAINER_IMAGE
IMAGE_NAME     := $(shell git remote get-url origin 2>/dev/null | sed -ne \
			       's,\(http[s]:\/\/\|git@\)[^:/]*[:/]\(.*\)\.git$$,\2,p')
ifeq ($(strip $(IMAGE_NAME)),)
$(error 'IMAGE_NAME is undefined.  Please clone a remote git repo.')
endif

VERSION  := $(shell cat $(CURDIR)/.version 2>/dev/null || git describe --tags --dirty --match="v*" 2>/dev/null)
ifndef VERSION
VERSION  := $(shell git rev-parse --short HEAD 2>/dev/null)
endif

ifdef IMAGE_HUB
CONTAINER_IMAGE   := $(IMAGE_HUB)/$(IMAGE_NAME):$(VERSION)
else
CONTAINER_IMAGE   := $(IMAGE_NAME):$(VERSION)
endif

# -----------------------------------------------------------------------------
BUILD_IMAGE ?= true
ifdef BUILD_ARGS
DOCKER_BUILD_ARGS := $(shell echo ' $(BUILD_ARGS)' | sed 's,\ , --build-arg ,g') -t $(CONTAINER_IMAGE)
else
DOCKER_BUILD_ARGS := -t $(CONTAINER_IMAGE)
endif

image: $(DOCKERFILE) ## generates the Docker image using a proper build command
ifeq ($(BUILD_IMAGE), true)
	$(info Building image $(CONTAINER_IMAGE))
	docker image build -f $(DOCKERFILE) $(DOCKER_BUILD_ARGS) $(DOCKER_CONTEXT)
else
	$(info Using existing image $(CONTAINER_IMAGE))
endif

release: image ## build and pushes the Docker image to the image registry
ifeq ($(BUILD_IMAGE), true)
	docker image push $(CONTAINER_IMAGE)
endif

# -----------------------------------------------------------------------------
APPLICATION ?= $(shell basename $(CURDIR))

ENV_FLAGS   := -e APPLICATION=$(APPLICATION)
ifneq (,$(wildcard $(ENV_FILE)))
	ENV_FLAGS += --env-file=$(ENV_FILE)
endif

docker-run: image ## runs the generated Docker image (with RUN_FLAGS, if specified)
	docker run --rm --name $(APPLICATION)-container $(ENV_FLAGS) $(RUN_FLAGS) $(CONTAINER_IMAGE) # TODO ifndef RUN_FLAGS

shell: image ## runs Docker image interactively with shell instead of entrypoint
	docker run --rm --name $(APPLICATION)-container -it --entrypoint /bin/sh $(ENV_FLAGS) $(CONTAINER_IMAGE)

# -----------------------------------------------------------------------------
NAMESPACE         ?= $(APPLICATION)
APPLICATION_PATH  ?= /

YAML_DIR       := ./yaml
YAML_BUILD_DIR := ./.build
YAML_FILES     := $(shell find $(YAML_DIR) -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sed 's,$(YAML_DIR)/,,g')

AVAILABLE_VARS := CLUSTER NAMESPACE APPLICATION
AVAILABLE_VARS += CONTAINER_IMAGE CONTAINER_PORT
AVAILABLE_VARS += APPLICATION_URL APPLICATION_PATH

SHELL_EXPORT   := $(foreach v,$(AVAILABLE_VARS),$(v)='$(firstword $($(v)))' )

validate:
# TODO talvez pegar o cluster de branch
ifndef CLUSTER
$(error CLUSTER is undefined! Impossible to deploy to Kubernetes)
endif
# TODO talvez pegar o namespace do dir acima da imagem
ifndef CONTAINER_PORT
$(error CONTAINER_PORT is undefined.)
endif
ifndef APPLICATION_URL
$(error APPLICATION_URL is undefined.)
endif

$(YAML_BUILD_DIR): validate
	@mkdir -p $(YAML_BUILD_DIR)

build: $(YAML_BUILD_DIR)
	@echo 'YAML available vars: $(AVAILABLE_VARS)'
	@for file in $(YAML_FILES); do \
		mkdir -p `dirname "$(YAML_BUILD_DIR)/$$file"` ; \
		$(SHELL_EXPORT) envsubst <$(YAML_DIR)/$$file >$(YAML_BUILD_DIR)/$$file ;\
	done
	@cat $(YAML_BUILD_DIR)/.dump.yaml

deploy: build
	@kubectx $(CLUSTER)
ifneq (,$(wildcard $(ENV_FILE)))
	@kubectl create configmap $(APPLICATION)-config -o yaml --dry-run \
		-n $(NAMESPACE) \
		--from-env-file=$(ENV_FILE) \
	| kubectl apply -f -
endif
	@kubectl apply -f $(YAML_BUILD_DIR)


undeploy: build
	@kubectx $(CLUSTER)
	@kubectl delete -f $(YAML_BUILD_DIR) 2>/dev/null || true
	@kubectl delete configmap $(APPLICATION)-config 2>/dev/null || true

redeploy: undeploy deploy

clean:
	docker container rm -f $(APPLICATION)-container 2>/dev/null || true
	docker image rm -f $(CONTAINER_IMAGE) 2>/dev/null || true
	docker system prune -f 2>/dev/null || true
	rm -rf $(YAML_BUILD_DIR)
