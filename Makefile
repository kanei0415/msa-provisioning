# ============================================================
# kt-cloud-cluster クラスタプロビジョニング Makefile
# ============================================================
# AWS 上に kubeadm ベースの自己管理型シングル master Kubernetes クラスタを
# 構築・運用するための Makefile。
#
# 構成: 1 master (2a) + 5 worker (2a x2, 2b x3)、Calico CNI、
#       AWS Load Balancer Controller、ArgoCD GitOps。
# ============================================================

SHELL                   := /usr/bin/env bash
.SHELLFLAGS             := -eu -o pipefail -c
.DEFAULT_GOAL           := help

# ---- パス ----
ROOT_DIR                := $(CURDIR)
TF_DIR                  := $(ROOT_DIR)/terraform
ANSIBLE_DIR             := $(ROOT_DIR)/ansible
SSH_KEY                 := $(HOME)/.ssh/ktcloud-bastion-node-key
LOCAL_KUBECONFIG        := $(ROOT_DIR)/.kube/config
INVENTORY               := $(ANSIBLE_DIR)/inventory.ini

# ---- クラスタ定数 ----
CLUSTER_NAME            := kt-cloud-cluster
MASTER_PRIV_IP          := $(shell awk -F'=' '/^master_private_ip=/{print $$2}' $(INVENTORY) 2>/dev/null)
BASTION_A_IP            := $(shell awk '/master:vars/,/^$$/{if ($$0 ~ /ec2-user@/) print}' $(INVENTORY) 2>/dev/null | grep -oE 'ec2-user@[0-9.]+' | sed 's/ec2-user@//' | head -1)
ARGOCD_NS               := argocd

# 色
CYAN                    := \033[36m
GREEN                   := \033[32m
YELLOW                  := \033[33m
RED                     := \033[31m
RESET                   := \033[0m

# ============================================================
# ヘルプ
# ============================================================

.PHONY: help
help: ## このヘルプを表示
	@printf "$(CYAN)kt-cloud-cluster Makefile$(RESET)\n\n"
	@printf "$(YELLOW)基本フロー:$(RESET)\n"
	@printf "  1) make ssh-key                   SSH キーペア生成\n"
	@printf "  2) make tf-init                   Terraform 初期化（backend.tfvars 必要）\n"
	@printf "  3) make tf-apply                  AWS インフラ作成\n"
	@printf "  4) make bastion-accept            bastion の host key 受理\n"
	@printf "  5) make ansible-ping              Ansible 疎通確認\n"
	@printf "  6) make cluster-up                クラスタブートストラップ\n"
	@printf "  7) make verify                    クラスタ検証\n\n"
	@printf "$(YELLOW)便利コマンド:$(RESET)\n"
	@grep -hE '^[a-zA-Z][a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk -F':.*?## ' '{printf "  $(GREEN)%-25s$(RESET) %s\n", $$1, $$2}'

# ============================================================
# 前提条件
# ============================================================

.PHONY: ssh-key
ssh-key: ## bastion / node 用 SSH キーペア生成（既存があればスキップ）
	@if [ -f $(SSH_KEY) ] && [ -f $(SSH_KEY).pub ]; then \
	  printf "$(YELLOW)既に存在: $(SSH_KEY)$(RESET)\n"; \
	else \
	  bash $(ROOT_DIR)/ssh-key-gen.bash; \
	fi

.PHONY: check-prereqs
check-prereqs: ## 前提コマンド (terraform, ansible-playbook, aws, ssh) の存在確認
	@for cmd in terraform ansible-playbook aws ssh jq; do \
	  if ! command -v $$cmd >/dev/null 2>&1; then \
	    printf "$(RED)missing: $$cmd$(RESET)\n"; exit 1; \
	  fi; \
	done
	@printf "$(GREEN)OK$(RESET)\n"

# ============================================================
# Terraform
# ============================================================

.PHONY: tf-init
tf-init: ## Terraform 初期化（terraform/backend.tfvars 必要）
	@if [ ! -f $(TF_DIR)/backend.tfvars ]; then \
	  printf "$(RED)$(TF_DIR)/backend.tfvars が無い。backend.tfvars.sample をコピーして S3 bucket を埋めてください。$(RESET)\n"; \
	  exit 1; \
	fi
	cd $(TF_DIR) && terraform init -backend-config=backend.tfvars -migrate-state

.PHONY: tf-plan
tf-plan: ## Terraform plan
	cd $(TF_DIR) && terraform plan

.PHONY: tf-apply
tf-apply: ## Terraform apply（auto-approve）
	cd $(TF_DIR) && terraform apply -auto-approve

.PHONY: tf-destroy
tf-destroy: ## Terraform destroy（auto-approve）
	cd $(TF_DIR) && terraform destroy -auto-approve

.PHONY: tf-output
tf-output: ## Terraform output（接続情報を表示）
	cd $(TF_DIR) && terraform output

# ============================================================
# bastion / Ansible
# ============================================================

.PHONY: bastion-accept
bastion-accept: ## bastion の host key を ~/.ssh/known_hosts に追加（ProxyCommand 用）
	@BA=$$(cd $(TF_DIR) && terraform output | awk '/bastion-connect-command/' | grep -oE 'ec2-user@[0-9.]+' | sort -u); \
	for h in $$BA; do \
	  IP=$${h#ec2-user@}; \
	  printf "$(CYAN)accepting $$IP$(RESET)\n"; \
	  ssh-keygen -R $$IP 2>/dev/null || true; \
	  ssh -o StrictHostKeyChecking=accept-new -i $(SSH_KEY) ec2-user@$$IP hostname || true; \
	done

.PHONY: ansible-ping
ansible-ping: ## 全ノードへの Ansible 疎通確認
	cd $(ANSIBLE_DIR) && ansible all -i inventory.ini -m ping

# ============================================================
# クラスタブートストラップ / 運用
# ============================================================

.PHONY: cluster-up
cluster-up: ## site.yaml をフル実行（bootstrap → control-plane → workers → addons）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yaml

.PHONY: cluster-bootstrap
cluster-bootstrap: ## bootstrap.yaml のみ実行（OS 準備 + パッケージ + containerd）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/bootstrap.yaml

.PHONY: cluster-control-plane
cluster-control-plane: ## control-plane.yaml のみ実行（kubeadm init + Calico）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/control-plane.yaml

.PHONY: cluster-workers
cluster-workers: ## workers.yaml のみ実行（worker join）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/workers.yaml

.PHONY: cluster-addons
cluster-addons: ## addons.yaml のみ実行（Helm + AWS LBC + ArgoCD）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/addons.yaml

.PHONY: cluster-clear
cluster-clear: ## clean.yaml 実行（kubeadm reset + /etc/kubernetes,/var/lib/etcd 削除）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/clean.yaml

.PHONY: irsa-setup
irsa-setup: ## IRSA OIDC セットアップ（discovery 文書 S3 アップロード + apiserver 再構成）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/irsa.yaml

# ============================================================
# kubeconfig / kubectl ローカルアクセス
# ============================================================

.PHONY: get-kubeconfig
get-kubeconfig: ## master から admin.conf をローカル ./.kube/config に取得（server を https://localhost:6443 に書き換え）
	@mkdir -p $(dir $(LOCAL_KUBECONFIG))
	scp -i $(SSH_KEY) -o ProxyCommand="ssh -W %h:%p -q ec2-user@$(BASTION_A_IP) -i $(SSH_KEY)" \
	    ec2-user@$(MASTER_PRIV_IP):/home/ec2-user/.kube/config $(LOCAL_KUBECONFIG)
	@# server を localhost に書き換え。localhost は kubeadm-config の certSANs に含まれているため TLS 検証が通る。
	@sed -i.bak -E 's|server: https://[0-9.]+:6443|server: https://localhost:6443|' $(LOCAL_KUBECONFIG) && rm -f $(LOCAL_KUBECONFIG).bak
	@printf "$(GREEN)kubeconfig 取得完了: $(LOCAL_KUBECONFIG)$(RESET)\n"
	@printf "$(YELLOW)使い方:$(RESET)\n"
	@printf "  別 terminal で:  make kube-tunnel  （トンネルを張り続けるので維持）\n"
	@printf "  この terminal で: export KUBECONFIG=$(LOCAL_KUBECONFIG) && kubectl get nodes\n"

.PHONY: kube-tunnel
kube-tunnel: ## bastion 経由で master:6443 を localhost:6443 にトンネル（フォアグラウンド、Ctrl+C で終了）
	@printf "$(CYAN)bastion=$(BASTION_A_IP) master=$(MASTER_PRIV_IP)$(RESET)\n"
	@printf "$(GREEN)→ localhost:6443 → master:6443 を維持中。別 terminal で:$(RESET)\n"
	@printf "    export KUBECONFIG=$(LOCAL_KUBECONFIG) && kubectl get nodes\n"
	@printf "$(YELLOW)Ctrl+C で終了。$(RESET)\n"
	ssh -N -L 6443:$(MASTER_PRIV_IP):6443 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
	    -i $(SSH_KEY) -J ec2-user@$(BASTION_A_IP) ec2-user@$(MASTER_PRIV_IP)

# ============================================================
# 検証 / 状態
# ============================================================

.PHONY: verify
verify: ## kubectl get nodes + pods で全体状態を確認（master 経由）
	@printf "$(CYAN)master=$(MASTER_PRIV_IP) via bastion=$(BASTION_A_IP)$(RESET)\n"
	ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) -J ec2-user@$(BASTION_A_IP) ec2-user@$(MASTER_PRIV_IP) \
	  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes; echo; sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A'

# ============================================================
# ArgoCD アクセス
# ============================================================

.PHONY: argocd-password
argocd-password: ## ArgoCD admin の初期パスワードを表示
	@ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) -J ec2-user@$(BASTION_A_IP) ec2-user@$(MASTER_PRIV_IP) \
	  "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n $(ARGOCD_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"

.PHONY: argocd-port-forward
argocd-port-forward: ## ArgoCD UI を localhost:8443 にフォワード（単一コマンド、Ctrl+C で終了）
	@printf "$(CYAN)master=$(MASTER_PRIV_IP) via $(BASTION_A_IP)$(RESET)\n"
	@PW=$$($(MAKE) -s argocd-password 2>/dev/null); \
	  printf "$(GREEN)→ http://localhost:8443/argocd  (admin / $$PW)$(RESET)\n"
	@printf "$(YELLOW)Ctrl+C で終了。$(RESET)\n"
	@# 前回の SSH が異常終了した場合 master 側に残留する kubectl port-forward を予防的に kill
	@ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) -J ec2-user@$(BASTION_A_IP) ec2-user@$(MASTER_PRIV_IP) \
	    'sudo pkill -9 -f "kubectl .*port-forward.*svc/argocd-server" 2>/dev/null; exit 0' >/dev/null 2>&1 || true
	@# -t (TTY 割当) で SSH 切断時に SIGHUP が sudo→kubectl まで届くようにする
	@# -L: laptop:8443 → master:127.0.0.1:8443  /  remote 側で kubectl port-forward が同 port を bind
	ssh -tt -L 8443:127.0.0.1:8443 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
	    -i $(SSH_KEY) -J ec2-user@$(BASTION_A_IP) ec2-user@$(MASTER_PRIV_IP) \
	    "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n $(ARGOCD_NS) port-forward --address 127.0.0.1 svc/argocd-server 8443:80"

.PHONY: argocd-cli
argocd-cli: ## argocd CLI 用の login コマンド例を表示
	@PW=$$($(MAKE) -s argocd-password); \
	printf "$(YELLOW)argocd CLI でログインする手順:$(RESET)\n"; \
	printf "  1) make argocd-port-forward （別 terminal で起動して維持）\n"; \
	printf "  2) argocd login localhost:8443 --username admin --password '$$PW' --insecure --grpc-web-root-path /argocd\n"; \
	printf "  3) argocd app list / argocd app sync root-app\n"

# ============================================================
# ライフサイクル統合
# ============================================================

.PHONY: all
all: check-prereqs ssh-key tf-init tf-apply bastion-accept ansible-ping cluster-up verify ## 0 からフル構築

.PHONY: destroy-all
destroy-all: ## クラスタ + AWS インフラを完全破棄
	@printf "$(RED)WARNING: クラスタとインフラを完全に破棄します$(RESET)\n"
	$(MAKE) cluster-clear || true
	$(MAKE) tf-destroy
