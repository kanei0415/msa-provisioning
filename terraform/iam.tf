data "aws_iam_role" "ktcloud-cluster-node-role" {
  name = "ktcloud-cluster-node-role"
}

resource "aws_iam_instance_profile" "ktcloud-cluster-node-profile" {
  name = "ktcloud-node-profile"
  role = data.aws_iam_role.ktcloud-cluster-node-role.name
}
