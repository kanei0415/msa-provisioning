data "aws_iam_role" "ktcloud_cluster_node_role" {
  name = "ktcloud-cluster-node-role"
}

resource "aws_iam_instance_profile" "ktcloud_cluster_node_profile" {
  name = "ktcloud_cluster_node_profile"
  role = data.aws_iam_role.ktcloud_cluster_node_role.name
}

# ------------------------------------------------------------
# AWS Cloud Controller Manager (out-of-tree) 用 IAM ポリシー
# ------------------------------------------------------------
# CCM は master ノード上で動き、ノードの instance profile (= node role) の
# 認証情報で AWS API を叩く。そのため node role に CCM が必要とする権限を
# inline policy で付与する。
#
# 参考: https://cloud-provider-aws.sigs.k8s.io/prerequisites/
#
# 本クラスタでは:
#   - Service type=LoadBalancer は AWS LBC が担当（CCM は ELB 自動作成しない）
#   - Pod ネットワークは Calico (IP-in-IP) で完結、VPC route table は NAT 用のみ
#     → CCM の route controller は無効化する (configure-cloud-routes=false)
#   - CCM の主用途は node controller: providerID 検証 + zone/region label 付与 +
#     uninitialized taint の除去 + node 削除時の cleanup
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
    sid    = "CCMServiceLinkedRole"
    effect = "Allow"
    actions = [
      "iam:CreateServiceLinkedRole",
    ]
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
    sid    = "CCMKMSDescribe"
    effect = "Allow"
    actions = [
      "kms:DescribeKey",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ccm" {
  name   = "ktcloud-cluster-ccm-policy"
  role   = data.aws_iam_role.ktcloud_cluster_node_role.name
  policy = data.aws_iam_policy_document.ccm.json
}
