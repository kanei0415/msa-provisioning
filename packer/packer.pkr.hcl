# ============================================================
# kt-cloud-cluster ノード用 AMI ビルダー
# ============================================================
# AL2023 ベースの EC2 を一時起動し、Ansible で kubelet / kubeadm /
# kubectl / containerd / カーネル前提設定を焼き込んで AMI 化する。
#
# 焼き込み対象（ansible/roles 配下を再利用）:
#   - k8s_prereqs   : swapoff / カーネルモジュール / sysctl
#   - k8s_packages  : kubelet / kubeadm / kubectl のインストールと enable
#   - containerd    : containerd + config.toml（SystemdCgroup）
#
# 実行時に動く（インスタンス起動時に UserData で行うもの）は焼き込まない:
#   - kubeadm init / join、provider-id 解決、ホスト名設定、SSM 取得など
#
# 完成 AMI に以下のタグを付与し、Terraform 側 data.aws_ami が tag:Role=
# k8s-node + tag:ClusterName=<cluster_name> でルックアップする。
# ============================================================

packer {
  required_plugins {
    amazon = {
      version = ">= 1.3.0"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ------------------------------------------------------------
# Source: AL2023 (x86_64) を起動して chroot ではなく EBS-backed AMI を作る
# ------------------------------------------------------------
source "amazon-ebs" "k8s_node" {
  region        = var.aws_region
  instance_type = var.builder_instance_type

  # ベース AMI: 最新 AL2023 (Amazon owner)
  source_ami_filter {
    filters = {
      name                = "al2023-ami-*-x86_64"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    most_recent = true
    owners      = ["amazon"]
  }

  ssh_username                = "ec2-user"
  ssh_interface               = "public_ip"
  associate_public_ip_address = true

  # subnet 解決:
  #   - builder_subnet_id を明示渡しなら最優先
  #   - 無ければ subnet_filter で「auto-assign public IP が true な任意のサブネット」を探す
  # default VPC のサブネットが消滅している場合は `make ami-prep` で復元するか、
  # builder_subnet_id を明示で渡す（例: PACKER_VAR_builder_subnet_id=subnet-xxx）。
  subnet_id = var.builder_subnet_id

  subnet_filter {
    filters = {
      "state"                   = "available"
      "map-public-ip-on-launch" = "true"
    }
    most_free = true
    random    = false
  }

  # 完成 AMI 名にタイムスタンプを入れる
  ami_name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  ami_description = "kt-cloud-cluster k8s node AMI (kubelet/kubeadm/kubectl/containerd preinstalled)"

  # AMI 自体のタグ
  tags = {
    Name        = "${var.ami_name_prefix}-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
    Project     = var.project
    Role        = "k8s-node"
    ClusterName = var.cluster_name
    BuiltBy     = "packer"
    Version     = formatdate("YYYYMMDD-hhmmss", timestamp())
  }

  # build 用一時 EC2 のタグ（区別しやすいよう Role=packer-builder）
  run_tags = {
    Name        = "${var.ami_name_prefix}-builder"
    Project     = var.project
    Role        = "packer-builder"
    ClusterName = var.cluster_name
  }

  # 焼き込み用の root volume はやや大きめ (30GB / gp3 / 暗号化)
  launch_block_device_mappings {
    device_name           = "/dev/xvda"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  # IMDSv2 を強制（焼き込み後の運用ノードも IMDSv2 のみで動かす）
  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 2
  }

  # AMI に同名が残っていれば上書き（再ビルド時の事故対策）
  force_deregister      = true
  force_delete_snapshot = true
}

# ------------------------------------------------------------
# Build: Ansible で AL2023 を k8s-node 化
# ------------------------------------------------------------
build {
  name    = "kt-cloud-cluster-k8s-node"
  sources = ["source.amazon-ebs.k8s_node"]

  # ansible が必要な python が AL2023 に入っているか確認 + 無ければ入れる
  provisioner "shell" {
    inline = [
      "set -eux",
      # AL2023 は python3 が標準。念のため確認のみ。
      "command -v python3 >/dev/null 2>&1 || sudo dnf install -y python3",
    ]
  }

  # ansible-playbook をローカル laptop で実行し、SSH で対象に流し込む
  provisioner "ansible" {
    playbook_file = "${path.root}/playbook.yaml"
    user          = "ec2-user"

    # ansible のロールを ansible/roles から探す
    extra_arguments = [
      "--scp-extra-args", "'-O'",
      "-e", "ansible_python_interpreter=/usr/bin/python3",
      "-e", "kubernetes_version=${var.kubernetes_version}",
    ]

    # ansible.cfg 側で roles_path をいじりたくないので環境変数で渡す
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_ROLES_PATH=${path.root}/../ansible/roles",
      "ANSIBLE_RETRY_FILES_ENABLED=False",
      "ANSIBLE_STDOUT_CALLBACK=default",
    ]
  }

  # ビルド後のクリーンアップ（runtime に解決すべき状態を AMI に焼き込まない）
  provisioner "shell" {
    inline = [
      "set -eux",
      # cloud-init: 次回起動時に再走させる（hostname / UserData を再評価させるため）
      "sudo cloud-init clean --logs --seed || true",

      # SSH host key: AMI からクローンされた全インスタンスが同じ key を持たないよう削除
      "sudo rm -f /etc/ssh/ssh_host_*",

      # 機械固有 ID をクリア
      "sudo truncate -s 0 /etc/machine-id || true",
      "sudo rm -f /var/lib/dbus/machine-id || true",
      "sudo ln -sf /etc/machine-id /var/lib/dbus/machine-id || true",

      # bash history / tmp
      "sudo rm -f /root/.bash_history /home/ec2-user/.bash_history",
      "sudo rm -rf /tmp/* /var/tmp/* || true",

      # dnf cache
      "sudo dnf clean all",
    ]
  }

  # ビルド結果を manifest.json に書き出す（Makefile が AMI ID を抽出可能）
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
    custom_data = {
      cluster_name = var.cluster_name
      project      = var.project
      role         = "k8s-node"
    }
  }
}
