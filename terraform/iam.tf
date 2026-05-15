data "aws_iam_role" "ktcloud_cluster_node_role" {
  name = "ktcloud-cluster-node-role"
}

resource "aws_iam_instance_profile" "ktcloud_cluster_node_profile" {
  name = "ktcloud_cluster_node_profile"
  role = data.aws_iam_role.ktcloud_cluster_node_role.name
}
