# ============================================================
# IAM — ノード instance profile（最小権限化）
# ============================================================
# 旧構成では node instance profile に CCM/LBC の権限を全部寄せていたが、
# IRSA 移行により Pod 側が assume するロールに権限を移し、ノード自体は
#   - IMDSv2 (default)
#   - SSM Parameter Store の join-command 読み取り（worker のみ）
# だけにする。
#
# 事前外部前提の `ktcloud-cluster-node-role` は引き続き data lookup する。
# 旧 inline policy (ccm-policy) は本ファイルから削除し、必要な権限は
# irsa.tf 側の IRSA role に inline policy として付け替える。

data "aws_iam_role" "ktcloud_cluster_node_role" {
  name = "ktcloud-cluster-node-role"
}

# ------------------------------------------------------------
# master / 静的ノード用の instance profile
# ------------------------------------------------------------
# master ノードは control-plane として動くだけで AWS API は基本叩かない
# （CCM 等は IRSA で動く）。互換性のため既存の data role をそのまま使う。
resource "aws_iam_instance_profile" "ktcloud_cluster_node_profile" {
  name = "ktcloud_cluster_node_profile"
  role = data.aws_iam_role.ktcloud_cluster_node_role.name
}

# ------------------------------------------------------------
# worker ASG 用の instance profile（最小権限）
# ------------------------------------------------------------
# UserData が SSM から join command を取りに行く分の権限だけ付ける。
# それ以外の AWS 操作は全部 IRSA 経由（Pod が token assume する）でやる。

resource "aws_iam_role" "ktcloud_worker_node_role" {
  name        = "${var.cluster_name}-worker-node-role"
  description = "Minimal role for ASG worker nodes (read SSM join-command + SSM Managed Instance Core)"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-worker-node-role"
  })
}

data "aws_iam_policy_document" "worker_ssm_join" {
  statement {
    sid     = "ReadJoinCommandSSMParam"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.kubeadm_join_command.arn,
    ]
  }

  # SecureString 復号のため KMS の default alias へのアクセス
  statement {
    sid       = "DecryptSSMParam"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.id}.amazonaws.com"]
    }
  }

  # ASG-launched instance に LBC discovery tag (`kubernetes.io/cluster/<name>=owned`)
  # を自分自身で付けるための ec2:CreateTags。LT tag_specifications で付けると
  # AWS Auto Scaling 側で `/` を含む key が validation で弾かれるため、launch 後
  # に self-tag するしかない。
  statement {
    sid       = "SelfTagForLBCDiscovery"
    effect    = "Allow"
    actions   = ["ec2:CreateTags", "ec2:DescribeTags", "ec2:DescribeInstances"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "worker_ssm_join" {
  name   = "${var.cluster_name}-worker-ssm-join"
  role   = aws_iam_role.ktcloud_worker_node_role.id
  policy = data.aws_iam_policy_document.worker_ssm_join.json
}

# CloudWatch Agent / SSM Agent の利用に備えて AWS managed policy も付与
resource "aws_iam_role_policy_attachment" "worker_ssm_managed_core" {
  role       = aws_iam_role.ktcloud_worker_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ktcloud_worker_node_profile" {
  name = "${var.cluster_name}-worker-node-profile"
  role = aws_iam_role.ktcloud_worker_node_role.name
}

# ------------------------------------------------------------
# master の instance profile に SSM PutParameter 権限を追加
# ------------------------------------------------------------
# kubeadm init 後、Ansible (roles/kubeadm_init) が master 上で
# `aws ssm put-parameter` を叩いて join-command を書き込むため、master 側
# にも書き込み権限が必要。
# 既存外部前提の ktcloud-cluster-node-role に inline で attach する。
data "aws_iam_policy_document" "master_ssm_join_write" {
  statement {
    sid     = "WriteJoinCommandSSMParam"
    effect  = "Allow"
    actions = ["ssm:PutParameter", "ssm:GetParameter"]
    resources = [
      aws_ssm_parameter.kubeadm_join_command.arn,
    ]
  }

  statement {
    sid       = "EncryptDecryptSSMParam"
    effect    = "Allow"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${data.aws_region.current.id}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "master_ssm_join_write" {
  name   = "${var.cluster_name}-master-ssm-join-write"
  role   = data.aws_iam_role.ktcloud_cluster_node_role.name
  policy = data.aws_iam_policy_document.master_ssm_join_write.json
}
