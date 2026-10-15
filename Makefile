# Kiro usage analytics: build, test and deploy.
#
#   make test build validate                local checks, no AWS access
#   make ENV=<env> bootstrap                once per account: state bucket + keys
#   make ENV=<env> platform-plan            AWS resources: review the plan ...
#   make ENV=<env> platform-apply           ... then apply exactly that plan
#   make ENV=<env> ingest                   run the import once (first time: schema + reader role)
#   make ENV=<env> grafana-plan grafana-apply
#
# All settings come from config/<env>.tfvars (see config/example.tfvars).

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ENV    ?=
CONFIG := $(abspath config/$(ENV).tfvars)
LIVE   := infra/live
PY     := .venv/bin/python
STACKS := bootstrap platform grafana

# Every tofu command gets the config file (backend and encryption settings
# need it at init), and each environment gets its own working directory.
ifneq ($(ENV),)
export TF_DATA_DIR       := .terraform/$(ENV)
export TF_CLI_ARGS_init  := -var-file=$(CONFIG)
export TF_CLI_ARGS_plan  := -var-file=$(CONFIG)
export TF_CLI_ARGS_apply := -var-file=$(CONFIG)
export TF_CLI_ARGS_output := -var-file=$(CONFIG)
# The AWS CLI calls (ingest, Grafana tokens) use the same profile and region.
CFG_PROFILE := $(shell sed -nE 's/^aws_profile *= *"([^"]*)".*/\1/p' $(CONFIG) 2>/dev/null)
CFG_REGION  := $(shell sed -nE 's/^aws_region *= *"([^"]*)".*/\1/p' $(CONFIG) 2>/dev/null)
ifneq ($(CFG_PROFILE),)
export AWS_PROFILE := $(CFG_PROFILE)
endif
export AWS_REGION := $(CFG_REGION)
endif

.PHONY: help test build fmt fmt-check validate check-env bootstrap platform-init platform-plan \
        platform-apply ingest grafana-init grafana-plan grafana-apply

help:
	@sed -n '2,12p' Makefile

test:
	cd src/ingest && ../../$(PY) -m pytest

build:
	$(PY) scripts/build_lambda.py

fmt:
	tofu fmt -recursive infra config

fmt-check:
	tofu fmt -recursive -check -diff infra config

# Syntax and type checks without touching any backend or AWS account.
validate: fmt-check
	@for s in $(STACKS); do \
	  echo "== $$s"; \
	  TF_DATA_DIR=.terraform/validate TF_CLI_ARGS_init= tofu -chdir=$(LIVE)/$$s init -backend=false -input=false >/dev/null; \
	  TF_DATA_DIR=.terraform/validate tofu -chdir=$(LIVE)/$$s validate; \
	done

check-env:
	@test -n "$(ENV)" || { echo "set ENV, e.g. make ENV=team-a ..." >&2; exit 2; }
	@test -f "$(CONFIG)" || { echo "missing $(CONFIG); copy config/example.tfvars" >&2; exit 2; }

bootstrap: check-env
	tofu -chdir=$(LIVE)/bootstrap init -input=false
	tofu -chdir=$(LIVE)/bootstrap apply

platform-init: check-env
	tofu -chdir=$(LIVE)/platform init -input=false

platform-plan: build platform-init
	tofu -chdir=$(LIVE)/platform plan -out=tfplan

platform-apply: check-env
	tofu -chdir=$(LIVE)/platform apply tfplan
	rm -f $(LIVE)/platform/tfplan

ingest: check-env
	fn=$$(tofu -chdir=$(LIVE)/platform output -raw ingest_function_name); \
	aws lambda invoke --function-name "$$fn" --payload '{}' \
	  --cli-binary-format raw-in-base64-out --log-type None /dev/stdout | python3 -m json.tool

grafana-init: check-env
	tofu -chdir=$(LIVE)/grafana init -input=false

grafana-plan: grafana-init
	scripts/with-grafana-token.sh $(LIVE)/platform -- tofu -chdir=$(LIVE)/grafana plan -out=tfplan

grafana-apply: check-env
	scripts/with-grafana-token.sh $(LIVE)/platform -- tofu -chdir=$(LIVE)/grafana apply tfplan
	rm -f $(LIVE)/grafana/tfplan
