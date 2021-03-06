# v2.3.2
ifeq (,$(wildcard ./app.ini))
$(error "The file app.ini was not found.  Please create it in the project root folder.")
else
include app.ini
endif

ifeq ($(strip $(ENVIRONMENT)),)
$(error "The ENVIRONMENT variable is undefined.  Please, define its value in app.ini file.")
endif
APPLICATION ?= $(shell basename $(CURDIR))
NAMESPACE   ?= $(APPLICATION)

ifeq (,$(wildcard ./.git))
$(error "This project is still not version controlled.  Please initialize a git repo and add a remote to it.")
endif

VERSION     := $(shell git describe --tags --dirty --match="v*" 2> /dev/null || cat $(CURDIR)/.version 2> /dev/null)
ifndef VERSION
VERSION     := latest
endif

YAML_DIR       ?= ./yaml
YAML_BUILD_DIR := ./.build_yaml
YAML_FILES     := $(shell find $(YAML_DIR) -name '*.yaml' 2>/dev/null | sed 's:$(YAML_DIR)/::g')

DOCKER_CONTEXT := .
SRC_DIR        := $(DOCKER_CONTEXT)/src
ENV_FILE       ?= $(SRC_DIR)/env
DOCKERFILE     ?= $(SRC_DIR)/Dockerfile

ENV_FLAGS := -e APPLICATION=$(APPLICATION) -e ENVIRONMENT=$(ENVIRONMENT)
ifneq (,$(wildcard $(ENV_FILE)))
	ENV_FLAGS += --env-file=$(ENV_FILE)
endif

K8S_DEPLOY  ?= false
BUILD_IMAGE ?= true
IMAGE_HUB   ?= registry.trt8.jus.br
IMAGE_NAME  ?= $(shell git remote -v | sed -ne '1 s:^origin.*gitlab\.trt8\.jus\.br[:/]\(.*\)\.git.*$$:\1:p')
ifeq ($(strip $(IMAGE_NAME)),)
$(error "The IMAGE_NAME is undefined.  Please, define it on app.ini or clone a repo from gitlab.trt8.jus.br.")
endif

DOCKER_IMAGE := $(IMAGE_HUB)/$(IMAGE_NAME):$(VERSION)

ifndef BUILD_ARGS
DOCKER_BUILD_ARGS := -t $(DOCKER_IMAGE)
else
DOCKER_BUILD_ARGS := $(shell echo ' $(BUILD_ARGS)' | sed 's:\ : --build-arg :g') -t $(DOCKER_IMAGE)
endif


APPID := $(shell bash -c 'printf "%05d" $$RANDOM')-$(APPLICATION)

AVAILABLE_VARS := APPLICATION NAMESPACE ENVIRONMENT DOCKER_IMAGE APPID
AVAILABLE_VARS += APP_BACKEND_PORT APP_ENDPOINT_URL APP_ENDPOINT_PATH

SHELL_EXPORT := $(foreach v,$(AVAILABLE_VARS),$(v)='$(firstword $($(v)))' )

# ---------------------------------------------------------------------------------------------------------------------
.PHONY: help image release docker-run image-start image-stop build-yaml deploy clean

help:
	@echo ''
	@echo 'Usage:'
	@echo '    make [TARGET TARGET ...]'
	@echo ''
	@echo 'TARGET can be:'
	@echo '    image       - builds the Docker image.'
	@echo '    release     - builds and pushes the Docker image.'
	@echo '    clean       - gets rid of generated files and Docker resources.'
	@echo ''
	@echo '    docker-run  - runs Docker image (with RUN_FLAGS, if specified).'
	@echo '    image-start - runs Docker image in background (with RUN_FLAGS, if specified).'
	@echo '    image-stop  - stops Docker image previously started.'
	@echo '    shell       - runs Docker image interactively with shell instead of entrypoint.'
	@echo ''
	@echo '    build-yaml  - interpolates variables of project in yaml files folder.'
	@echo '    deploy      - apply resources from yaml files folder.'
	@echo '    undeploy    - delete resources from yaml files folder.'
	@echo '    redeploy    - just an undeploy followed by a deploy.'
	@echo ''
	@echo '    help        - this message.'
	@echo ''

image:
ifeq ($(BUILD_IMAGE), true)
	@echo 'Building image $(DOCKER_IMAGE)'
	docker build -f $(DOCKERFILE) $(DOCKER_BUILD_ARGS) $(DOCKER_CONTEXT)
else
	@echo 'Using image $(DOCKER_IMAGE)'
endif

release: image
ifeq ($(BUILD_IMAGE), true)
	docker push $(DOCKER_IMAGE)
endif

shell: image
	docker run -it --rm --name $(APPLICATION)-container --entrypoint /bin/sh $(ENV_FLAGS) $(DOCKER_IMAGE)

docker-run: image
	docker run --rm --name $(APPLICATION)-container $(ENV_FLAGS) $(RUN_FLAGS) $(DOCKER_IMAGE)

image-start: image
	docker run -d -t --name $(APPLICATION)-container $(ENV_FLAGS) $(RUN_FLAGS) $(DOCKER_IMAGE)

image-stop: image
	docker stop -t 1 $(APPLICATION)-container


# Create the yaml build directory if it does not exist
$(YAML_BUILD_DIR):
	@mkdir -p $(YAML_BUILD_DIR)

build-yaml: $(YAML_BUILD_DIR)
	@echo 'YAML files support the following vars: $(AVAILABLE_VARS)'
	@for file in $(YAML_FILES); do \
		mkdir -p `dirname "$(YAML_BUILD_DIR)/$$file"` ; \
		$(SHELL_EXPORT) envsubst <$(YAML_DIR)/$$file >$(YAML_BUILD_DIR)/$$file ;\
	done

deploy: build-yaml
ifeq ($(K8S_DEPLOY), false)
	$(error '(K8S_DEPLOY=false) Configured to not deploy to Kubernetes.  Skipping.')
else
	@kubectx kubernetes-$(ENVIRONMENT)

ifneq (,$(wildcard $(ENV_FILE)))
	@kubectl create configmap $(APPLICATION)-config -o yaml --dry-run \
		-n $(NAMESPACE) \
		--from-env-file=$(ENV_FILE) \
	| kubectl apply -f -
endif
	@kubectl apply -f $(YAML_BUILD_DIR)
endif

undeploy: build-yaml
ifeq ($(K8S_DEPLOY), false)
	$(error '(K8S_DEPLOY=false) Configured to not deploy to Kubernetes.  Skipping.')
else
	@kubectx kubernetes-$(ENVIRONMENT)

	@kubectl delete configmap $(APPLICATION)-config 2>/dev/null || true
	@kubectl delete -f $(YAML_BUILD_DIR) 2>/dev/null || true
endif

redeploy: undeploy deploy


clean:
	docker container rm -f $(APPLICATION)-container 2>/dev/null || true
	docker image rm -f $(DOCKER_IMAGE) 2>/dev/null || true
	docker system prune -f 2>/dev/null || true
	rm -rf $(YAML_BUILD_DIR)
