# ============================================================
# kubeadm join command を SSM Parameter Store でやりとり
# ============================================================
# - master は kubeadm init 後に `kubeadm token create --print-join-command` の
#   出力を Ansible (roles/kubeadm_init) からこの SSM パラメータに書き込む。
# - ASG launch instance の UserData は AWS CLI で同パラメータを読み、
#   `kubeadm join --config <(render with token/hash)` で cluster join する。
#
# 値は token を含むので SecureString。
# Terraform 自身はプレースホルダ ("__PLACEHOLDER__") のみ書き込み、実値は
# 後段で Ansible が SSM PutParameter で上書きする。
# ignore_changes で value drift は無視（マスターが更新する以上当然 drift する）。

resource "aws_ssm_parameter" "kubeadm_join_command" {
  name        = "/${var.cluster_name}/kubeadm/join-command"
  description = "kubeadm join command (refreshed every 24h by master, read by ASG worker UserData)"
  type        = "SecureString"
  value       = "__PLACEHOLDER__"

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-kubeadm-join-command"
  })

  lifecycle {
    ignore_changes = [value]
  }
}

# 同様に CA 証明書 hash の参考用（必要時のため。実際は join-command に含まれる）
output "kubeadm_join_command_ssm_name" {
  value       = aws_ssm_parameter.kubeadm_join_command.name
  description = "ASG UserData が aws ssm get-parameter で読むパラメータ名"
}
