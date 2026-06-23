# ============================================================
# AWS Secrets Manager — per-service secrets
# ============================================================
# 各マイクロサービスが必要とするシークレットを `${cluster_name}/<service>`
# プレフィックスで作成する。初回は placeholder 値で作成し、運用後はコンソール
# / CLI から値を書き換える前提 (lifecycle.ignore_changes で terraform が
# 上書きしないようにしてある)。
#
# ESO 側の ClusterSecretStore がこれらをそのまま K8s Secret に同期する。
# 必要なキー一覧:
#   auth-service       : DB_PASSWORD, REDIS_PASSWORD, JWT_SECRET
#   product-service    : DB_PASSWORD
#   inventory-service  : DB_PASSWORD, REDIS_PASSWORD
#   order-service      : DB_PASSWORD
#   user-api-gateway   : JWT_SECRET

locals {
  msa_service_secrets = {
    auth_service = {
      name = "auth-service"
      keys = {
        DB_PASSWORD    = "CHANGE_ME_AUTH_DB"
        REDIS_PASSWORD = "CHANGE_ME_REDIS"
        JWT_SECRET     = "CHANGE_ME_JWT"
      }
    }
    product_service = {
      name = "product-service"
      keys = {
        DB_PASSWORD = "CHANGE_ME_PRODUCT_DB"
      }
    }
    inventory_service = {
      name = "inventory-service"
      keys = {
        DB_PASSWORD    = "CHANGE_ME_INVENTORY_DB"
        REDIS_PASSWORD = "CHANGE_ME_REDIS"
      }
    }
    order_service = {
      name = "order-service"
      keys = {
        DB_PASSWORD = "CHANGE_ME_ORDER_DB"
      }
    }
    user_api_gateway = {
      name = "user-api-gateway"
      keys = {
        JWT_SECRET = "CHANGE_ME_JWT"
        # The gateway's Bucket4j rate limiter connects to inventory-redis, so it
        # needs the same REDIS_PASSWORD (ESO dataFrom-extracts every key here).
        REDIS_PASSWORD = "CHANGE_ME_REDIS"
      }
    }
  }
}

resource "aws_secretsmanager_secret" "msa" {
  for_each = local.msa_service_secrets

  name        = "${var.cluster_name}/${each.value.name}"
  description = "MSA secrets for ${each.value.name} (read by ESO via IRSA)"

  # 削除時の復元期間。dev cluster は destroy → apply を頻繁に回すので即時削除 (=0)。
  # 0 以外だと同名 secret が grace 期間中に残り、次の apply が
  # "scheduled for deletion" で失敗する。
  recovery_window_in_days = 0

  tags = merge(local.common_tags, {
    Name    = "${var.cluster_name}-${each.value.name}"
    Service = each.value.name
  })
}

resource "aws_secretsmanager_secret_version" "msa" {
  for_each = local.msa_service_secrets

  secret_id     = aws_secretsmanager_secret.msa[each.key].id
  secret_string = jsonencode(each.value.keys)

  # 初回作成のみ placeholder を入れ、以後は手動更新を尊重する。
  lifecycle {
    ignore_changes = [secret_string, version_stages]
  }
}

output "secretsmanager_secret_arns" {
  description = "ARN of each per-service AWS Secrets Manager secret"
  value = {
    for k, s in aws_secretsmanager_secret.msa : k => s.arn
  }
}
