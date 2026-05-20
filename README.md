# kt-cloud-cluster

AWS 上に **kubeadm ベースの自己管理型シングル master Kubernetes クラスタ** を `ap-northeast-2` に立ち上げるための Terraform + Ansible 構成。EKS は使わず、EC2 で 1 master + 5 worker（マルチ AZ）を立て、AWS Load Balancer Controller と ArgoCD（GitOps）を載せる。

クラスタ名: `kt-cloud-cluster`
Kubernetes: `v1.30`
CNI: Calico `v3.27.0`
GitOps: ArgoCD（`https://github.com/kanei0415/ktcloud-k8s-argocd-manifest.git` を root app に同期）

設計判断とトラブルシューティングは [`PROVISIONING_REPORT.md`](./PROVISIONING_REPORT.md) を参照。

---

## トポロジ

```
VPC 10.0.0.0/16  (ap-northeast-2)
├── ap-northeast-2a
│   ├── public  10.0.1.0/24   → bastion-a (NAT GW-a)
│   └── private 10.0.2.0/24   → master, worker-01, worker-02
└── ap-northeast-2b
    ├── public  10.0.3.0/24   → bastion-b (NAT GW-b)
    └── private 10.0.4.0/24   → worker-01, worker-02, worker-03
```

- **master** は 2a の private subnet に 1 台のみ。HA 用 NLB はなし（controlPlaneEndpoint は master の private IP を直接指定）。
- **worker** は 2a に 2 台、2b に 3 台。
- bastion は AZ ごとに 1 台。Ansible の ProxyCommand が各 AZ の private subnet にいるノードに per-AZ で SSH する。
- EFS は両 AZ にマウントターゲットを持つので worker からの NFS マウントは AZ を問わない。

---

## クイックスタート

すべての操作は **Makefile** にラップされています。

```bash
make help            # 利用可能なターゲットを表示
```

### 0 からフル構築

```bash
# 1. 前提コマンドの確認
make check-prereqs

# 2. SSH キーペアを生成（既存なら skip）
make ssh-key

# 3. terraform/backend.tfvars を作成（S3 bucket を埋める）
cp terraform/backend.tfvars.sample terraform/backend.tfvars
$EDITOR terraform/backend.tfvars

# 4. Terraform init
make tf-init

# 5. AWS インフラ作成（VPC / EC2 / EFS / IAM 結線）
make tf-apply

# 6. bastion の host key を受理（ProxyCommand 用）
make bastion-accept

# 7. Ansible 疎通確認
make ansible-ping

# 8. クラスタ立ち上げ
make cluster-up

# 9. 検証
make verify
```

`make all` で 1〜9 を一括実行できます（`backend.tfvars` だけ事前に必要）。

---

## ローカルから kubectl を使う

```bash
# admin.conf をローカルに取得（./.kube/config）
make get-kubeconfig

# bastion → master への SSH トンネルを張る
make kube-tunnel     # フォアグラウンドで動き続けるので別 terminal を用意

# 別 terminal で
sudo sh -c 'echo "127.0.0.1 <master-private-ip>" >> /etc/hosts'
export KUBECONFIG=$PWD/.kube/config
kubectl get nodes
```

`make kube-tunnel` は `inventory.ini` から master の private IP を読んでトンネルを張ります。kubeconfig は `https://<master-private-ip>:6443` を指しているので、 `/etc/hosts` で master private IP を `127.0.0.1` に向けることで証明書 SAN が通ります（certSANs に master の private IP を含めている）。

---

## ArgoCD ダッシュボードへのアクセス

ArgoCD は **ClusterIP** で `argocd` namespace に入っており、 `--rootpath=/argocd --insecure` で起動しています。外部公開はあえてしておらず、操作端末からは port-forward 経由でアクセスします。

```bash
# admin パスワードを表示
make argocd-password

# master 上で kubectl port-forward → bastion 経由でローカル 8443 に転送
make argocd-port-forward
# このコマンドは SSH トンネルを張ったままになります。
# 別 terminal で表示される手順 (kubectl port-forward) を実行してください。
```

ブラウザで `http://localhost:8443/argocd` を開き、 `admin / <make argocd-password の出力>` でログインします。

argocd CLI を使う場合:

```bash
make argocd-cli              # 手順を表示
```

---

## 部分的に playbook を流す

`site.yaml` は以下 4 つの playbook の集合です。個別に流すことができます。

| Makefile target | 対応 playbook | 内容 |
|---|---|---|
| `make cluster-bootstrap` | `playbooks/bootstrap.yaml` | swapoff / kernel modules / kubelet / kubeadm / kubectl / containerd |
| `make cluster-control-plane` | `playbooks/control-plane.yaml` | `kubeadm init` → Calico CNI |
| `make cluster-workers` | `playbooks/workers.yaml` | worker の `kubeadm join` |
| `make cluster-addons` | `playbooks/addons.yaml` | Helm / AWS LBC / ArgoCD（root-app 作成） |
| `make cluster-clear` | `playbooks/clean.yaml` | `kubeadm reset` + `/etc/kubernetes`, `/var/lib/etcd`, CNI iface 削除 |

`make cluster-up` は `site.yaml` を直接流します。

---

## 破棄

```bash
make destroy-all     # cluster-clear → terraform destroy
```

`tf-destroy` 単体でも EC2/VPC は破棄できますが、 ArgoCD が AWS リソース（LoadBalancer など）を作っていた場合は先に `cluster-clear` で kubeadm reset を流してから terraform destroy する方が綺麗です。

---

## ディレクトリ構造

```
.
├── Makefile                 # すべての操作のエントリポイント
├── README.md                # 本ファイル
├── PROVISIONING_REPORT.md   # 構築レポート（日本語、詳細解説）
├── CLAUDE.md                # AI agent 向けプロジェクト指示書
├── ssh-key-gen.bash         # SSH キーペア生成スクリプト
├── terraform/               # AWS インフラ定義
│   ├── ec2.tf / sgs.tf / vpc.tf / subnets.tf / nat.tf
│   ├── storage.tf           # EFS
│   ├── main.tf              # ansible-inventory モジュール呼び出し
│   ├── modules/ansible-inventory/   # inventory.ini を生成
│   └── backend.tfvars.sample
└── ansible/
    ├── site.yaml            # 全 playbook を import
    ├── inventory.ini        # terraform apply で生成（コミット不要）
    ├── group_vars/all.yaml
    └── playbooks/
        ├── bootstrap.yaml
        ├── control-plane.yaml
        ├── workers.yaml
        ├── addons.yaml
        └── clean.yaml
    └── roles/
        ├── k8s_prereqs/
        ├── k8s_packages/
        ├── containerd/
        ├── kubeadm_init/
        ├── kubeadm_join_worker/
        ├── cni_calico/
        ├── k8s_python/
        ├── helm/
        ├── aws_lbc/
        ├── argocd/
        ├── traefik/
        └── k8s_clear/
```

---

## 既知の制約

- aws-load-balancer-controller の webhook が ArgoCD インストールを阻害する場合があります。 `argocd` role は事前に webhook を削除する task を持っているのでそのまま運用してください。
- IAM Role / Policy はすべて Terraform 管理に移行済みです（旧構成で要求していた `ktcloud-cluster-node-role` の事前作成は不要になりました）。LBC / CCM / cluster-autoscaler / EBS-CSI / external-secrets はそれぞれ IRSA Role を `terraform/irsa.tf` で作成し、`make tf-apply` 一発で揃います。
- bastion SG は `ifconfig.me` で解決される現在のグローバル IP のみを許可します。IP が変わったら `terraform apply` を再実行してください。
- シングル master 構成です。control plane は SPOF。master ノードが落ちると apiserver が止まります。学習・開発用途に最適化されています。

---

## 詳細・トラブルシューティング

- 構築の全体像、設計判断は [`PROVISIONING_REPORT.md`](./PROVISIONING_REPORT.md) を参照。
- AI agent（Claude Code）向けの操作指針は [`CLAUDE.md`](./CLAUDE.md) を参照。
