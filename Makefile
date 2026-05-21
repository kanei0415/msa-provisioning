# ============================================================
# kt-cloud-cluster クラスタプロビジョニング Makefile (Packer + ASG 版)
# ============================================================
# 構成: 1 master (静的 EC2, 2a) + worker ASG x 2 (2a / 2b) +
#       Cluster Autoscaler + 各種 IRSA (CCM / LBC / EBS-CSI / CA).
#
# AMI は Packer + Ansible で事前ビルド（イミュータブル）。worker は ASG の
# Launch Template から起動し、UserData が SSM Parameter から kubeadm join
# command を取得して自走 join する。Ansible は master 上のみで動く。
# ============================================================

SHELL                   := /usr/bin/env bash
.SHELLFLAGS             := -eu -o pipefail -c
.DEFAULT_GOAL           := help

# ---- パス ----
ROOT_DIR                := $(CURDIR)
TF_DIR                  := $(ROOT_DIR)/terraform
ANSIBLE_DIR             := $(ROOT_DIR)/ansible
PACKER_DIR              := $(ROOT_DIR)/packer
SSH_KEY                 := $(HOME)/.ssh/ktcloud-bastion-node-key
LOCAL_KUBECONFIG        := $(ROOT_DIR)/.kube/config
INVENTORY               := $(ANSIBLE_DIR)/inventory.ini

# ---- クラスタ定数 ----
CLUSTER_NAME            := kt-cloud-cluster
AWS_REGION              := ap-northeast-2
MASTER_PRIV_IP          := $(shell awk -F'=' '/^master_private_ip=/{print $$2}' $(INVENTORY) 2>/dev/null)
BASTION_B_IP            := $(shell awk -F'=' '/^bastion_b_ip=/{print $$2}' $(INVENTORY) 2>/dev/null)
ARGOCD_NS               := argocd

# ---- AMI ルックアップ用タグ ----
AMI_ROLE_TAG            := k8s-node
AMI_CLUSTER_TAG         := $(CLUSTER_NAME)
AMI_BUILT_BY_TAG        := packer

# ---- 色 ----
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
	@printf "$(CYAN)kt-cloud-cluster Makefile (Packer + ASG 版)$(RESET)\n\n"
	@printf "$(YELLOW)基本フロー:$(RESET)\n"
	@printf "  make all                          # 0 からフル構築 (ssh-key → ami → tf-apply → cluster-up)\n"
	@printf "  make destroy-all                  # cluster + AWS インフラを完全破棄\n\n"
	@printf "$(YELLOW)個別:$(RESET)\n"
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
check-prereqs: ## 前提コマンド (terraform, ansible-playbook, aws, ssh, packer, jq) の存在確認
	@for cmd in terraform ansible-playbook aws ssh jq packer; do \
	  if ! command -v $$cmd >/dev/null 2>&1; then \
	    printf "$(RED)missing: $$cmd$(RESET)\n"; exit 1; \
	  fi; \
	done
	@printf "$(GREEN)OK$(RESET)\n"

# ============================================================
# Packer AMI
# ============================================================

.PHONY: ami-current
ami-current: ## 現行 (tag:Role=k8s-node, tag:ClusterName=...) で最新の AMI ID を表示
	@aws ec2 describe-images \
	  --region $(AWS_REGION) \
	  --owners self \
	  --filters \
	    "Name=tag:Role,Values=$(AMI_ROLE_TAG)" \
	    "Name=tag:ClusterName,Values=$(AMI_CLUSTER_TAG)" \
	    "Name=tag:BuiltBy,Values=$(AMI_BUILT_BY_TAG)" \
	    "Name=state,Values=available" \
	  --query 'Images | sort_by(@,&CreationDate) | [-1].ImageId' \
	  --output text 2>/dev/null

.PHONY: ami
ami: ## Packer で AMI をビルド (既存があればスキップ)
	@AMI=$$($(MAKE) -s ami-current); \
	if [ -n "$$AMI" ] && [ "$$AMI" != "None" ]; then \
	  printf "$(YELLOW)既存 AMI を再利用: $$AMI$(RESET)\n"; \
	  printf "  強制再ビルドは 'make ami-force'\n"; \
	else \
	  printf "$(CYAN)AMI が無いので Packer build を実行$(RESET)\n"; \
	  $(MAKE) -s ami-prep; \
	  $(MAKE) -s ami-force; \
	fi

.PHONY: ami-prep
ami-prep: ## Packer ビルダー用に「auto-assign public IP な subnet」が無ければ default subnet を作る
	@PUBLIC_SUBNETS=$$(aws ec2 describe-subnets \
	  --region $(AWS_REGION) \
	  --filters "Name=map-public-ip-on-launch,Values=true" "Name=state,Values=available" \
	  --query 'Subnets[].SubnetId' --output text 2>/dev/null); \
	if [ -n "$$PUBLIC_SUBNETS" ]; then \
	  printf "$(GREEN)既存の public subnet を利用: $$PUBLIC_SUBNETS$(RESET)\n"; \
	  exit 0; \
	fi; \
	printf "$(YELLOW)public subnet が無いので default VPC に作成します$(RESET)\n"; \
	DEFAULT_VPC=$$(aws ec2 describe-vpcs --region $(AWS_REGION) \
	  --filters "Name=isDefault,Values=true" --query 'Vpcs[0].VpcId' --output text); \
	if [ -z "$$DEFAULT_VPC" ] || [ "$$DEFAULT_VPC" = "None" ]; then \
	  printf "$(RED)default VPC も無い。`aws ec2 create-default-vpc` を実行するか packer/variables.pkr.hcl の builder_subnet_id を明示してください$(RESET)\n"; \
	  exit 1; \
	fi; \
	printf "default VPC: $$DEFAULT_VPC\n"; \
	aws ec2 create-default-subnet --region $(AWS_REGION) --availability-zone $(AWS_REGION)a 2>/dev/null || true; \
	aws ec2 create-default-subnet --region $(AWS_REGION) --availability-zone $(AWS_REGION)c 2>/dev/null || true; \
	aws ec2 describe-subnets --region $(AWS_REGION) \
	  --filters "Name=map-public-ip-on-launch,Values=true" "Name=state,Values=available" \
	  --query 'Subnets[].SubnetId' --output text

.PHONY: ami-force
ami-force: ## Packer で AMI を強制ビルド（既存があってもスキップしない）
	@printf "$(CYAN)packer init + build を実行$(RESET)\n"
	cd $(PACKER_DIR) && packer init . && packer build .
	@printf "$(GREEN)AMI build 完了。$(RESET)\n"
	@$(MAKE) -s ami-current

.PHONY: ami-clean-old
ami-clean-old: ## 最新 1 件を残して古い Packer 製 AMI + snapshot を deregister
	@LATEST=$$($(MAKE) -s ami-current); \
	if [ -z "$$LATEST" ] || [ "$$LATEST" = "None" ]; then \
	  printf "$(YELLOW)現存 AMI 無し$(RESET)\n"; exit 0; \
	fi; \
	printf "keep: $$LATEST\n"; \
	OLD=$$(aws ec2 describe-images \
	  --region $(AWS_REGION) \
	  --owners self \
	  --filters \
	    "Name=tag:Role,Values=$(AMI_ROLE_TAG)" \
	    "Name=tag:ClusterName,Values=$(AMI_CLUSTER_TAG)" \
	    "Name=tag:BuiltBy,Values=$(AMI_BUILT_BY_TAG)" \
	  --query 'Images[].[ImageId,CreationDate]' \
	  --output text | sort -k2 | awk -v keep=$$LATEST '$$1!=keep{print $$1}'); \
	for ami in $$OLD; do \
	  printf "deregister: $$ami\n"; \
	  SNAPS=$$(aws ec2 describe-images --region $(AWS_REGION) --image-ids $$ami \
	    --query 'Images[].BlockDeviceMappings[].Ebs.SnapshotId' --output text 2>/dev/null); \
	  aws ec2 deregister-image --region $(AWS_REGION) --image-id $$ami || true; \
	  for snap in $$SNAPS; do \
	    aws ec2 delete-snapshot --region $(AWS_REGION) --snapshot-id $$snap || true; \
	  done; \
	done

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
tf-output: ## Terraform output
	cd $(TF_DIR) && terraform output

# ============================================================
# bastion / Ansible
# ============================================================

.PHONY: bastion-accept
bastion-accept: ## bastion の host key を ~/.ssh/known_hosts に追加（ProxyCommand 用）
	@for IP in $(BASTION_B_IP); do \
	  if [ -z "$$IP" ]; then continue; fi; \
	  printf "$(CYAN)accepting $$IP$(RESET)\n"; \
	  ssh-keygen -R $$IP 2>/dev/null || true; \
	  ssh -o StrictHostKeyChecking=accept-new -i $(SSH_KEY) ec2-user@$$IP hostname || true; \
	done

.PHONY: ansible-ping
ansible-ping: ## master への Ansible 疎通確認
	cd $(ANSIBLE_DIR) && ansible all -i inventory.ini -m ping

# ============================================================
# クラスタブートストラップ / 運用
# ============================================================

.PHONY: cluster-up
cluster-up: ## site.yaml をフル実行（bootstrap → control-plane → addons）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini site.yaml

.PHONY: cluster-bootstrap
cluster-bootstrap: ## bootstrap.yaml のみ実行（master の python 依存）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/bootstrap.yaml

.PHONY: cluster-control-plane
cluster-control-plane: ## control-plane.yaml のみ実行（kubeadm init + Calico + SSM 書き込み）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/control-plane.yaml

.PHONY: cluster-addons
cluster-addons: ## addons.yaml のみ実行（IRSA + 各 IRSA-ware addon + ArgoCD + Traefik）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/addons.yaml

.PHONY: wait-workers
wait-workers: ## ASG worker が cluster に join し Ready になるまで待つ
	@printf "$(CYAN)ASG worker の join を待機 (最大 15min)$(RESET)\n"
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/addons.yaml --tags wait_workers

.PHONY: refresh-join-command
refresh-join-command: ## master 上で新しい join token を生成して SSM Parameter を更新（24h 期限切れ対策）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/control-plane.yaml --tags init

# ============================================================
# Destroy 系: drain LB → AWS API LBC sweep → ASG=0 → kubeadm reset → terraform destroy
# ============================================================

.PHONY: drain-lbs
drain-lbs: ## cluster 上の Service type=LoadBalancer / Ingress / PVC を全削除（LBC NLB/ALB + EBS CSI 解放）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/clean.yaml --tags drain || true

# ------------------------------------------------------------
# aws-lbc-cleanup
# ------------------------------------------------------------
# drain-lbs だけでは「LBC が ALB の delete を reconcile し切る前に Ansible 側が
# 進んでしまう」「LBC pod が落ちている／cluster が壊れている」などで AWS 上に
# ALB/NLB と ENI が残り、その ENI が subnet/VPC を terraform destroy から守って
# しまう。AWS LBC が作るリソースは全部 `elbv2.k8s.aws/cluster=<cluster>` タグを
# 持つので、そのタグ起点で API 直叩きで掃除する（cluster の生死に依存しない）。
#
# 対象:
#   - elasticloadbalancing:loadbalancer (ALB / NLB)
#   - elasticloadbalancing:targetgroup
#   - ec2:security-group (LBC が作る frontend / backend SG)
#
# ENI は LB delete の副作用で AWS 側が自動 detach/delete するので個別に触らない。
# ------------------------------------------------------------
.PHONY: aws-lbc-cleanup
aws-lbc-cleanup: ## AWS API で LBC 生成 ALB/NLB/TG/SG をクラスタタグ起点で強制削除（tf destroy 前段の保険）
	@TAG_KEY=elbv2.k8s.aws/cluster; \
	 TAG_VAL=$(CLUSTER_NAME); \
	 REGION=$(AWS_REGION); \
	 printf "$(CYAN)Look up LBC resources (tag $$TAG_KEY=$$TAG_VAL)$(RESET)\n"; \
	 LB_ARNS=$$(aws resourcegroupstaggingapi get-resources \
	   --region $$REGION \
	   --tag-filters "Key=$$TAG_KEY,Values=$$TAG_VAL" \
	   --resource-type-filters elasticloadbalancing:loadbalancer \
	   --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null); \
	 if [ -n "$$LB_ARNS" ]; then \
	   for ARN in $$LB_ARNS; do \
	     printf "  delete LB %s\n" "$$ARN"; \
	     aws elbv2 delete-load-balancer --region $$REGION --load-balancer-arn "$$ARN" || true; \
	   done; \
	   printf "$(CYAN)LB delete 完了を最大 5min 待機 (ENI 解放まで)$(RESET)\n"; \
	   for ARN in $$LB_ARNS; do \
	     for i in $$(seq 1 30); do \
	       if ! aws elbv2 describe-load-balancers --region $$REGION --load-balancer-arns "$$ARN" >/dev/null 2>&1; then \
	         printf "  gone: %s\n" "$$ARN"; break; \
	       fi; \
	       sleep 10; \
	     done; \
	   done; \
	 else \
	   printf "  no LBC-managed load balancers\n"; \
	 fi; \
	 TG_ARNS=$$(aws resourcegroupstaggingapi get-resources \
	   --region $$REGION \
	   --tag-filters "Key=$$TAG_KEY,Values=$$TAG_VAL" \
	   --resource-type-filters elasticloadbalancing:targetgroup \
	   --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null); \
	 if [ -n "$$TG_ARNS" ]; then \
	   for ARN in $$TG_ARNS; do \
	     printf "  delete TG %s\n" "$$ARN"; \
	     aws elbv2 delete-target-group --region $$REGION --target-group-arn "$$ARN" || true; \
	   done; \
	 fi; \
	 SG_IDS=$$(aws resourcegroupstaggingapi get-resources \
	   --region $$REGION \
	   --tag-filters "Key=$$TAG_KEY,Values=$$TAG_VAL" \
	   --resource-type-filters ec2:security-group \
	   --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null \
	   | awk -F'/' '{print $$NF}'); \
	 if [ -n "$$SG_IDS" ]; then \
	   printf "$(CYAN)revoke rules → delete SG (LBC 生成)$(RESET)\n"; \
	   for SG in $$SG_IDS; do \
	     ING=$$(aws ec2 describe-security-groups --region $$REGION --group-ids "$$SG" \
	            --query 'SecurityGroups[0].IpPermissions' --output json 2>/dev/null); \
	     if [ -n "$$ING" ] && [ "$$ING" != "null" ] && [ "$$ING" != "[]" ]; then \
	       aws ec2 revoke-security-group-ingress --region $$REGION --group-id "$$SG" --ip-permissions "$$ING" >/dev/null 2>&1 || true; \
	     fi; \
	     EGR=$$(aws ec2 describe-security-groups --region $$REGION --group-ids "$$SG" \
	            --query 'SecurityGroups[0].IpPermissionsEgress' --output json 2>/dev/null); \
	     if [ -n "$$EGR" ] && [ "$$EGR" != "null" ] && [ "$$EGR" != "[]" ]; then \
	       aws ec2 revoke-security-group-egress --region $$REGION --group-id "$$SG" --ip-permissions "$$EGR" >/dev/null 2>&1 || true; \
	     fi; \
	   done; \
	   for SG in $$SG_IDS; do \
	     for i in $$(seq 1 12); do \
	       if aws ec2 delete-security-group --region $$REGION --group-id "$$SG" 2>/dev/null; then \
	         printf "  deleted SG %s\n" "$$SG"; break; \
	       fi; \
	       printf "  SG %s 削除待ち (try %s/12)\n" "$$SG" "$$i"; sleep 10; \
	     done; \
	   done; \
	 else \
	   printf "  no LBC-managed security groups\n"; \
	 fi; \
	 printf "$(GREEN)LBC cleanup done$(RESET)\n"

.PHONY: asg-scale-zero
asg-scale-zero: ## worker ASG を min=0/desired=0 にスケール（terraform destroy 前に instance 解放）
	@for ASG in $$(cd $(TF_DIR) && terraform output -json worker_asg_names 2>/dev/null | jq -r '.[]'); do \
	  printf "$(CYAN)scale to 0: $$ASG$(RESET)\n"; \
	  aws autoscaling update-auto-scaling-group \
	    --region $(AWS_REGION) \
	    --auto-scaling-group-name "$$ASG" \
	    --min-size 0 --desired-capacity 0 || true; \
	done
	@printf "$(CYAN)ASG instance terminate を最大 5min 待機$(RESET)\n"
	@for ASG in $$(cd $(TF_DIR) && terraform output -json worker_asg_names 2>/dev/null | jq -r '.[]'); do \
	  for i in $$(seq 1 30); do \
	    REMAIN=$$(aws autoscaling describe-auto-scaling-groups \
	      --region $(AWS_REGION) \
	      --auto-scaling-group-names "$$ASG" \
	      --query 'AutoScalingGroups[0].Instances | length(@)' --output text); \
	    if [ "$$REMAIN" = "0" ] || [ "$$REMAIN" = "None" ]; then \
	      printf "  $$ASG: drained\n"; break; \
	    fi; \
	    printf "  $$ASG: $$REMAIN remaining (try $$i/30)\n"; sleep 10; \
	  done; \
	done

.PHONY: cluster-clear
cluster-clear: ## drain LB/PVC + master kubeadm reset（cluster だけリセット、インフラは残す）
	cd $(ANSIBLE_DIR) && ansible-playbook -i inventory.ini playbooks/clean.yaml

.PHONY: destroy-all
destroy-all: ## drain LB+PVC → AWS LBC sweep → ASG=0 → terraform destroy → 古い AMI 掃除
	@printf "$(RED)WARNING: cluster と AWS インフラを完全に破棄します$(RESET)\n"
	@printf "$(CYAN)[1/5] cluster 上の LB + PVC を drain (LBC が ALB を delete 出来る間に reconcile させる)$(RESET)\n"
	$(MAKE) drain-lbs || true
	@printf "$(CYAN)[2/5] AWS API で LBC 生成 ALB/NLB/TG/SG を強制掃除 (drain 取りこぼし対策: ENI 残留で subnet/VPC 削除が詰まるのを防ぐ)$(RESET)\n"
	$(MAKE) aws-lbc-cleanup || true
	@printf "$(CYAN)[3/5] ASG を 0 にスケールして worker EC2 を terminate$(RESET)\n"
	$(MAKE) asg-scale-zero || true
	@printf "$(CYAN)[4/5] terraform destroy (master / bastion / VPC / EFS / IRSA Role / OIDC bucket 等)$(RESET)\n"
	$(MAKE) tf-destroy
	@printf "$(CYAN)[5/5] 古い Packer 製 AMI / snapshot を整理$(RESET)\n"
	$(MAKE) ami-clean-old || true
	@printf "$(GREEN)完了。次に立て直すときは 'make all'。$(RESET)\n"

# ============================================================
# kubeconfig / kubectl ローカルアクセス
# ============================================================

.PHONY: get-kubeconfig
get-kubeconfig: ## master から admin.conf をローカル ./.kube/config に取得（server を https://localhost:6443 に書き換え）
	@mkdir -p $(dir $(LOCAL_KUBECONFIG))
	scp -i $(SSH_KEY) -o ProxyCommand="ssh -W %h:%p -q ec2-user@$(BASTION_B_IP) -i $(SSH_KEY)" \
	    ec2-user@$(MASTER_PRIV_IP):/home/ec2-user/.kube/config $(LOCAL_KUBECONFIG)
	@sed -i.bak -E 's|server: https://[0-9.]+:6443|server: https://localhost:6443|' $(LOCAL_KUBECONFIG) && rm -f $(LOCAL_KUBECONFIG).bak
	@printf "$(GREEN)kubeconfig 取得完了: $(LOCAL_KUBECONFIG)$(RESET)\n"

.PHONY: kube-tunnel
kube-tunnel: ## bastion 経由で master:6443 を localhost:6443 にトンネル（フォアグラウンド）
	@printf "$(CYAN)bastion=$(BASTION_B_IP) master=$(MASTER_PRIV_IP)$(RESET)\n"
	ssh -N -L 6443:$(MASTER_PRIV_IP):6443 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
	    -i $(SSH_KEY) \
	    -o ProxyCommand="ssh -W %h:%p -q -i $(SSH_KEY) ec2-user@$(BASTION_B_IP)" \
	    ec2-user@$(MASTER_PRIV_IP)

# ============================================================
# 検証 / 状態
# ============================================================

.PHONY: verify
verify: ## kubectl get nodes + pods で全体状態を確認（master 経由）
	@printf "$(CYAN)master=$(MASTER_PRIV_IP) via bastion=$(BASTION_B_IP)$(RESET)\n"
	ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) \
	    -o ProxyCommand="ssh -W %h:%p -q -i $(SSH_KEY) ec2-user@$(BASTION_B_IP)" \
	    ec2-user@$(MASTER_PRIV_IP) \
	  'sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes -o wide; echo; sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get pods -A'

.PHONY: verify-asg
verify-asg: ## worker ASG の状態と CA-managed タグを表示
	@for ASG in $$(cd $(TF_DIR) && terraform output -json worker_asg_names 2>/dev/null | jq -r '.[]'); do \
	  printf "$(CYAN)$$ASG$(RESET)\n"; \
	  aws autoscaling describe-auto-scaling-groups --region $(AWS_REGION) \
	    --auto-scaling-group-names "$$ASG" \
	    --query 'AutoScalingGroups[0].{Min:MinSize,Max:MaxSize,Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,State:LifecycleState,Health:HealthStatus}}'; \
	done

.PHONY: verify-irsa
verify-irsa: ## OIDC issuer / S3 公開状況 / 各 IRSA Role を表示
	@cd $(TF_DIR) && terraform output irsa_oidc_issuer_url && terraform output irsa_role_arns

# ============================================================
# ArgoCD アクセス
# ============================================================

.PHONY: argocd-password
argocd-password: ## ArgoCD admin の初期パスワードを表示
	@ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) \
	    -o ProxyCommand="ssh -W %h:%p -q -i $(SSH_KEY) ec2-user@$(BASTION_B_IP)" \
	    ec2-user@$(MASTER_PRIV_IP) \
	  "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n $(ARGOCD_NS) get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"

.PHONY: argocd-port-forward
argocd-port-forward: ## ArgoCD UI を localhost:8443 にフォワード
	@printf "$(CYAN)master=$(MASTER_PRIV_IP) via $(BASTION_B_IP)$(RESET)\n"
	@PW=$$($(MAKE) -s argocd-password 2>/dev/null); \
	  printf "$(GREEN)→ http://localhost:8443/argocd  (admin / $$PW)$(RESET)\n"
	@ssh -o StrictHostKeyChecking=no -i $(SSH_KEY) \
	    -o ProxyCommand="ssh -W %h:%p -q -i $(SSH_KEY) ec2-user@$(BASTION_B_IP)" \
	    ec2-user@$(MASTER_PRIV_IP) \
	    'sudo pkill -9 -f "kubectl .*port-forward.*svc/argocd-server" 2>/dev/null; exit 0' >/dev/null 2>&1 || true
	ssh -tt -L 8443:127.0.0.1:8443 -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 \
	    -i $(SSH_KEY) \
	    -o ProxyCommand="ssh -W %h:%p -q -i $(SSH_KEY) ec2-user@$(BASTION_B_IP)" \
	    ec2-user@$(MASTER_PRIV_IP) \
	    "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf -n $(ARGOCD_NS) port-forward --address 127.0.0.1 svc/argocd-server 8443:80"

# ============================================================
# ライフサイクル統合
# ============================================================

.PHONY: all
all: check-prereqs ssh-key ami tf-init tf-apply bastion-accept ansible-ping cluster-up verify ## 0 からフル構築 (Packer AMI ビルド込み)
