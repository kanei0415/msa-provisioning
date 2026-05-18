# kt-cloud-cluster 構築レポート

AWS 上に kubeadm ベースのシングル master Kubernetes クラスタを構築するための Terraform + Ansible 構成の設計判断とトラブルシューティング集。

---

## 1. 全体像

### 目的

- EKS を使わず EC2 上に **自己管理型 Kubernetes クラスタ** を構築する。
- インフラ層 (Terraform) と OS 構成・クラスタブートストラップ (Ansible) を明確に分離。
- ArgoCD による GitOps でアプリ層は外部 manifest リポジトリから同期。

### スコープ

| 層 | 採用技術 | 備考 |
|---|---|---|
| クラウド | AWS `ap-northeast-2` | VPC / EC2 / EFS / IAM |
| IaC | Terraform `>= 1.10`, AWS provider `~> 5.80` | state は S3 backend |
| 構成管理 | Ansible (collections: ansible.posix, community.general, kubernetes.core, amazon.aws) | per-AZ bastion + ProxyCommand |
| OS | Amazon Linux 2023 | data source で latest AMI を解決 |
| CRI | containerd (`SystemdCgroup = true`) | dnf install + 設定書き換え |
| Kubernetes | `v1.30` | kubeadm |
| CNI | Calico `v3.27.0` | upstream manifest を `kubectl apply` |
| GitOps | ArgoCD | `--rootpath=/argocd --insecure` |
| 補助 | AWS Load Balancer Controller | `kube-system` namespace |
| 補助（option） | Traefik | `deploy_traefik: true` で有効化 |

---

## 2. ネットワークトポロジ

```
VPC 10.0.0.0/16  (ap-northeast-2)
├── Internet Gateway
│
├── ap-northeast-2a
│   ├── public  10.0.1.0/24
│   │   ├── bastion-a  (EIP, ifconfig.me/32 から 22/icmp 許可)
│   │   └── NAT GW-a   (EIP)
│   └── private 10.0.2.0/24
│       ├── master-01     (control plane, kubeadm init)
│       ├── worker-01
│       └── worker-02
│
└── ap-northeast-2b
    ├── public  10.0.3.0/24
    │   ├── bastion-b
    │   └── NAT GW-b
    └── private 10.0.4.0/24
        ├── worker-01
        ├── worker-02
        └── worker-03
```

### Route tables

- public RT: `0.0.0.0/0 → IGW`
- private RT (per AZ): `0.0.0.0/0 → NAT GW (同 AZ)`

### Security groups

| SG | Ingress | Egress |
|---|---|---|
| `kt_cloud_vpc_bastion_node_sg` | 22, ICMP from `<operator current IP>/32` | all |
| `kt_cloud_vpc_cluster_node_sg` | all from `0.0.0.0/0` | all |
| `kt_cloud_cluster_efs_sg` | 2049/tcp from VPC CIDR | (default) |

`cluster-node-sg` は VPC 内通信に必要な全プロトコル（kubelet 10250, etcd 2379-2380, NodePort 30000-32767, CNI VXLAN, etc.）を網羅するために実用上 wide-open。production 向けに絞る場合は kubeadm のポート要件を参照。

---

## 3. コンピューティング

### インスタンス一覧 (`terraform/locals.tf` の `nodes` map)

| 名前 | AZ | role | instance_type | subnet | EBS |
|---|---|---|---|---|---|
| `ap-northeast-2a-master-01` | 2a | master | `t3.medium` | private | (root 30GB) |
| `ap-northeast-2a-worker-01` | 2a | worker | `t3.large` | private | root 30GB + sdh 20GB |
| `ap-northeast-2a-worker-02` | 2a | worker | `t3.large` | private | root 30GB + sdh 20GB |
| `ap-northeast-2b-worker-01` | 2b | worker | `t3.large` | private | root 30GB + sdh 20GB |
| `ap-northeast-2b-worker-02` | 2b | worker | `t3.large` | private | root 30GB + sdh 20GB |
| `ap-northeast-2b-worker-03` | 2b | worker | `t3.large` | private | root 30GB + sdh 20GB |
| `ap-northeast-2a-bastion` | 2a | bastion | `t3.nano` | public | root 10GB |
| `ap-northeast-2b-bastion` | 2b | bastion | `t3.nano` | public | root 10GB |

すべて Amazon Linux 2023。bastion 以外は `ktcloud_cluster_node_profile` (IAM Role `ktcloud-cluster-node-role` 由来) を attach。

### ストレージ

- worker の `/dev/sdh` (20GB gp3 EBS) は formatting 未実行。ローカル PV や Longhorn 等のブロックストレージで使うことを想定。
- EFS は両 AZ に mount target を持つ。RWX が必要な workload はこちらを使う。

---

## 4. なぜシングル master か

旧構成では 3 master + NLB の HA control plane を構築していたが、以下の理由で **シングル master + NLB 撤去** に変更:

1. **AWS NLB の hairpin 不安定性** — `target_type=ip` でも `target_type=instance` でも、master 自身が NLB DNS で apiserver に到達しようとすると断続的に接続不可になる事象を観測。haproxy/loopback alias 等のワークアラウンドは複雑化を招くだけで根治しない。
2. **学習・開発用途** — 完全 HA は不要で、SPOF を受け入れる代わりに構成を大幅に簡素化したい。
3. **コスト** — master 3 台 + NLB の継続コストが用途に対して過剰。

トレードオフ:

- ✅ kubeadm config / Ansible playbook / Makefile が大幅にシンプルになった。
- ✅ `master_loopback_hosts` / `kubeadm_join_master` role が不要になり、`/etc/hosts` の NLB DNS override や haproxy も消えた。
- ❌ master ノードが落ちると apiserver が止まる。control plane backup 戦略は etcd snapshot を別途定期取得することを推奨。
- ❌ master が AZ 障害で巻き込まれると影響が大きい (workers は AZ 分散しているがアクセスできない)。

---

## 5. クラスタブートストラップの順序

`site.yaml` は以下 4 playbook を順に import:

### 5.1 `playbooks/bootstrap.yaml` (hosts: `all`)

- `k8s_prereqs`: swapoff, `overlay`/`br_netfilter` kernel modules, sysctl (`net.bridge.bridge-nf-call-iptables=1`, `net.ipv4.ip_forward=1`), `/etc/hosts` に master と self のエントリを追加。
- `k8s_packages`: 公式 yum リポジトリを `/etc/yum.repos.d/kubernetes.repo` に追加し `kubelet kubeadm kubectl` を `dnf install`。`kubelet` は enable のみ（start は join 後）。
- `containerd`: `dnf install containerd` → `containerd config default > /etc/containerd/config.toml` → `SystemdCgroup = true` に書き換え → restart。

### 5.2 `playbooks/control-plane.yaml` (hosts: `master`)

- `kubeadm_init`:
  - `kubeadm-config.yaml.j2` を render (`controlPlaneEndpoint: {{ ansible_default_ipv4.address }}:6443`, `podSubnet: 192.168.0.0/16`, `cgroupDriver: systemd`, certSANs に master private IP / 127.0.0.1 / localhost)。
  - `kubeadm init --config /etc/kubernetes/kubeadm-config.yaml`。
  - `admin.conf` を `/home/ec2-user/.kube/config` にコピー。
  - `kubectl --kubeconfig=admin.conf get --raw=/livez` を 60 回 retry で待つ。
- `cni_calico`: upstream Calico manifest を download → `127.0.0.1:6443/livez` で apiserver の準備を待つ → `kubectl apply` → master ノードが Ready になるまで待機。
- `k8s_python`: `python3-pip` + `kubernetes` / `PyYAML` を pip install (`kubernetes.core.*` モジュールのため)。

### 5.3 `playbooks/workers.yaml` (hosts: `workers`)

- `kubeadm_join_worker`:
  - `delegate_to: master` で `kubeadm token create --print-join-command` を実行し、stdout を全 worker に fact として配布。
  - 各 worker で `<join command> --cri-socket unix:///var/run/containerd/containerd.sock` を実行。`'already exists'` を含む stderr は冪等性のため許容。

### 5.4 `playbooks/addons.yaml` (hosts: `master`)

- `helm`: `https://get.helm.sh/helm-{{ helm_version }}-linux-amd64.tar.gz` を /usr/local/bin に配置。
- `aws_lbc`: EKS Helm chart repo を登録し、 `aws-load-balancer-controller` を `kube-system` に install (`clusterName`, `vpcId`, `region` を override)。
- `argocd`: ArgoCD namespace 作成 → ALB controller の MutatingWebhookConfiguration / ValidatingWebhookConfiguration を削除（残骸対策） → ArgoCD Helm chart install → CRD 登録を待機 → `root-app` Application を `https://github.com/kanei0415/ktcloud-k8s-argocd-manifest.git` の `Setup/` に向けて作成（auto-sync, prune, selfHeal）。
- `traefik`: `deploy_traefik: true` の時のみ。Traefik chart を `traefik` namespace に install し、Service annotation で AWS LBC 経由の external NLB を生成。

---

## 6. controlPlaneEndpoint の設計

シングル master では `controlPlaneEndpoint` は master の private IP を直接指す:

```yaml
controlPlaneEndpoint: "{{ ansible_default_ipv4.address }}:6443"
apiServer:
  certSANs:
    - "{{ ansible_default_ipv4.address }}"
    - "127.0.0.1"
    - "localhost"
```

これにより:

- worker の `kubeadm join` は master private IP に対して直接接続する (VPC 内なので問題なし)。
- master 自身からの kubectl は `127.0.0.1:6443` か kubeconfig の private IP どちらでも cert SAN に含まれている。
- ローカル端末から `make get-kubeconfig` + `make kube-tunnel` で SSH トンネルを張る場合、 `127.0.0.1` を master private IP として `/etc/hosts` に書けば cert を通せる。

---

## 7. インベントリ生成

Terraform の `modules/ansible-inventory` モジュールが `inventory.tftpl` を render して `ansible/inventory.ini` を **書き出す** (state 内で `local_file` を作成する)。

`inventory.ini` の構造:

```ini
[master]
master ansible_host=<master-private-ip>

[ap-northeast-2a-workers]
<2a-worker-01-private-ip>
<2a-worker-02-private-ip>

[ap-northeast-2b-workers]
<2b-worker-01-private-ip>
<2b-worker-02-private-ip>
<2b-worker-03-private-ip>

[workers:children]
ap-northeast-2a-workers
ap-northeast-2b-workers

[master:vars]
ansible_ssh_common_args='-o ProxyCommand="ssh -W %h:%p -q ec2-user@<bastion-a-public-ip> -i ~/.ssh/ktcloud-bastion-node-key"'

# (per-AZ workers も同様に各 AZ の bastion を ProxyCommand に指定)

[all:vars]
ansible_port=22
ansible_user=ec2-user
ansible_ssh_private_key_file=~/.ssh/ktcloud-bastion-node-key
vpc_id=<vpc-id>
master_private_ip=<master-private-ip>
```

`master` グループは 2a bastion 経由で SSH する (master が 2a private subnet にいるため)。

---

## 8. 既知の問題と回避策

### 8.1 ALB Controller webhook が ArgoCD install を阻害する

`argocd` role は事前に以下を `state: absent` で削除する task を持つ:

- `MutatingWebhookConfiguration/mservice.elbv2.k8s.aws`
- `ValidatingWebhookConfiguration/vservice.elbv2.k8s.aws`

これがないと ArgoCD の `Application` リソース作成時に LBC の webhook が認証で詰まる事象が観測される。

### 8.2 bastion SG が operator の現在の IP に固定される

`data.http.my_ip` (`ifconfig.me`) で取得した `/32` を ingress に書き込んでいるため、 operator の global IP が変わると bastion SSH ができなくなる。 `terraform apply` を再実行すれば新しい IP で SG が更新される。

### 8.3 `argocd` namespace の finalizer 残留

namespace 削除が finalizer で stuck する場合は:

```bash
kubectl get ns argocd -o json | jq '.spec.finalizers = []' \
  | kubectl replace --raw "/api/v1/namespaces/argocd/finalize" -f -
```

---

## 9. リソースの最終姿

| AWS resource | 数 |
|---|---|
| VPC | 1 |
| Subnet (public/private × AZ) | 4 |
| Internet Gateway | 1 |
| NAT Gateway (+ EIP) | 2 |
| Route table (public 1 + private per-AZ 2) | 3 |
| EC2 (master 1 + worker 5 + bastion 2) | 8 |
| EBS volume (root 8 + sdh 5) | 13 |
| EFS (file system + mount targets per AZ) | 1 + 2 |
| Security group | 3 |
| IAM Instance Profile | 1 (data source の Role を参照) |
| Key Pair | 1 |

---

## 10. 参考リンク

- kubeadm: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/
- Calico: https://docs.tigera.io/calico/latest/getting-started/kubernetes/quickstart
- AWS Load Balancer Controller: https://kubernetes-sigs.github.io/aws-load-balancer-controller/
- ArgoCD: https://argo-cd.readthedocs.io/
- ArgoCD root-app manifest repo: https://github.com/kanei0415/ktcloud-k8s-argocd-manifest
