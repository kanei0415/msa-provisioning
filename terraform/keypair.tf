resource "aws_key_pair" "ktcloud_key_pair" {
  key_name   = "ktcloud_key_pair"
  public_key = file("~/.ssh/ktcloud-bastion-node-key.pub")
}
