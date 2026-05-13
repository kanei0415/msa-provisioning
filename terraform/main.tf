resource "aws_key_pair" "bastion-node-key" {
  key_name   = "ktcloud-bastion-node-key"
  public_key = file("~/.ssh/ktcloud-bastion-node-key.pub")
}

terraform {
  backend "s3" {}
}
