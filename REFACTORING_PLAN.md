# リファクタリング計画書

このドキュメントは `./terraform` と `./ansible` を最新のベストプラクティスへ段階的に改善するための学習・実装プランです。
**「動くもの」から「読みやすく・安全で・モダンなもの」へ** を目標に、各フェーズで「何を」「なぜ」「どう」変えるかを明記します。

---

## 0. 全体方針

### 0-1. ゴール

| ゴール | 詳細 |
|---|---|
| 学習 | Terraform / Ansible の 2025 年時点のモダンな書き方を一通り経験する |
| 重複の排除 | `2a-*.tf` と `2b-*.tf`、似たような Playbook の copy-paste を **`for_each` / ループ / role** で集約する |
| 安全性 | 0.0.0.0/0 全開の SG、ハードコードされた AMI、平文の token 受け渡しを直す |
| 再現性 | 静的解析・CI を入れて、壊れた状態をマージできないようにする |
| 可逆性 | リファクタ中に既存リソースを **destroy せずに移行** する（`moved` / `removed` ブロックを使う） |

### 0-2. 段階的に進める

一気にやらない。**1 フェーズ＝ 1 PR** を強く推奨。
各フェーズで以下を必ず確認すること。

- `terraform plan` の差分が `No changes` か、想定どおりの差分か（refactor 系は `No changes` が正解）
- `ansible-playbook --check --diff main.yaml` が成功する
- 既存クラスタが壊れていない（`kubectl get nodes` ですべて `Ready`）

### 0-3. 学習の進め方の推奨順

1. **Terraform フェーズ 1～3**（構造整理・変数化）で「現状のコードを読み解く力」を付ける
2. **Terraform フェーズ 4**（`for_each`）で **HCL の表現力** を体感する
3. **Ansible フェーズ 1**（role 化）で **Ansible の標準的なディレクトリ構造** を覚える
4. その後、横断的改善 → CI → セキュリティ強化へ進む

---

## 1. Terraform リファクタリング

### 現状の問題点

| # | 問題 | 影響 |
|---|---|---|
| T1 | `variables.tf` が空。`cluster_name`, `region`, `cidr`, `ami` などがハードコード | 環境を増やすたびに全ファイル grep & 置換 |
| T2 | `2a-ec2.tf` / `2b-ec2.tf`, `2a-subnet.tf` / `2b-subnet.tf`, `2a-nat.tf` / `2b-nat.tf` が **コピペ** | AZ を 1 つ追加するだけで 6 ファイル増える |
| T3 | プロバイダのバージョン固定が無い（`required_providers` 未設定） | 半年後に `terraform init` したら別バージョンで挙動が変わる |
| T4 | `cluster-node-sg` が `0.0.0.0/0` で全 port 開放 | クラスタ内ノードが直接インターネットから攻撃可能 |
| T5 | AMI `ami-087e08db3e40f7429` がハードコード | 数か月後に AMI が deprecate されたら全 EC2 を手動更新 |
| T6 | `data.aws_iam_role.ktcloud-cluster-node-role` が外部依存（手動作成前提） | 「動かない」原因の上位。Terraform で管理すべき |
| T7 | `output.tf` が SSH コマンドを文字列で組み立てており、IP 変更に弱い | 出力をシェルで `eval` しにくい |
| T8 | モジュール分割なし。すべてフラットに root module 直下 | 再利用不可。「Stage 環境を作る」ができない |

### フェーズ T1: ファイル構造の整理（破壊なし）

**ゴール**: 役割でファイルを分離し、Terraform 標準の命名規則に合わせる。

**変更内容**

```
terraform/
├── versions.tf       # terraform { required_version, required_providers }
├── providers.tf      # provider "aws" { region = var.region }
├── variables.tf      # 入力変数の定義（後続フェーズで埋める）
├── locals.tf         # 共通の計算値（タグ、命名規則）
├── outputs.tf        # 既存 output.tf をリネーム（plural が標準）
├── main.tf           # 既存維持（key_pair + backend）
├── vpc.tf
├── subnets.tf        # 2a/2b 統合（フェーズ T4）
├── nat.tf            # 2a/2b 統合（フェーズ T4）
├── ec2.tf            # 2a/2b 統合（フェーズ T4）
├── nlb.tf            # vpc.tf から NLB 関連を分離
├── iam.tf
├── storage.tf
└── ansible.tf
```

**なぜこれがモダンか**

- HashiCorp 公式の「Standard Module Structure」に合わせると、他人（将来の自分含む）がコードを読む際に **「設定を見たい → variables.tf」「出力を見たい → outputs.tf」** と即座にたどれる
- `versions.tf` の分離は **Terraform 1.0+ 以降のデファクト**

**実装ステップ**

1. 空の `versions.tf` を作成し、以下を記述

```hcl
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.80"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
  backend "s3" {}
}
```

2. `main.tf` の `terraform { backend "s3" {} }` ブロックを削除（`versions.tf` に統合）
3. `output.tf` → `outputs.tf` にリネーム
4. `terraform init -upgrade` でロックファイルを更新
5. `terraform plan` で `No changes` を確認

**ポイント**: ファイル名変更だけでは Terraform は何も変えない。安全に試せる第一歩。

---

### フェーズ T2: 変数化（ハードコード撲滅）

**ゴール**: 環境固有の値を `variables.tf` に集約し、`terraform.tfvars` で差し替え可能にする。

**変更内容**: `variables.tf` を以下のように埋める。

```hcl
variable "project" {
  type        = string
  description = "プロジェクト識別子。タグや name prefix に使う"
  default     = "kt-cloud"
}

variable "region" {
  type        = string
  default     = "ap-northeast-2"
}

variable "availability_zones" {
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2b"]
}

variable "vpc_cidr" {
  type        = string
  default     = "10.0.0.0/16"
}

variable "cluster_name" {
  type        = string
  default     = "kt-cloud-cluster"
}

variable "master_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "worker_instance_type" {
  type    = string
  default = "t3.medium"
}

variable "bastion_instance_type" {
  type    = string
  default = "t3.nano"
}
```

そして `locals.tf` で派生値を計算：

```hcl
locals {
  common_tags = {
    Project                                     = var.project
    ManagedBy                                   = "terraform"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}
```

**AMI のハードコード解消** — 新しい `data` ソースを `ec2.tf` の頭に追加：

```hcl
data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}
```

そして `ami = "ami-087e08db3e40f7429"` を全部 `ami = data.aws_ami.amazon_linux_2023.id` に置換。

**注意**: AMI を変えると **インスタンスが再作成される**（destroy + create）。本番クラスタが動いている状態でこれをやると全ノードが吹き飛ぶ。
→ 既存環境を残すなら、まず `data` 側で **`ami-087e08db3e40f7429` を取得する条件** を書き、新規環境作成時のみ最新版を使う、という戦略にする。

具体的には変数化：

```hcl
variable "node_ami_id" {
  type        = string
  default     = null
  description = "明示的に AMI を指定したい場合。null なら最新 AL2023 を使う"
}

locals {
  node_ami = coalesce(var.node_ami_id, data.aws_ami.amazon_linux_2023.id)
}
```

`terraform.tfvars` で `node_ami_id = "ami-087e08db3e40f7429"` と書けば現状維持、外せば最新化、という挙動になる。

**なぜモダンか**

- `coalesce()` + nullable variable は **「環境ごとに差し替え可能だが既定値もある」** という最近の HCL 流儀
- `data` ソースで AMI を取るのは **Terraform AWS Provider 公式の推奨パターン**

---

### フェーズ T3: タグ戦略の統一

**ゴール**: 全リソースに同じタグを自動付与する。

**変更内容**: `providers.tf` で `default_tags` を使う。

```hcl
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Cluster   = var.cluster_name
    }
  }
}
```

→ 各リソースの `tags = {}` から **共通タグを削除できる**。
ただし `kubernetes.io/cluster/...` のようなクラスタ判別タグはリソース固有なので残す。

**なぜモダンか**

- `default_tags` は AWS Provider 3.38+ の機能で、**Provider レベルで横断的にタグを当てる** ことができる
- コスト分析・誰が作ったかの追跡で必須レベル

**注意**: `default_tags` と個別 `tags` の **重複定義は plan が perpetual diff になる**（毎回差分が出る）。重複は厳禁。

---

### フェーズ T4: `for_each` で 2a/2b の重複を一掃 ⭐ 学習のヤマ場

**ゴール**: AZ ごとに重複している `*-subnet.tf`, `*-nat.tf`, `*-ec2.tf` を 1 ファイルにまとめる。

#### 4-1: subnet

**Before** (`2a-subnet.tf` + `2b-subnet.tf` = 計 72 行)

**After** (`subnets.tf`):

```hcl
locals {
  azs = {
    "2a" = {
      az           = "ap-northeast-2a"
      public_cidr  = "10.0.1.0/24"
      private_cidr = "10.0.2.0/24"
    }
    "2b" = {
      az           = "ap-northeast-2b"
      public_cidr  = "10.0.3.0/24"
      private_cidr = "10.0.4.0/24"
    }
  }
}

resource "aws_subnet" "public" {
  for_each          = local.azs
  vpc_id            = aws_vpc.kt-cloud-vpc.id
  cidr_block        = each.value.public_cidr
  availability_zone = each.value.az
  tags = {
    Name                     = "${var.project}-public-${each.key}"
    "kubernetes.io/role/elb" = "1"
  }
}

resource "aws_subnet" "private" {
  for_each          = local.azs
  vpc_id            = aws_vpc.kt-cloud-vpc.id
  cidr_block        = each.value.private_cidr
  availability_zone = each.value.az
  tags = {
    Name                              = "${var.project}-private-${each.key}"
    "kubernetes.io/role/internal-elb" = "1"
  }
}
```

参照側は `aws_subnet.public["2a"].id`, `aws_subnet.private["2b"].id` という書き方になる。

#### 4-2: 既存状態を壊さず移行する `moved` ブロック ⭐

新しい資源名に変わったことを Terraform に教えるため、**`moved` ブロック** を使う：

```hcl
moved {
  from = aws_subnet.public-ap-northeast-2a
  to   = aws_subnet.public["2a"]
}

moved {
  from = aws_subnet.public-ap-northeast-2b
  to   = aws_subnet.public["2b"]
}

moved {
  from = aws_subnet.private-ap-northeast-2a
  to   = aws_subnet.private["2a"]
}
# ... 同様に private-2b, NAT, EIP も
```

これで `terraform plan` は **destroy/create ではなく rename のみ** を計画してくれる。

**なぜモダンか**

- `moved` ブロックは Terraform **1.1+** の機能。以前は `terraform state mv` を手動で叩く必要があった
- コード化されているので、PR レビューで「どのリソースを rename したか」が一目瞭然
- リファクタリングの第一級市民

#### 4-3: NAT GW も同じパターン

`nat.tf` 1 ファイルに集約：

```hcl
resource "aws_eip" "nat" {
  for_each = local.azs
  domain   = "vpc"
}

resource "aws_nat_gateway" "main" {
  for_each      = local.azs
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  depends_on    = [aws_internet_gateway.main_igw]
}
```

#### 4-4: EC2 は **少し複雑なのでマップを 2 段にする**

ノードは **AZ × 役割（master/worker/bastion）× 番号** で識別したい。

```hcl
locals {
  nodes = {
    "2a-master-01" = { az = "2a", role = "master", instance_type = var.master_instance_type, subnet = "private" }
    "2a-master-02" = { az = "2a", role = "master", instance_type = var.master_instance_type, subnet = "private" }
    "2a-worker-01" = { az = "2a", role = "worker", instance_type = var.worker_instance_type, subnet = "private", ebs_size = 20 }
    "2b-master-01" = { az = "2b", role = "master", instance_type = var.master_instance_type, subnet = "private" }
    "2b-worker-01" = { az = "2b", role = "worker", instance_type = var.worker_instance_type, subnet = "private", ebs_size = 20 }
    "2b-worker-02" = { az = "2b", role = "worker", instance_type = var.worker_instance_type, subnet = "private", ebs_size = 20 }
    "2a-bastion"   = { az = "2a", role = "bastion", instance_type = var.bastion_instance_type, subnet = "public" }
    "2b-bastion"   = { az = "2b", role = "bastion", instance_type = var.bastion_instance_type, subnet = "public" }
  }
}

resource "aws_instance" "node" {
  for_each = local.nodes

  ami           = local.node_ami
  instance_type = each.value.instance_type
  subnet_id = each.value.subnet == "public" ? (
    aws_subnet.public[each.value.az].id
  ) : (
    aws_subnet.private[each.value.az].id
  )
  security_groups = each.value.role == "bastion" ? (
    [aws_security_group.bastion-node-sg.id]
  ) : (
    [aws_security_group.cluster-node-sg.id]
  )
  key_name                    = aws_key_pair.bastion-node-key.key_name
  iam_instance_profile        = each.value.role == "bastion" ? null : aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  source_dest_check           = each.value.role != "bastion"
  associate_public_ip_address = each.value.role == "bastion"

  user_data = each.value.role == "master" ? <<-EOF
    #!/bin/bash
    hostnamectl set-hostname ${each.key}
  EOF : null

  tags = each.value.role != "bastion" ? {
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
    Name                                        = each.key
  } : { Name = each.key }
}

# EBS は条件付きで作る
resource "aws_ebs_volume" "worker_data" {
  for_each          = { for k, v in local.nodes : k => v if can(v.ebs_size) }
  availability_zone = "ap-northeast-${each.value.az}"
  size              = each.value.ebs_size
}

resource "aws_volume_attachment" "worker_data" {
  for_each    = aws_ebs_volume.worker_data
  device_name = "/dev/sdh"
  volume_id   = each.value.id
  instance_id = aws_instance.node[each.key].id
}
```

**学習ポイント**

- `for_each` のキーはマップでも set でもよい。**ここでは「ノード名 = キー」とすることで自然な参照ができる**
- 三項演算子は HCL の標準
- `for k, v in local.nodes : k => v if condition` は **for 内包表記** と呼ばれる。Python の dict comprehension に相当
- `can()` は属性が存在するかを true/false で返す関数

#### 4-5: NLB target_group_attachment も `for_each`

```hcl
resource "aws_lb_target_group_attachment" "k8s_api" {
  for_each         = { for k, v in local.nodes : k => v if v.role == "master" }
  target_group_arn = aws_lb_target_group.k8s-api-tg.arn
  target_id        = aws_instance.node[each.key].id
  port             = 6443
}
```

#### 4-6: `moved` を網羅して plan が `No changes` になることを確認

すべての rename を `moved` ブロックで記述してから `terraform plan` を必ず確認する。
**destroy/create が 1 つでも出たら、それは事故である。**

---

### フェーズ T5: モジュール化

**ゴール**: 再利用可能な `network` / `compute` モジュールを切り出す。

**変更後の構造**

```
terraform/
├── main.tf                    # ルート: モジュールを呼ぶだけ
├── variables.tf
├── outputs.tf
├── versions.tf
├── providers.tf
├── locals.tf
├── modules/
│   ├── network/
│   │   ├── main.tf            # VPC, subnet, NAT, IGW, RT
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── compute/
│   │   ├── main.tf            # EC2, EBS, key pair
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── nlb/
│   │   ├── main.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   └── ansible-inventory/
│       ├── main.tf            # local_file + template
│       ├── variables.tf
│       └── outputs.tf
```

ルートの `main.tf` は：

```hcl
module "network" {
  source       = "./modules/network"
  project      = var.project
  vpc_cidr     = var.vpc_cidr
  azs          = local.azs
  cluster_name = var.cluster_name
}

module "compute" {
  source             = "./modules/compute"
  project            = var.project
  nodes              = local.nodes
  public_subnet_ids  = module.network.public_subnet_ids
  private_subnet_ids = module.network.private_subnet_ids
  cluster_node_sg_id = module.network.cluster_node_sg_id
  bastion_sg_id      = module.network.bastion_sg_id
  iam_profile_name   = aws_iam_instance_profile.ktcloud-cluster-node-profile.name
  ami_id             = local.node_ami
}

# ... 以下同様
```

**なぜモダンか**

- モジュール化すると **ステージング環境を 30 行の `staging/main.tf` で構築できる**
- 公式 `terraform-aws-modules/vpc/aws` などのコミュニティモジュールと **同じインタフェース** を持たせると将来差し替えやすい
- Terraform 1.8+ では **provider をモジュール側で `configuration_aliases` で受ける** こともできる（multi-region 時に有用）

**注意**: モジュール化も `moved` ブロックでリソース移動を記述する。

```hcl
moved {
  from = aws_vpc.kt-cloud-vpc
  to   = module.network.aws_vpc.main
}
```

---

### フェーズ T6: セキュリティ強化

#### 6-1: `cluster-node-sg` を最小権限に

**現状**: `0.0.0.0/0` から全 port インバウンド。これはほぼ「SG なし」と同じ。

**改善**:

```hcl
resource "aws_security_group" "cluster_node" {
  name   = "${var.project}-cluster-node-sg"
  vpc_id = aws_vpc.kt-cloud-vpc.id
}

# クラスタ内通信（自分自身からの全通信）
resource "aws_security_group_rule" "cluster_node_self" {
  type              = "ingress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.cluster_node.id
  self              = true
}

# bastion からの SSH のみ
resource "aws_security_group_rule" "cluster_node_ssh_from_bastion" {
  type                     = "ingress"
  from_port                = 22
  to_port                  = 22
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster_node.id
  source_security_group_id = aws_security_group.bastion-node-sg.id
}

# NLB → kube-apiserver
resource "aws_security_group_rule" "cluster_node_api_from_nlb" {
  type              = "ingress"
  from_port         = 6443
  to_port           = 6443
  protocol          = "tcp"
  security_group_id = aws_security_group.cluster_node.id
  cidr_blocks       = [var.vpc_cidr]
}

# 全 egress
resource "aws_security_group_rule" "cluster_node_egress" {
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  security_group_id = aws_security_group.cluster_node.id
  cidr_blocks       = ["0.0.0.0/0"]
}
```

**なぜモダンか**

- `aws_security_group_rule` を分離するのが **公式推奨**。`aws_security_group` の `ingress {}` インライン記法は **rule のドリフト検出が壊れやすい**
- `self = true` で **自グループからの通信** を表現するのが慣用

#### 6-2: IAM Role を Terraform 管理下に

**現状**: `data` で外部参照、手動作成前提。

**改善**: `iam.tf` に `aws_iam_role` リソースとして書く。

```hcl
data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_node" {
  name               = "${var.project}-cluster-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json
}

# AWS LBC の policy.json をダウンロードして添付
data "http" "lbc_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.7.0/docs/install/iam_policy.json"
}

resource "aws_iam_policy" "lbc" {
  name   = "${var.project}-lbc-policy"
  policy = data.http.lbc_policy.response_body
}

resource "aws_iam_role_policy_attachment" "cluster_node_lbc" {
  role       = aws_iam_role.cluster_node.name
  policy_arn = aws_iam_policy.lbc.arn
}

resource "aws_iam_instance_profile" "cluster_node" {
  name = "${var.project}-cluster-node-profile"
  role = aws_iam_role.cluster_node.name
}
```

**重要**: 既存環境の IAM Role を Terraform 管理下に取り込むには `import` ブロック（Terraform 1.5+）を使う：

```hcl
import {
  to = aws_iam_role.cluster_node
  id = "ktcloud-cluster-node-role"
}
```

`terraform plan` を実行すると **既存リソースが state に読み込まれて差分計算** される。CLI の `terraform import` を打たなくて済むのが新しい流儀。

#### 6-3: SSM Session Manager で bastion を将来的に廃止する案

**カッティングエッジの提案**: bastion は SSH 鍵管理が面倒で、攻撃対象にもなる。
モダンな AWS では **AWS Systems Manager (SSM) Session Manager** を使うのが標準。

- ノードに `AmazonSSMManagedInstanceCore` policy を付ける
- VPC endpoint (`ssm`, `ssmmessages`, `ec2messages`) を private subnet に置く
- `aws ssm start-session --target i-xxxx` で **公開 IP も SSH 鍵も不要** で接続できる

このリファクタは大きいので **後続のオプションタスク** とする。やる場合は別 PR。

---

### フェーズ T7: 静的解析・CI

#### 7-1: ローカルでの最低限

```bash
terraform fmt -recursive             # フォーマット
terraform validate                   # 構文チェック
```

`.pre-commit-config.yaml` を作成：

```yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: v1.96.1
    hooks:
      - id: terraform_fmt
      - id: terraform_validate
      - id: terraform_tflint
      - id: terraform_trivy        # tfsec の後継
      - id: terraform_docs         # README を自動生成
```

#### 7-2: GitHub Actions

`.github/workflows/terraform.yml`:

```yaml
name: Terraform

on:
  pull_request:
    paths: ['terraform/**']

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: 1.10.0
      - run: terraform fmt -check -recursive
        working-directory: terraform
      - run: terraform init -backend=false
        working-directory: terraform
      - run: terraform validate
        working-directory: terraform
      - uses: aquasecurity/trivy-action@master
        with:
          scan-type: config
          scan-ref: terraform
```

**なぜモダンか**

- `tfsec` は 2024 年に **Aqua Security の Trivy に統合** された。今は `trivy config` が標準
- `terraform-docs` は **README を HCL から自動生成** する。手書きより常に正確

---

## 2. Ansible リファクタリング

### 現状の問題点

| # | 問題 | 影響 |
|---|---|---|
| A1 | Playbook 直書き、role 化されていない | 再利用・テスト・他リポジトリ流用が不可能 |
| A2 | `K8S_VARS_HOLDER` という **synthetic in-memory host** で token を受け渡し | 標準的な Ansible 流儀ではない。読み手が混乱する |
| A3 | `shell:` / `command:` が多い（idempotent ではない） | 何度実行しても安全、にならない |
| A4 | `requirements.yml` (collections) が無い | `kubernetes.core` などが動く保証なし |
| A5 | `inventory.ini` が Terraform から生成される **静的ファイル** | EC2 を増やすたびに `terraform apply` 必須 |
| A6 | tag が振られていない | 「ArgoCD だけ再実行」みたいな部分実行ができない |
| A7 | エラーハンドリング（`block`/`rescue`/`always`）が無い | 失敗時のクリーンアップなし |
| A8 | `ansible-lint` を通していない | YAML スタイル不統一・非推奨記法が混入 |

### フェーズ A1: collections の明示化

**変更内容**: `ansible/requirements.yml` を作成。

```yaml
collections:
  - name: ansible.posix
    version: ">=1.5.0"
  - name: community.general
    version: ">=10.0.0"
  - name: kubernetes.core
    version: ">=5.0.0"
  - name: amazon.aws
    version: ">=9.0.0"
```

インストール：

```bash
ansible-galaxy collection install -r requirements.yml
```

**なぜモダンか**

- Ansible 2.10 以降、ほぼすべての非組み込みモジュールは **collection** に分離されている
- 「`kubernetes.core` の version を固定」しておくと **CI 環境とローカルの再現性** が保証される

---

### フェーズ A2: role 化（一番重要）⭐

**ゴール**: 各 playbook を `roles/` に分解する。

**変更後の構造**

```
ansible/
├── ansible.cfg
├── requirements.yml
├── inventory.ini             # 既存（フェーズ A6 で dynamic 化）
├── group_vars/
│   ├── all.yml               # nlb_dns_name など Terraform から渡る変数
│   └── ap-northeast-2a-masters.yml
├── site.yml                  # 旧 main.yaml（リネーム）
├── playbooks/
│   ├── bootstrap.yml         # 全ノード共通の前準備
│   ├── control-plane.yml     # マスター系
│   ├── workers.yml           # ワーカー join
│   └── addons.yml            # ArgoCD, LBC, Helm
└── roles/
    ├── k8s_prereqs/
    │   ├── tasks/main.yml    # 旧 k8s-pre-setup.yaml
    │   ├── handlers/main.yml
    │   └── defaults/main.yml
    ├── containerd/
    ├── k8s_packages/
    ├── kubeadm_init/         # 旧 master-init.yaml
    ├── cni_calico/
    ├── kubeadm_join_master/
    ├── kubeadm_join_worker/
    ├── helm/
    ├── aws_lbc/
    └── argocd/
```

**`site.yml` の例**:

```yaml
- import_playbook: playbooks/bootstrap.yml
- import_playbook: playbooks/control-plane.yml
- import_playbook: playbooks/workers.yml
- import_playbook: playbooks/addons.yml
```

**`playbooks/bootstrap.yml` の例**:

```yaml
- name: 全ノード共通の前準備
  hosts: all
  become: true
  roles:
    - role: k8s_prereqs
      tags: [prereqs]
    - role: k8s_packages
      tags: [packages]
    - role: containerd
      tags: [containerd]
```

**role の典型構造**（例: `roles/containerd/`）:

```yaml
# roles/containerd/tasks/main.yml
- name: containerd のインストール
  ansible.builtin.dnf:
    name: containerd
    state: present

- name: containerd の設定ディレクトリ作成
  ansible.builtin.file:
    path: /etc/containerd
    state: directory
    mode: "0755"

- name: containerd config の生成
  ansible.builtin.shell: containerd config default > /etc/containerd/config.toml
  args:
    creates: /etc/containerd/config.toml    # ⭐ idempotent化
  notify: restart containerd                # ⭐ handler に通知

- name: SystemdCgroup の有効化
  ansible.builtin.replace:
    path: /etc/containerd/config.toml
    regexp: "SystemdCgroup = false"
    replace: "SystemdCgroup = true"
  notify: restart containerd

- name: IPv4 forwarding
  ansible.posix.sysctl:
    name: net.ipv4.ip_forward
    value: "1"
    state: present
    reload: true

- name: containerd の有効化
  ansible.builtin.systemd:
    name: containerd
    state: started
    enabled: true
```

```yaml
# roles/containerd/handlers/main.yml
- name: restart containerd
  ansible.builtin.systemd:
    name: containerd
    state: restarted
```

**ポイント**

- `args.creates:` は **べき等性** を担保（既にファイルがあれば skip）
- `handlers` は **変更があった時だけ走る**。`notify` で呼び出す
- `tags` で `ansible-playbook site.yml --tags containerd` のように部分実行できる

**なぜモダンか**

- role 化は **Ansible 公式の最重要パターン**。Galaxy で配布する単位でもある
- handler は **idempotency と効率性** の両立に必須

---

### フェーズ A3: `K8S_VARS_HOLDER` を捨てて `set_fact` + `hostvars` で書き直す

**現状** (`join-master.yaml`):

```yaml
- ansible.builtin.add_host:
    name: "K8S_VARS_HOLDER"
    shared_join_cmd: "{{ join_cmd_raw.stdout | trim }}"
```

→ `add_host` で **架空のホストを作って** そこに変数を貼り、別の play で `hostvars['K8S_VARS_HOLDER']` で参照する、というハック。動くけど読みにくい。

**改善案**: `set_fact` + `delegate_to` を使う。

```yaml
# roles/kubeadm_join_master/tasks/main.yml

- name: Join 用の token と cert-key を main-master で生成
  delegate_to: "{{ groups['main-master'][0] }}"
  run_once: true
  become: true
  block:
    - name: cert-key の生成
      ansible.builtin.shell: kubeadm init phase upload-certs --upload-certs | tail -n 1
      environment:
        KUBECONFIG: /etc/kubernetes/admin.conf
      register: cert_key_raw

    - name: join コマンドの生成
      ansible.builtin.shell: kubeadm token create --print-join-command
      environment:
        KUBECONFIG: /etc/kubernetes/admin.conf
      register: join_cmd_raw

    - name: fact を全ノードに配る
      ansible.builtin.set_fact:
        shared_join_cmd: "{{ join_cmd_raw.stdout | trim }}"
        shared_cert_key: "{{ cert_key_raw.stdout | trim }}"
      delegate_to: "{{ item }}"
      delegate_facts: true
      loop: "{{ groups['ap-northeast-2a-masters'] }}"

- name: 2a マスターを control-plane として join
  ansible.builtin.shell: >
    {{ shared_join_cmd }} --control-plane
    --certificate-key {{ shared_cert_key }}
    --cri-socket unix:///var/run/containerd/containerd.sock
  register: master_join_result
  failed_when:
    - master_join_result.rc != 0
    - "'already exists' not in master_join_result.stderr"
  changed_when: "'already exists' not in master_join_result.stderr"
```

**学習ポイント**

- `delegate_to` は **「このタスクを別ホスト上で実行する」**
- `delegate_facts: true` を付けると **set_fact が delegate 先のホストの fact になる**
- `run_once: true` で **複数ホスト対象 play 内でも 1 回だけ実行**

**なぜモダンか**

- `add_host` トリックは古い慣習。最近の Ansible では `set_fact + delegate_facts` が標準
- `block:` で関連タスクをまとめると **エラー時に `rescue:` でクリーンアップ** できる

---

### フェーズ A4: `shell:` → 専用 module への置換

| 現在の shell コマンド | 置き換え先モジュール |
|---|---|
| `kubectl apply -f calico.yaml` | `kubernetes.core.k8s` (URL を src に指定) |
| `helm repo update` | `kubernetes.core.helm` (自動的に update する) |
| `kubectl delete mutatingwebhook...` | `kubernetes.core.k8s` with `state: absent` |
| `sudo curl ... -o /usr/local/bin/argocd` | `ansible.builtin.get_url` |
| `dnf clean all` | `ansible.builtin.dnf: state: latest` (cache 更新) |
| `ssh-add` | これはローカル操作なので playbook 外に移す |

例：

```yaml
# Before
- ansible.builtin.shell: kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# After
- name: Calico CNI のインストール
  kubernetes.core.k8s:
    state: present
    src: https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml
    kubeconfig: /home/ec2-user/.kube/config
```

**なぜモダンか**

- 専用 module は **idempotent**（既にある場合は何もしない）かつ **check mode 対応**（`--check` で dry-run できる）
- `shell:` は最後の手段。「やむを得ない時だけ使う」が原則

---

### フェーズ A5: dynamic inventory（`amazon.aws.aws_ec2` plugin）

**ゴール**: `inventory.ini` を Terraform で生成するのをやめて、**AWS タグから動的に取得** する。

**変更内容**: `ansible/inventory/aws_ec2.yml`

```yaml
plugin: amazon.aws.aws_ec2
regions:
  - ap-northeast-2

filters:
  tag:kubernetes.io/cluster/kt-cloud-cluster: owned
  instance-state-name: running

keyed_groups:
  - key: tags.Role
    prefix: role
  - key: placement.availability_zone
    prefix: az

hostnames:
  - private-ip-address

compose:
  ansible_host: private_ip_address
```

タグの前提：EC2 に `Role: master/worker/bastion` を Terraform 側で付ける。

```bash
ansible-inventory -i inventory/aws_ec2.yml --graph
```

で `role_master`, `role_worker`, `az_ap-northeast-2a` などのグループが自動で見える。

**なぜモダンか**

- **静的 inventory.ini を持たない** ことで、AutoScaling や手動追加にも追従できる
- `terraform apply` と `ansible-playbook` が **疎結合** になる
- AWX/Tower や Ansible Automation Platform は dynamic inventory が前提

**注意**: 既存 playbook の `hosts: ap-northeast-2a-masters` などのグループ名が変わるので、role 化と合わせて段階的に。

---

### フェーズ A6: ansible-vault で secrets 化

現状は secrets を扱っていないが、将来 ArgoCD のパスワードなどを扱うなら：

```bash
ansible-vault create group_vars/all/secrets.yml
```

`group_vars/all/secrets.yml`:

```yaml
argocd_initial_admin_password: !vault |
  $ANSIBLE_VAULT;1.1;AES256
  6162636465...
```

実行時：

```bash
ansible-playbook site.yml --ask-vault-pass
# or
ansible-playbook site.yml --vault-password-file ~/.ansible_vault_pass
```

---

### フェーズ A7: 静的解析・テスト

#### 7-1: ansible-lint

```bash
pip install ansible-lint
ansible-lint
```

`.ansible-lint`:

```yaml
profile: production    # 最も厳しいプロファイル
skip_list:
  - role-name          # 既存 role 名に dash を使っているなら
```

#### 7-2: molecule（role 単体テスト）

```bash
pip install molecule molecule-plugins[docker]
cd roles/containerd
molecule init scenario
molecule test
```

Docker コンテナ上で role を実際に流して、**idempotency と converge** をテストできる。

#### 7-3: GitHub Actions

`.github/workflows/ansible.yml`:

```yaml
name: Ansible

on:
  pull_request:
    paths: ['ansible/**']

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: pip install ansible-lint ansible-core
      - run: ansible-galaxy collection install -r ansible/requirements.yml
      - run: ansible-lint
        working-directory: ansible
```

---

## 3. 横断的改善

### 3-1: Execution Environment（コンテナ化された Ansible）

最新の Ansible 公式 推奨は **Execution Environment (EE)** で Playbook を実行すること。
ローカルにいちいち `ansible-galaxy install` しなくて済む。

```yaml
# execution-environment.yml は ansible-builder で使う
version: 3
dependencies:
  galaxy: requirements.yml
  python:
    - kubernetes
    - boto3
```

```bash
ansible-builder build -t msa-ee:latest
ansible-navigator run site.yml --execution-environment-image msa-ee:latest
```

### 3-2: OpenTofu への移行検討

HashiCorp Terraform は 2023 年に **BSL ライセンス** に変更され、コミュニティが **OpenTofu** に fork した。
コマンドは `tofu` で互換性は高い。**新規プロジェクトでは OpenTofu 推奨** という意見が増えている。

ただ AWS Provider は同じなので、急いで切り替える必要はない。**学習として 1 度 `tofu` で動かしてみる** のは良い経験。

### 3-3: ドキュメント自動生成

- `terraform-docs markdown ./terraform > terraform/README.md`
- `ansible-doctor -r roles/` で role 別 README 自動生成

---

## 4. 推奨実施順（マイルストーン）

| Phase | 内容 | 危険度 | 学習価値 |
|---|---|---|---|
| 1 | TF: フェーズ T1 (ファイル整理) + T2 (変数化) | 低 | ★★ |
| 2 | TF: フェーズ T3 (default_tags) | 低 | ★★ |
| 3 | TF: フェーズ T4 (for_each + moved) ⭐ | **中（必ず plan で No changes を確認）** | ★★★★★ |
| 4 | TF: フェーズ T7 (静的解析・CI) | 低 | ★★★ |
| 5 | Ansible: フェーズ A1 (requirements.yml) | 低 | ★★ |
| 6 | Ansible: フェーズ A2 (role 化) ⭐ | 中 | ★★★★★ |
| 7 | Ansible: フェーズ A4 (shell → module) | 低 | ★★★ |
| 8 | Ansible: フェーズ A3 (K8S_VARS_HOLDER 改善) | 中 | ★★★★ |
| 9 | TF: フェーズ T6 (SG 最小権限 + IAM 内製化) | 高（適用順注意） | ★★★★ |
| 10 | TF: フェーズ T5 (モジュール化) | 中 | ★★★★ |
| 11 | Ansible: フェーズ A5 (dynamic inventory) | 中 | ★★★★ |
| 12 | Ansible: フェーズ A7 (lint + molecule + CI) | 低 | ★★★ |
| 13 | オプション: SSM Session Manager / Execution Environment / OpenTofu | 高 | ★★★★ |

---

## 5. 各フェーズで必ず守ること

1. **1 フェーズ ＝ 1 PR**。レビュアー（過去/未来の自分含む）が読みきれる粒度に。
2. **`terraform plan` で `No changes` が期待** されるリファクタは、必ず差分ゼロを目視確認してマージ。
3. **`moved` ブロックは消さない**。1 度マージしたら次回以降の `terraform plan` で「state は移動済み」と認識された後も残しておく（数か月後の `terraform refresh` でも安全）。
4. **Ansible は `--check --diff` で必ず dry-run** してから本実行。
5. **README.md を毎フェーズで更新**。手順が変わるなら必ず日本語で追記。

---

## 6. 学習リソース

### Terraform

- 公式: <https://developer.hashicorp.com/terraform/language>
- 「Standard Module Structure」: <https://developer.hashicorp.com/terraform/language/modules/develop/structure>
- `moved` / `import` / `removed` ブロック: <https://developer.hashicorp.com/terraform/language/modules/develop/refactoring>
- AWS Provider: <https://registry.terraform.io/providers/hashicorp/aws/latest/docs>
- HashiCorp 公式チュートリアル: <https://developer.hashicorp.com/terraform/tutorials>

### Ansible

- 公式 Best Practices: <https://docs.ansible.com/ansible/latest/tips_tricks/ansible_tips_tricks.html>
- Role 公式ガイド: <https://docs.ansible.com/ansible/latest/playbook_guide/playbooks_reuse_roles.html>
- `kubernetes.core`: <https://docs.ansible.com/ansible/latest/collections/kubernetes/core/index.html>
- `amazon.aws.aws_ec2` dynamic inventory: <https://docs.ansible.com/ansible/latest/collections/amazon/aws/aws_ec2_inventory.html>
- Molecule: <https://ansible.readthedocs.io/projects/molecule/>

### 周辺

- pre-commit-terraform: <https://github.com/antonbabenko/pre-commit-terraform>
- Trivy (旧 tfsec): <https://trivy.dev/>
- OpenTofu: <https://opentofu.org/>

---

## 7. 最後に — 「動くものを壊さない」ための心得

このリポジトリは **既に動いているクラスタを支える IaC** です。リファクタは「コードを綺麗にする」ことが目的ですが、目的と手段を取り違えると **本番が止まる** ことがあります。

- **「リファクタの最中はインフラを変えない」**。新機能追加とリファクタは同じ PR にしない
- **`terraform plan` の出力を読む癖をつける**。`# forces replacement` の文字を見逃さない
- **不安なら `terraform state pull > backup.tfstate` でバックアップ** してから操作する
- **Ansible は `--limit` で対象ホストを絞れる**。怪しい変更は 1 ノードだけで試す

このプランは順番どおりにやれば、ゴール（モダン化＋学習）を両立できるよう設計しています。
フェーズごとに **疑問が出たら遠慮なく Claude に相談** してください。
