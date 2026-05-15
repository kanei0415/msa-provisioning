# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo does

Two-stage IaC that stands up a **self-managed, multi-AZ kubeadm Kubernetes cluster on EC2** (not EKS) in `ap-northeast-2`, then layers on AWS Load Balancer Controller and an ArgoCD-managed GitOps root app. Terraform provisions AWS infra; Ansible bootstraps the cluster. The README is in Japanese — match that language/tone when editing it or authoring new playbook task names.

## Provisioning workflow (end-to-end)

The pipeline is **strictly ordered**; later stages assume earlier outputs:

1. `bash ssh-key-gen.bash` — creates `~/.ssh/ktcloud-bastion-node-key{,.pub}`. Required before `terraform apply`: the `.pub` is read by `aws_key_pair`, and the private key path is hardcoded into `inventory.tftpl`.
2. `cd terraform && cp backend.tfvars.sample backend.tfvars` and fill in the S3 `bucket`. Then `terraform init -backend-config=backend.tfvars -migrate-state`.
3. `terraform plan` / `terraform apply` — provisions VPC, subnets, NAT, EC2, EFS, NLB, and **writes `ansible/inventory.ini`** via `ansible.tf` (templated from `inventory.tftpl`).
4. **Manually SSH to both bastions once** (using the two `*-bastion-node-connect-command` outputs) to accept host fingerprints. Ansible's ProxyCommand will hang otherwise.
5. `cd ansible && ansible all -m ping -i inventory.ini` — sanity check.
6. `ansible-playbook -i inventory.ini main.yaml` — runs the full bring-up (see playbook order below).
7. To tear down the K8s layer without destroying EC2: `ansible-playbook -i inventory.ini k8s-clear.yaml` (resets kubeadm, wipes `/etc/kubernetes`, `/var/lib/etcd`, CNI ifaces). Useful for re-running `main.yaml` cleanly.

For full destroy: `terraform destroy` (after `k8s-clear.yaml` if you want a graceful teardown).

## Out-of-band prerequisites (not created by this repo)

- **IAM role `ktcloud-cluster-node-role`** must already exist — `terraform/iam.tf` uses a `data` source, not a resource. It needs the AWS Load Balancer Controller policy from https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/main/docs/install/iam_policy.json attached, plus permissions referenced in the README.
- **AWS CLI credentials** for an IAM principal with the policies listed in `README.md` (EC2/VPC/ELB/EFS/IAM-PassRole). Configure via `aws configure`.
- **S3 bucket** for Terraform remote state (referenced by `backend.tfvars`).

## Architecture cheat sheet

**Topology** — single VPC `10.0.0.0/16`, mirrored per AZ (`2a`, `2b`):
- Public subnets `.1.0/24` (2a) / `.3.0/24` (2b) → bastions + NAT GWs + NLB ENIs.
- Private subnets `.2.0/24` (2a) / `.4.0/24` (2b) → all cluster nodes; egress via per-AZ NAT.
- `cluster-node-sg` is wide-open intra-cluster; `bastion-node-sg` opens 22/ICMP only to the operator's current public IP (resolved at apply time via `data.http.my_ip` → `ifconfig.me`). **Re-apply when your IP changes** or SSH will break.

**Control plane** — three masters fronted by an external Network Load Balancer:
- `ap-northeast-2a-master-node-01` (a-master-01)
- `ap-northeast-2a-master-node-02` (a-master-02)
- `ap-northeast-2b-master-node-01` (b-master-01) — **this is `main-master`**, the host that runs `kubeadm init` and brokers join tokens for everyone else
- NLB listener `:6443` → target group with all three masters; `controlPlaneEndpoint` in `kubeadm-config.yaml.j2` resolves to the NLB DNS

**Workers** — 1 in 2a, 2 in 2b. Each has a 20GB EBS volume attached at `/dev/sdh` (for local PV / longhorn-style use; not formatted by Ansible).

**Storage** — one EFS file system with mount targets in both private subnets (`storage.tf`), reachable from anything in the VPC on TCP 2049.

**Tags** — every cluster node carries `kubernetes.io/cluster/kt-cloud-cluster: owned`; subnets carry `kubernetes.io/role/elb: 1`. AWS Load Balancer Controller relies on these for discovery — preserve them on any new instance/subnet resources.

## Ansible playbook order (`main.yaml`)

Each line is a separate playbook; they must run in this sequence:

1. `k8s-pre-setup.yaml` — swapoff, kernel modules (`overlay`, `br_netfilter`), `/etc/hosts` entries for the 3 masters. Runs on **all** hosts.
2. `k8s-pkg-install.yaml` — installs kubeadm/kubelet/kubectl packages.
3. `containerd-setup.yaml` — installs and configures containerd as the CRI.
4. `master-init.yaml` — **`main-master` only**: renders `configuration/kubeadm-config.yaml.j2` (uses `{{ nlb_dns_name }}` for `controlPlaneEndpoint` and certSAN, podSubnet `192.168.0.0/16`, `cgroupDriver: systemd`), runs `kubeadm init --upload-certs`, sets up `~/.kube/config` for `ec2-user`.
5. `master-cni-setup.yaml` — applies **Calico v3.27.0** manifest from upstream.
6. `master-python-setup.yaml` — installs python deps so the `kubernetes.core.*` modules work on the master.
7. `join-master.yaml` — on `main-master`, generates a fresh cert key and join command, stashes them on a synthetic in-memory host `K8S_VARS_HOLDER` via `add_host`, then 2a masters consume those via `hostvars['K8S_VARS_HOLDER']` to join as control planes. **Re-running tolerates "already exists" via `failed_when`.**
8. `join-worker.yaml` — same pattern for workers.
9. `helm-setup.yaml` — installs Helm on the master.
10. `nlb-setup.yaml` — Helm-installs `aws-load-balancer-controller` in `kube-system` with `clusterName: kt-cloud-cluster`, `vpcId` from inventory, `region: ap-northeast-2`.
11. `argocd-setup.yaml` — installs ArgoCD via Helm (NodePort 30080, `--rootpath=/argocd --insecure`), then creates a `root-app` Application pointing at the external manifest repo `https://github.com/kanei0415/ktcloud-k8s-argocd-manifest.git` (path `Setup`, auto-sync with prune+selfHeal). **Deletes the ALB controller's mutating/validating webhooks first** as a workaround — keep that step when modifying this file.

`traefik-setup.yaml` exists but is **not** wired into `main.yaml`; it's standalone.

## Inventory wiring — non-obvious bits

`inventory.tftpl` → `ansible/inventory.ini` is the single source of truth for group membership and SSH:

- Groups: `ap-northeast-2a-masters`, `ap-northeast-2a-workers`, `main-master` (singleton — `b-master-01`), `ap-northeast-2b-workers`. **There is no `ap-northeast-2b-masters` group** — `b-master-01` lives only in `main-master`. Don't break this assumption; playbooks like `master-init.yaml` target `hosts: main-master` specifically.
- Each non-main group reaches its nodes via a per-AZ `ProxyCommand` jumping through that AZ's bastion. The `main-master` group jumps through the **2b** bastion.
- Group-level vars `nlb_dns_name`, `control_plane_endpoint`, `vpc_id`, `a_master_01_private_ip`, `a_master_02_private_ip`, `b_master_01_private_ip` are exported under `[all:vars]` — playbooks consume them directly (e.g., `kubeadm-config.yaml.j2` uses `nlb_dns_name`; `nlb-setup.yaml` uses `vpc_id`; `k8s-pre-setup.yaml` uses the master IPs for `/etc/hosts`).

When adding a node in Terraform, you must update **both** `2x-ec2.tf` and `terraform/ansible.tf` (to pass its IP into the template) and `terraform/inventory.tftpl` (to place it in a group).

## Conventions to preserve

- **Per-AZ file pairs**: `2a-ec2.tf`/`2b-ec2.tf`, `2a-subnet.tf`/`2b-subnet.tf`, `2a-nat.tf`/`2b-nat.tf` mirror each other. When adding a symmetric resource, edit both; when adding something AZ-specific, follow the existing asymmetry (e.g., 2b has an extra master and an extra worker on purpose).
- **Resource naming**: `ap-northeast-2{a,b}-{master,worker,bastion}-node-NN`. Keep this; the inventory template, NLB attachments, and tags all reference these names.
- **Hardcoded names that matter**: cluster name `kt-cloud-cluster` (in instance tags and `nlb-setup.yaml`), key name `ktcloud-bastion-node-key` (in `~/.ssh/` and `aws_key_pair`), IAM role `ktcloud-cluster-node-role` (data lookup), EFS creation token `kt-cloud-cluster-efs`. Renaming any of these requires a coordinated multi-file change.
- **Playbook task names are in Japanese.** New tasks should match — keeps `ansible-playbook` output coherent for the team reading it.
- **`become:` discipline**: `argocd-setup.yaml` and `nlb-setup.yaml`'s Helm work runs against the kubeconfig at `/home/ec2-user/.kube/config` — not as root. Other infra-level playbooks use `become: true`. Don't flip these without reason.

## Post-apply verification

```
# from main-master (b-master-01) via the 2b bastion:
ssh-add ~/.ssh/ktcloud-bastion-node-key
# use the main-master-node-connect-command output, then:
kubectl get nodes                                                   # expect 3 control-plane + 3 worker, all Ready
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
argocd login <b-master-01-ip>:30080 --username admin --insecure     # password from argocd-initial-admin-secret
argocd app list && argocd app sync root-app --prune                 # Traefik can take 5+ min to go Healthy
```

If the `argocd` namespace gets stuck deleting:

```
kubectl get ns argocd -o json | jq '.spec.finalizers = []' | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
```
