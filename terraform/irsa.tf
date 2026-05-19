# ============================================================
# IRSA (IAM Roles for Service Accounts) for self-managed kubeadm
# ============================================================
# 自己管理 kubeadm クラスタに対して以下を構築する:
#   1. OIDC discovery 文書をホストする S3 bucket（public read）
#   2. AWS IAM OIDC Identity Provider（issuer = S3 URL）
#   3. EBS CSI 用 IAM Role（trust = OIDC provider, sub = kube-system:ebs-csi-controller-sa）
#   4. AmazonEBSCSIDriverPolicy (AWS managed) のアタッチ
#
# Apiserver の `--service-account-issuer` 設定および discovery 文書の S3 へのアップロードは
# Ansible 側 (roles/irsa_oidc) で実施する。Terraform 側はあくまで AWS リソースのみ。

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

# Block Public Access のうち、public bucket policy だけを許可する。
# ACL 経由の public は引き続きブロック。
resource "aws_s3_bucket_public_access_block" "oidc" {
  bucket                  = aws_s3_bucket.oidc.id
  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false

  depends_on = [aws_s3_bucket_ownership_controls.oidc]
}

# OIDC discovery 文書は 2 つの key にのみ public read を付与する:
#   - .well-known/openid-configuration
#   - openid/v1/jwks
# それ以外の key への access は許可しない。
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
# OIDC URL の TLS 証明書から thumbprint を取得
# ------------------------------------------------------------
# AWS IAM OIDC Provider はリーフ証明書ではなく root CA の thumbprint を期待する。
# data.tls_certificate は URL の cert chain を取得し certificates[*] に格納する。
# chain の末端（最後）が root CA。
data "tls_certificate" "oidc" {
  url = aws_s3_bucket.oidc.bucket_regional_domain_name == "" ? "https://${local.oidc_issuer_host}" : "https://${aws_s3_bucket.oidc.bucket_regional_domain_name}"
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

# ------------------------------------------------------------
# EBS CSI Driver 用 IAM Role
# ------------------------------------------------------------
# Trust policy は sts:AssumeRoleWithWebIdentity を許可し、
# sub claim が kube-system:ebs-csi-controller-sa、aud claim が sts.amazonaws.com のとき
# のみマッチする。

data "aws_iam_policy_document" "ebs_csi_trust" {
  statement {
    sid     = "EBSCSIServiceAccountAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    # OIDC issuer のホスト名部分 (https:// を除く) を condition key の prefix に使う。
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name               = "${var.cluster_name}-ebs-csi-controller"
  description        = "Assumed by kube-system:ebs-csi-controller-sa via IRSA"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_trust.json

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-ebs-csi-controller"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_policy" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ------------------------------------------------------------
# Ansible 用の group_vars を吐き出す
# ------------------------------------------------------------
# IRSA セットアップ playbook が参照する変数を一箇所に書き出す。

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
    irsa_ebs_csi_role_arn: "${aws_iam_role.ebs_csi.arn}"
    irsa_aws_account_id: "${data.aws_caller_identity.current.account_id}"
  EOF
}

# ------------------------------------------------------------
# Outputs
# ------------------------------------------------------------

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

output "irsa_ebs_csi_role_arn" {
  description = "IAM role to be assumed by system:serviceaccount:kube-system:ebs-csi-controller-sa"
  value       = aws_iam_role.ebs_csi.arn
}
