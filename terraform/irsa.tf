# ============================================================
# IRSA (IAM Roles for Service Accounts) for self-managed kubeadm
# ============================================================
# 自己管理 kubeadm クラスタに対して以下を構築する:
#   1. OIDC discovery 文書をホストする S3 bucket（public read）
#   2. AWS IAM OIDC Identity Provider（issuer = S3 URL）
#   3. IRSA 用 IAM Role（trust = OIDC provider, sub = 各 ServiceAccount）
#       - EBS CSI controller
#       - AWS Cloud Controller Manager (CCM)
#       - AWS Load Balancer Controller (LBC)
#       - Cluster Autoscaler (CA)
#
# Apiserver の `--service-account-issuer` 設定および discovery 文書の S3 への
# アップロードは Ansible 側 (roles/irsa_oidc) で実施。Terraform は AWS リソース
# とポリシーのみを管理。

locals {
  oidc_bucket_name = "${var.cluster_name}-oidc-${data.aws_caller_identity.current.account_id}"

  # OIDC issuer URL（trailing slash 無し）。
  # virtual-hosted-style URL を採用: https://<bucket>.s3.<region>.amazonaws.com
  oidc_issuer_host = "${local.oidc_bucket_name}.s3.${data.aws_region.current.id}.amazonaws.com"
  oidc_issuer_url  = "https://${local.oidc_issuer_host}"
}

# ------------------------------------------------------------
# S3 bucket: OIDC discovery 文書のホスティング
# ------------------------------------------------------------

resource "aws_s3_bucket" "oidc" {
  bucket        = local.oidc_bucket_name
  force_destroy = true

  tags = merge(local.common_tags, {
    Name    = local.oidc_bucket_name
    Purpose = "IRSA OIDC discovery hosting"
  })
}

resource "aws_s3_bucket_ownership_controls" "oidc" {
  bucket = aws_s3_bucket.oidc.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket                  = aws_s3_bucket.oidc.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false

  depends_on = [aws_s3_bucket_ownership_controls.oidc]
}

resource "aws_s3_bucket_policy" "oidc" {
  bucket = aws_s3_bucket.oidc.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadDiscoveryDocs"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource = [
          "${aws_s3_bucket.oidc.arn}/.well-known/openid-configuration",
          "${aws_s3_bucket.oidc.arn}/openid/v1/jwks",
        ]
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.oidc]
}

# ------------------------------------------------------------
# TLS 証明書 thumbprint
# ------------------------------------------------------------
data "tls_certificate" "oidc" {
  url = "https://${local.oidc_issuer_host}"
}

# ------------------------------------------------------------
# IAM OIDC Identity Provider
# ------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "cluster" {
  url             = local.oidc_issuer_url
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[length(data.tls_certificate.oidc.certificates) - 1].sha1_fingerprint]

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-oidc"
  })
}

# ============================================================
# Helper local — IRSA Trust Policy 生成
# ============================================================
# 同型の trust policy を 4 つ書くので、helper local で kvargs 風に出力する。

locals {
  irsa_trust = {
    ebs_csi = {
      sa_namespace = "kube-system"
      sa_name      = "ebs-csi-controller-sa"
    }
    ccm = {
      sa_namespace = "kube-system"
      sa_name      = "aws-cloud-controller-manager"
    }
    lbc = {
      sa_namespace = "kube-system"
      sa_name      = "aws-load-balancer-controller"
    }
    cluster_autoscaler = {
      sa_namespace = "kube-system"
      sa_name      = "cluster-autoscaler"
    }
    external_secrets = {
      sa_namespace = "external-secrets"
      sa_name      = "external-secrets"
    }
  }
}

data "aws_iam_policy_document" "irsa_trust" {
  for_each = local.irsa_trust

  statement {
    sid     = "AssumeWithWebIdentity"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:${each.value.sa_namespace}:${each.value.sa_name}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ============================================================
# IRSA Role: EBS CSI Driver controller
# ============================================================
resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-controller"
  description        = "Assumed by kube-system:ebs-csi-controller-sa via IRSA"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["ebs_csi"].json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-ebs-csi-controller"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ============================================================
# IRSA Role: AWS Cloud Controller Manager
# ============================================================
# 旧来 node instance profile に inline で乗せていた CCM 用権限を IRSA Role に
# 移管。out-of-tree CCM の必要権限のみを最小で付ける。
data "aws_iam_policy_document" "ccm" {
  statement {
    sid    = "CCMRead"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeInstances",
      "ec2:DescribeRegions",
      "ec2:DescribeRouteTables",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSubnets",
      "ec2:DescribeVolumes",
      "ec2:DescribeVpcs",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CCMTagAndModify"
    effect = "Allow"
    actions = [
      "ec2:CreateTags",
      "ec2:ModifyInstanceAttribute",
      "ec2:ModifyVolume",
      "ec2:AttachVolume",
      "ec2:DetachVolume",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "CCMServiceLinkedRole"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "elasticloadbalancing.amazonaws.com",
        "autoscaling.amazonaws.com",
      ]
    }
  }

  statement {
    sid       = "CCMKMSDescribe"
    effect    = "Allow"
    actions   = ["kms:DescribeKey"]
    resources = ["*"]
  }
}

resource "aws_iam_role" "ccm" {
  name               = "${var.cluster_name}-cloud-controller-manager"
  description        = "Assumed by kube-system:aws-cloud-controller-manager via IRSA"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["ccm"].json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-cloud-controller-manager"
  })
}

resource "aws_iam_role_policy" "ccm" {
  name   = "${var.cluster_name}-ccm-inline"
  role   = aws_iam_role.ccm.id
  policy = data.aws_iam_policy_document.ccm.json
}

# ============================================================
# IRSA Role: AWS Load Balancer Controller
# ============================================================
# 公式の IAM policy JSON を取り込む方法もあるが、依存を増やしたくないので
# data.http で公式 raw を取り込む。
data "http" "lbc_iam_policy" {
  url = "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.8.1/docs/install/iam_policy.json"
}

resource "aws_iam_role" "lbc" {
  name               = "${var.cluster_name}-aws-load-balancer-controller"
  description        = "Assumed by kube-system:aws-load-balancer-controller via IRSA"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["lbc"].json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-aws-load-balancer-controller"
  })
}

resource "aws_iam_role_policy" "lbc" {
  name   = "${var.cluster_name}-lbc-inline"
  role   = aws_iam_role.lbc.id
  policy = data.http.lbc_iam_policy.response_body
}

# ============================================================
# IRSA Role: Cluster Autoscaler
# ============================================================
data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "CAReadDescribe"
    effect = "Allow"
    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeScalingActivities",
      "autoscaling:DescribeTags",
      "ec2:DescribeImages",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplateVersions",
      "ec2:GetInstanceTypesFromInstanceRequirements",
      "eks:DescribeNodegroup",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "CAMutate"
    effect = "Allow"
    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]
    resources = ["*"]
    # 安全のため、CA が管理対象としてタグ付けした ASG のみに絞り込み
    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${var.cluster_name}"
      values   = ["owned"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.cluster_name}-cluster-autoscaler"
  description        = "Assumed by kube-system:cluster-autoscaler via IRSA"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["cluster_autoscaler"].json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-cluster-autoscaler"
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name   = "${var.cluster_name}-ca-inline"
  role   = aws_iam_role.cluster_autoscaler.id
  policy = data.aws_iam_policy_document.cluster_autoscaler.json
}

# ============================================================
# IRSA Role: External Secrets Operator (ESO)
# ============================================================
# external-secrets:external-secrets SA が AWS Secrets Manager から
# `${cluster_name}/*` プレフィックスのシークレットを読むためのロール。
data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid    = "ESOReadClusterSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecretVersionIds",
    ]
    resources = [
      "arn:aws:secretsmanager:${data.aws_region.current.id}:${data.aws_caller_identity.current.account_id}:secret:${var.cluster_name}/*",
    ]
  }

  statement {
    sid    = "ESOListSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:ListSecrets",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ESOKMSDecrypt"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.id}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name               = "${var.cluster_name}-external-secrets"
  description        = "Assumed by external-secrets:external-secrets via IRSA"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust["external_secrets"].json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-external-secrets"
  })
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "${var.cluster_name}-eso-inline"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

# ============================================================
# Ansible 用 group_vars
# ============================================================
resource "local_file" "irsa_group_vars" {
  filename        = "${path.module}/../ansible/group_vars/irsa.yaml"
  file_permission = "0644"

  content = <<-EOF
    ---
    # AUTO-GENERATED by terraform/irsa.tf — DO NOT EDIT MANUALLY
    irsa_oidc_bucket: "${local.oidc_bucket_name}"
    irsa_oidc_region: "${data.aws_region.current.id}"
    irsa_oidc_issuer_url: "${local.oidc_issuer_url}"
    irsa_oidc_issuer_host: "${local.oidc_issuer_host}"
    irsa_oidc_provider_arn: "${aws_iam_openid_connect_provider.cluster.arn}"
    irsa_aws_account_id: "${data.aws_caller_identity.current.account_id}"

    # 各 IRSA 用 IAM Role ARN
    irsa_ebs_csi_role_arn:            "${aws_iam_role.ebs_csi.arn}"
    irsa_ccm_role_arn:                "${aws_iam_role.ccm.arn}"
    irsa_lbc_role_arn:                "${aws_iam_role.lbc.arn}"
    irsa_cluster_autoscaler_role_arn: "${aws_iam_role.cluster_autoscaler.arn}"
    irsa_external_secrets_role_arn:   "${aws_iam_role.external_secrets.arn}"

    # ASG / cluster identity (CA role が参照)
    cluster_name: "${var.cluster_name}"
    aws_region: "${data.aws_region.current.id}"
    worker_asg_names:
    %{for name in [for k, asg in aws_autoscaling_group.workers : asg.name]~}
      - "${name}"
    %{endfor~}

    # join-command SSM パラメータ名 (master 側で書き込み)
    kubeadm_join_command_ssm_name: "${aws_ssm_parameter.kubeadm_join_command.name}"
  EOF

  depends_on = [
    aws_autoscaling_group.workers,
    aws_ssm_parameter.kubeadm_join_command,
  ]
}

# ============================================================
# Outputs
# ============================================================
output "irsa_oidc_bucket" {
  description = "S3 bucket hosting OIDC discovery documents"
  value       = aws_s3_bucket.oidc.id
}

output "irsa_oidc_issuer_url" {
  description = "OIDC issuer URL (= --service-account-issuer on kube-apiserver)"
  value       = local.oidc_issuer_url
}

output "irsa_oidc_provider_arn" {
  description = "IAM OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "irsa_role_arns" {
  description = "IRSA role ARN map (controller -> role ARN)"
  value = {
    ebs_csi            = aws_iam_role.ebs_csi.arn
    ccm                = aws_iam_role.ccm.arn
    lbc                = aws_iam_role.lbc.arn
    cluster_autoscaler = aws_iam_role.cluster_autoscaler.arn
    external_secrets   = aws_iam_role.external_secrets.arn
  }
}
