# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Two-stage IaC that stands up a **self-managed, single-master kubeadm Kubernetes cluster on EC2** (not EKS) in `ap-northeast-2`, then layers on AWS Load Balancer Controller and an ArgoCD-managed GitOps root app. Terraform provisions AWS infra; Ansible bootstraps the cluster. The README is in Japanese — match that language/tone when editing it or authoring new playbook task names.

## Provisioning workflow (end-to-end)

Everything is wrapped in `Makefile`. The pipeline is **strictly ordered**; later stages assume earlier outputs:

1. `make ssh-key` — creates `~/.ssh/ktcloud-bastion-node-key{,.pub}`. Required before `terraform apply`: the `.pub` is read by `aws_key_pair`, and the private key path is hardcoded into the inventory template.
2. `cp terraform/backend.tfvars.sample terraform/backend.tfvars` and fill in the S3 `bucket`. Then `make tf-init`.
3. `make tf-apply` — provisions VPC, subnets, NAT, EC2, EFS, and **writes `ansible/inventory.ini`** via the `modules/ansible-inventory` module.
4. `make bastion-accept` — accepts bastion host fingerprints (Ansible ProxyCommand hangs otherwise).
5. `make ansible-ping` — sanity check.
6. `make cluster-up` — runs `site.yaml` (bootstrap → control-plane → workers → addons).
7. `make verify` — `kubectl get nodes` + `get pods -A` via SSH/bastion to the master.

Cluster teardown: `make cluster-clear`. Full destroy: `make destroy-all`.

## Out-of-band prerequisites (not created by this repo)

- **IAM**: all roles/policies are now Terraform-managed (`terraform/iam.tf`, `terraform/irsa.tf`). No pre-created roles required. LBC / CCM / cluster-autoscaler / EBS-CSI / external-secrets all use IRSA roles defined under `terraform/irsa.tf`; the master/static-node instance role (`ktcloud-cluster-node-role`) only carries SSM put/get for the kubeadm join-command parameter.
- **AWS CLI credentials** for an IAM principal with EC2/VPC/ELB/EFS/IAM-PassRole permissions. Configure via `aws configure`.
- **S3 bucket** for Terraform remote state (referenced by `backend.tfvars`).

## Architecture cheat sheet

**Topology** — single VPC `10.0.0.0/16`, mirrored per AZ (`2a`, `2b`):
- Public subnets `.1.0/24` (2a) / `.3.0/24` (2b) → NAT GWs both AZs; **bastion lives only in 2b** (`ap-northeast-2b-bastion`). 2a public subnet has no bastion — keeps the operator entry point single.
- Private subnets `.2.0/24` (2a) / `.4.0/24` (2b) → all cluster nodes; egress via per-AZ NAT.
- `cluster-node-sg` is wide-open intra-cluster; `bastion-node-sg` opens 22/ICMP only to the operator's current public IP (resolved at apply time via `data.http.my_ip` → `ifconfig.me`). **Re-apply when your IP changes** or SSH will break.

**Control plane** — **one master** in 2a private subnet (`ap-northeast-2a-master-01`). No NLB; `controlPlaneEndpoint` is the master's private IP directly. Single point of failure by design.

**Workers** — 2 in 2a, 3 in 2b. Each has a 20GB EBS volume attached at `/dev/sdh` (for local PV / longhorn-style use; not formatted by Ansible).

**Storage** — one EFS file system with mount targets in both private subnets (`storage.tf`), reachable from anything in the VPC on TCP 2049.

**Tags** — every cluster node carries `kubernetes.io/cluster/kt-cloud-cluster: owned`; subnets carry `kubernetes.io/role/elb: 1`. AWS Load Balancer Controller relies on these for discovery — preserve them on any new instance/subnet resources.

**Cloud integration** — kubelet runs with `--cloud-provider=external` on every node and is given `--provider-id=aws:///<az>/<instance-id>` at kubeadm init / ASG join time. For ASG workers the values are written from `terraform/templates/worker-userdata.sh.tftpl` **into `/etc/sysconfig/kubelet`** as `KUBELET_EXTRA_ARGS`, not a `/etc/systemd/system/kubelet.service.d/*.conf` drop-in: the kubelet rpm's `10-kubeadm.conf` ends with `EnvironmentFile=-/etc/sysconfig/kubelet`, and per systemd semantics `EnvironmentFile=` always wins over a drop-in's `Environment=` regardless of file ordering — so a drop-in approach is silently clobbered by the empty sysconfig file. The out-of-tree AWS CCM (`roles/aws_ccm`) runs as a DaemonSet on the master with `--configure-cloud-routes=false` (Calico handles pod NW) and removes the `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` taint that kubelet adds at registration. Pre-setting providerID via kubelet flags means AWS LBC can resolve Node → EC2 InstanceID immediately even before CCM finishes — this is the load-bearing piece for `targetType: instance` NodePort registration. CCM IAM permissions live in the IRSA role under `terraform/irsa.tf`, not on the node role.

## Ansible playbook order (`site.yaml` imports)

1. `playbooks/bootstrap.yaml` (hosts: `all`) — `k8s_prereqs` (swapoff, kernel modules, sysctl, `/etc/hosts` master entry), `k8s_packages` (kubelet/kubeadm/kubectl), `containerd` (CRI).
2. `playbooks/control-plane.yaml` (hosts: `master`) — `kubeadm_init` (renders `kubeadm-config.yaml.j2` with `controlPlaneEndpoint: <master-private-ip>:6443`, runs `kubeadm init`, sets up `~/.kube/config` for `ec2-user`), `cni_calico` (applies Calico v3.27.0 manifest), `k8s_python` (python deps for `kubernetes.core.*` modules).
3. `playbooks/workers.yaml` (hosts: `workers`) — `kubeadm_join_worker` generates a join token on master and runs `kubeadm join` on each worker.
4. `playbooks/addons.yaml` (hosts: `master`) — split into two plays. **Play 1** runs `helm` then `aws_ccm` (Helm-installs the out-of-tree AWS Cloud Controller Manager and blocks until the `node.cloudprovider.kubernetes.io/uninitialized` taint is gone from every node — this must come first because CoreDNS won't schedule until that taint is removed). **Play 2** waits for all kube-system pods Running, then runs `aws_lbc` (Helm-installs `aws-load-balancer-controller` in `kube-system` with `clusterName: kt-cloud-cluster`), `argocd` (installs ArgoCD via Helm with `--rootpath=/argocd --insecure`, creates `root-app` Application pointing at the external manifest repo `https://github.com/kanei0415/ktcloud-k8s-argocd-manifest.git`, **deletes the ALB controller's mutating/validating webhooks first** as a workaround — keep that step). `traefik` runs only when `deploy_traefik: true`.

`playbooks/clean.yaml` (hosts: `all`) — `k8s_clear` runs `kubeadm reset` and wipes `/etc/kubernetes`, `/var/lib/etcd`, CNI ifaces.

## Inventory wiring — non-obvious bits

`modules/ansible-inventory/inventory.tftpl` → `ansible/inventory.ini` is the single source of truth for group membership and SSH:

- Groups: `master` (singleton — `ap-northeast-2a-master-01`), `ap-northeast-2a-workers`, `ap-northeast-2b-workers`, and a `workers:children` group that unions both worker groups for the worker playbook.
- Every group reaches its nodes via a `ProxyCommand` jumping through the single **2b** bastion (`bastion_b_ip` in the inventory). `cluster-node-sg` is wide-open intra-VPC so the 2b bastion can SSH into the 2a master without an SG hop.
- Group-level vars `vpc_id` and `master_private_ip` are exported under `[all:vars]` — `aws_lbc` role consumes `vpc_id`; `k8s_prereqs` derives the master entry for `/etc/hosts` via `hostvars[groups['master'][0]].ansible_host`.

When adding a node in Terraform, you must update **both** `terraform/locals.tf` (`nodes` map) and `terraform/modules/ansible-inventory/main.tf` (to pass its IP into the template) and `terraform/modules/ansible-inventory/inventory.tftpl` (to place it in a group).

## Conventions to preserve

- **Resource naming**: `ap-northeast-2{a,b}-{master,worker,bastion}-NN`. Keep this; the inventory template, instance tags, and outputs all reference these names.
- **Hardcoded names that matter**: cluster name `kt-cloud-cluster` (in instance tags and `aws_lbc` role), key name `ktcloud-bastion-node-key` (in `~/.ssh/` and `aws_key_pair`), IAM role `ktcloud-cluster-node-role` (Terraform-managed), EFS creation token `kt_cloud_cluster_efs`. Renaming any of these requires a coordinated multi-file change.
- **Playbook task names are in Japanese.** New tasks should match — keeps `ansible-playbook` output coherent for the team reading it.
- **`become:` discipline**: `argocd`, `aws_lbc`, `traefik` roles all run Helm against the kubeconfig at `/home/ec2-user/.kube/config` — not as root. Other infra-level roles use `become: true`. Don't flip these without reason.

## Post-apply verification

```bash
make verify
# expects: 1 control-plane + 5 worker nodes, all Ready
# pods -A: kube-system (calico, coredns, kube-proxy, aws-load-balancer-controller),
#          argocd (server, repo-server, application-controller, redis, etc.)
```

If the `argocd` namespace gets stuck deleting:

```bash
kubectl get ns argocd -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
```
