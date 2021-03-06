# https://www.linode.com/docs/kubernetes/deploy-and-manage-lke-cluster-with-api-a-tutorial/
LKE_CONFIGS := $(XDG_CONFIG_HOME)/.kube/configs
LKE_NAME ?= prod

# This has been already created & will be enabled on: eval "$(make env)"
env::
	@echo 'export LKE_LABEL=prod-20210302'

LKE_LABEL ?= $(LKE_NAME)-$(shell date -u +'%Y%m%d')
# us-east is the only US region with all the bells & whistles in 2021.03:
# Linodes, NodeBalancers, Block Storage, Object Storage, GPU Linodes, Kubernetes
LKE_REGION ?= us-east
LKE_VERSION ?= 1.19
LKE_NODE_TYPE ?= g6-dedicated-16
LKE_NODE_COUNT ?= 1

$(LKE_CONFIGS):
	mkdir -p $(LKE_CONFIGS)

env:: | $(LPASS)
	@echo 'export LINODE_CLI_TOKEN="$(shell $(LPASS) show --notes Shared-changelog/secrets/LINODE_CLI_TOKEN)"'

ifeq ($(PLATFORM),Darwin)
# Use Python3 for all Python-based CLIs, such as linode-cli
PATH := /usr/local/opt/python/libexec/bin:$(PATH)
export PATH

PIP := /usr/local/bin/pip3
$(PIP):
	brew install python3

# https://github.com/linode/linode-cli
LINODE_CLI := /usr/local/bin/linode-cli
$(LINODE_CLI): $(PIP)
	$(PIP) install linode-cli
	touch $(@)


linode-cli-upgrade: $(PIP)
	$(PIP) install --upgrade linode-cli
endif

ifeq ($(PLATFORM),Linux)
LINODE_CLI ?= /usr/bin/linode-cli
$(LINODE_CLI):
	$(error Please install linode-cli: https://github.com/linode/linode-cli)
endif

.PHONY: linode-cli
linode-cli: $(LINODE_CLI)


.PHONY: linode
linode: | $(LINODE_CLI)
ifndef LINODE_CLI_TOKEN
	@printf "$(RED)LINODE_CLI_TOKEN$(NORMAL) environment variable must be set\n"
	@printf 'Run $(BOLD)eval "$$(make env)"$(NORMAL)\n'
	exit 1
endif

env:: | linode
	@$(LINODE_CLI) completion bash

LINODE := $(LINODE_CLI) --no-defaults

.PHONY: regions
regions: | linode
	$(LINODE) regions list

.PHONY: linodes
linodes: | linode
	$(LINODE) linodes list

.PHONY: linodes-types
linodes-types: | linode
	$(LINODE) linodes types

.PHONY: nodebalancers
nodebalancers: | linode
	$(LINODE) nodebalancers list

.PHONY: lke
lke: | linode
	$(LINODE) lke cluster-create \
	    --label $(LKE_LABEL) \
	    --region $(LKE_REGION) \
	    --k8s_version $(LKE_VERSION) \
	    --node_pools.type $(LKE_NODE_TYPE) \
	    --node_pools.count $(LKE_NODE_COUNT)

LKE_LS = $(LINODE) --all lke clusters-list
.PHONY: lke-ls
lke-ls: | linode
	$(LKE_LS)

.PHONY: lke-versions
lke-versions: | linode
	$(LINODE) --all lke versions-list

LKE_POOL_LS = $(LINODE) --all lke pools-list $(LKE_CLUSTER_ID)
define LKE_CLUSTER_ID
$$($(LKE_LS) --json \
| $(JQ) '.[] | select(.label == "$(LKE_LABEL)") | .id')
endef

.PHONY: lke-pool
lke-pool: | linode $(JQ)
	$(LINODE) lke pool-create \
	    --type $(LKE_NODE_TYPE) \
	    --count $(LKE_NODE_COUNT) \
	    $(LKE_CLUSTER_ID)

.PHONY: lke-pool-ls
lke-pool-ls: | linode $(JQ)
	$(LKE_POOL_LS)

.PHONY: lke-configs
lke-configs: | linode $(LKE_CONFIGS) $(JQ)
	@$(LKE_LS) --json \
	  | $(JQ) --raw-output --compact-output '.[] | [.id, .label] | join(" ")' \
	  | while read -r lke_id lke_name \
	    ; do \
	      printf "Saving $(BOLD)$$lke_name$(NORMAL) LKE cluster config to $(BOLD)$(LKE_CONFIGS)/$$lke_name.yml$(NORMAL) ...\n" \
	      ; $(LINODE) lke kubeconfig-view $$lke_id --no-headers --text \
	      | base64 --decode \
	      > $(LKE_CONFIGS)/$$lke_name.yml \
	    ; done \
	  && printf "$(BOLD)$(GREEN)OK!$(NORMAL)\n" \
	  && printf "\nTo use a specific config with $(BOLD)kubectl$(NORMAL), run e.g. $(BOLD)export KUBECONFIG=$(NORMAL)\n"

env::
	@echo 'export KUBECONFIG=$(LKE_CONFIGS)/$(LKE_LABEL).yml'

IS_KUBECONFIG_LKE_CONFIG := $(findstring $(LKE_CONFIGS), $(KUBECONFIG))
.PHONY: lke-config-hint
lke-config-hint:
ifneq ($(IS_KUBECONFIG_LKE_CONFIG), $(LKE_CONFIGS))
	@printf "You may want to set $(BOLD)KUBECONFIG$(NORMAL) " \
	; printf "to one of the configs stored in $(BOLD)$(LKE_CONFIGS)$(NORMAL)\n"
endif

KUBECTL_RELEASES := https://github.com/kubernetes/kubernetes/releases
KUBECTL_VERSION = $(LKE_VERSION).8
KUBECTL_BIN := kubectl-$(KUBECTL_VERSION)-$(platform)-amd64
KUBECTL_URL := https://storage.googleapis.com/kubernetes-release/release/v$(KUBECTL_VERSION)/bin/$(platform)/amd64/kubectl
KUBECTL := $(LOCAL_BIN)/$(KUBECTL_BIN)
$(KUBECTL): | $(CURL) $(LOCAL_BIN)
	$(CURL) --progress-bar --fail --location --output $(KUBECTL) "$(KUBECTL_URL)"
	touch $(KUBECTL)
	chmod +x $(KUBECTL)
	$(KUBECTL) version | grep $(KUBECTL_VERSION)
	ln -sf $(KUBECTL) $(LOCAL_BIN)/kubectl
.PHONY: kubectl
kubectl: $(KUBECTL)

.PHONY: releases-kubectl
releases-kubectl:
	$(OPEN) $(KUBECTL_RELEASES)

.PHONY: lke-ctx
lke-ctx: | $(KUBECTL) lke-config-hint
