# AWS Cloud Controller Manager 導入レポート — 自己管理 kubeadm クラスタへの out-of-tree CCM 統合

**クラスタ**: `kt-cloud-cluster` (1 control-plane + 5 workers、kubeadm v1.30 on EC2、ap-northeast-2)
**スコープ**: kubelet を `--cloud-provider=external` で動かし、`provider-id` を kubeadm init/join 時に IMDSv2 から先回りで埋め込んだうえで、out-of-tree AWS Cloud Controller Manager (CCM) を DaemonSet として control plane に常駐させる。AWS Load Balancer Controller の `targetType: instance` を機能させ、Node ↔ EC2 InstanceID 解決の常設障害を根絶する。
**読者**: 自己管理 kubeadm クラスタ (= EKS を使わない構成) を AWS 上で運用しており、in-tree cloud-provider のサポート打ち切り後の正しい移行先を理解したいオペレータ。
**状態**: ✅ Terraform / Ansible への組み込み完了。`make tf-apply` → `make cluster-up` で再現可能な構成として固定済み。本番稼働クラスタは別途 live patch で復旧済 (詳細は §7)。

---

## 目次

- [0. エグゼクティブサマリー](#0-エグゼクティブサマリー)
- [1. 発生していた事象と影響範囲](#1-発生していた事象と影響範囲)
  - [1.1 観測されていた症状](#11-観測されていた症状)
  - [1.2 AWS LBC が出していた決定的なログ](#12-aws-lbc-が出していた決定的なログ)
  - [1.3 影響範囲: traefik 経由の Web 入口が全断](#13-影響範囲-traefik-経由の-web-入口が全断)
- [2. 根本原因 — `.spec.providerID` 空問題](#2-根本原因--specprovideri-d-空問題)
  - [2.1 Node オブジェクトの providerID とは何か](#21-node-オブジェクトの-providerid-とは何か)
  - [2.2 AWS LBC が providerID をどう使うか](#22-aws-lbc-が-providerid-をどう使うか)
  - [2.3 なぜ kubeadm 単体だと providerID は空のままなのか](#23-なぜ-kubeadm-単体だと-providerid-は空のままなのか)
- [3. cloud-provider の歴史 — in-tree から out-of-tree へ](#3-cloud-provider-の歴史--in-tree-から-out-of-tree-へ)
  - [3.1 in-tree cloud-provider の時代 (k8s ≤ 1.20)](#31-in-tree-cloud-provider-の時代-k8s--120)
  - [3.2 KEP-2392 と "external cloud provider"](#32-kep-2392-と-external-cloud-provider)
  - [3.3 k8s 1.25 で in-tree AWS が消えた](#33-k8s-125-で-in-tree-aws-が消えた)
  - [3.4 自己管理 kubeadm クラスタが取る選択肢](#34-自己管理-kubeadm-クラスタが取る選択肢)
- [4. AWS Cloud Controller Manager の中身](#4-aws-cloud-controller-manager-の中身)
  - [4.1 リポジトリと配布形態](#41-リポジトリと配布形態)
  - [4.2 内部で動く 4 つの controller](#42-内部で動く-4-つの-controller)
  - [4.3 uninitialized taint の意味と除去メカニズム](#43-uninitialized-taint-の意味と除去メカニズム)
  - [4.4 本クラスタで使う controller と無効化する controller](#44-本クラスタで使う-controller-と無効化する-controller)
- [5. アーキテクチャ全体像](#5-アーキテクチャ全体像)
  - [5.1 シーケンス図 — ノード起動から LBC への登録まで](#51-シーケンス図--ノード起動から-lbc-への登録まで)
  - [5.2 静的 manifest と DaemonSet の関係](#52-静的-manifest-と-daemonset-の関係)
  - [5.3 認証経路 — IRSA を使わず Node IAM Role を使う理由](#53-認証経路--irsa-を使わず-node-iam-role-を使う理由)
- [6. 実装 — ファイル単位の詳細](#6-実装--ファイル単位の詳細)
  - [6.1 変更ファイル一覧](#61-変更ファイル一覧)
  - [6.2 Terraform: `terraform/iam.tf`](#62-terraform-terraformiamtf)
  - [6.3 Ansible: `roles/kubeadm_init/templates/kubeadm-config.yaml.j2`](#63-ansible-roleskubeadm_inittemplateskubeadm-configyamlj2)
  - [6.4 Ansible: `roles/kubeadm_init/tasks/main.yaml`](#64-ansible-roleskubeadm_inittasksmainyaml)
  - [6.5 Ansible: `roles/kubeadm_join_worker/tasks/main.yaml`](#65-ansible-roleskubeadm_join_workertasksmainyaml)
  - [6.6 Ansible: `roles/kubeadm_join_worker/templates/kubeadm-join-config.yaml.j2`](#66-ansible-roleskubeadm_join_workertemplateskubeadm-join-configyamlj2)
  - [6.7 Ansible: `roles/aws_ccm/tasks/main.yaml`](#67-ansible-rolesaws_ccmtasksmainyaml)
  - [6.8 Ansible: `playbooks/addons.yaml`](#68-ansible-playbooksaddonsyaml)
  - [6.9 Ansible: `group_vars/all.yaml`](#69-ansible-group_varsallyaml)
- [7. ライブクラスタへの応急処置 (記録)](#7-ライブクラスタへの応急処置-記録)
  - [7.1 状況把握コマンド](#71-状況把握コマンド)
  - [7.2 providerID 直接 patch](#72-providerid-直接-patch)
  - [7.3 LBC の挙動確認](#73-lbc-の挙動確認)
- [8. 検証手順](#8-検証手順)
  - [8.1 providerID が全 node に埋まっていること](#81-provideri-d-が全-node-に埋まっていること)
  - [8.2 uninitialized taint がないこと](#82-uninitialized-taint-がないこと)
  - [8.3 zone/region label が CCM で付いていること](#83-zoneregion-label-が-ccm-で-付いていること)
  - [8.4 CCM Pod が control-plane で Ready であること](#84-ccm-pod-が-control-plane-で-ready-であること)
  - [8.5 AWS LBC ログに providerID 欠落エラーがないこと](#85-aws-lbc-ログに-providerid-欠落エラーがないこと)
  - [8.6 ALB/NLB の target group が登録されていること](#86-albnlb-の-target-group-が-登録されていること)
  - [8.7 traefik 経由の HTTP 通信が通ること](#87-traefik-経由の-http-通信が通ること)
- [9. トラブルシューティング](#9-トラブルシューティング)
  - [9.1 CCM Pod が CrashLoopBackOff になる (IAM 権限不足)](#91-ccm-pod-が-crashloopbackoff-になる-iam-権限不足)
  - [9.2 uninitialized taint が消えない](#92-uninitialized-taint-が-消えない)
  - [9.3 join した worker の providerID が空](#93-join-した-worker-の-providerid-が-空)
  - [9.4 controller-manager が起動しない](#94-controller-manager-が-起動しない)
  - [9.5 IMDSv2 の token 取得が 403 を返す](#95-imdsv2-の-token-取得が-403-を返す)
  - [9.6 CoreDNS が Pending のまま](#96-coredns-が-pending-のまま)
  - [9.7 CCM が Service コントローラとして CLB を作ろうとする](#97-ccm-が-service-コントローラとして-clb-を作ろうとする)
- [10. セキュリティ・運用上の留意点](#10-セキュリティ運用上の留意点)
  - [10.1 IAM ポリシースコープの最小化](#101-iam-ポリシースコープの最小化)
  - [10.2 IMDSv2 強制](#102-imdsv2-強制)
  - [10.3 providerID と node 削除の関係](#103-providerid-と-node-削除の関係)
  - [10.4 EBS volume topology との連携](#104-ebs-volume-topology-との-連携)
  - [10.5 control-plane を冗長化したときの CCM のリーダー選出](#105-control-plane-を-冗長化したときの-ccm-の-リーダー選出)
- [11. EKS との比較](#11-eks-との比較)
- [12. オペレーションランブック](#12-オペレーションランブック)
  - [12.1 ゼロから構築する手順](#121-ゼロから構築する手順)
  - [12.2 既存クラスタへの CCM 追加 (本ケースの再現方法)](#122-既存クラスタへの-ccm-追加-本ケースの再現方法)
  - [12.3 CCM Helm release のアップグレード](#123-ccm-helm-release-のアップグレード)
  - [12.4 CCM の撤去 (使わなくなった場合)](#124-ccm-の撤去-使わなくなった場合)
- [13. 用語集](#13-用語集)
- [14. 参考資料](#14-参考資料)
- [付録 A: 完成版 kubeadm-config.yaml の例](#付録-a-完成版-kubeadm-configyaml-の例)
- [付録 B: 完成版 kubeadm-join-config.yaml の例](#付録-b-完成版-kubeadm-join-configyaml-の例)
- [付録 C: CCM が node に付与する label / annotation 一覧](#付録-c-ccm-が-node-に付与する-label--annotation-一覧)
- [付録 D: CCM IAM ポリシー全文 (JSON)](#付録-d-ccm-iam-ポリシー全文-json)
- [付録 E: 各 controller の在野ログサンプル](#付録-e-各-controller-の-在野ログサンプル)
- [付録 F: ライブパッチ作業の生ログ](#付録-f-ライブパッチ作業の生ログ)

---

## 0. エグゼクティブサマリー

本作業の目的は、`kt-cloud-cluster` (kubeadm ベース、EC2 上の自己管理 K8s) において恒常的に発生していた "AWS Load Balancer Controller (LBC) が target group に EC2 インスタンスを登録できない" 不具合を、対症療法ではなく構成として直すことだった。

事象の要約は次のとおり。

- `kubectl get nodes -o jsonpath='{...spec.providerID}'` がすべての node で空。
- LBC のログに `providerID is not specified for node: ip-10-0-x-x.ap-northeast-2.compute.internal` が毎 reconcile 出る。
- それに伴い、`TargetGroupBinding` 経由で作られた target group (例: `k8s-traefik-traefik-df452a5320`) に targets が 0 件登録。
- NLB は backend に到達できず、`curl` レベルで TCP timeout / 504。

根本原因は、kubelet が AWS in-tree cloud-provider を喋っていない (= kubeadm が untainted な K8s をそのまま立てた) ため、Node オブジェクトの `.spec.providerID` を埋める者がいないこと。LBC は `targetType: instance` のときこのフィールドを `aws:///<az>/<instance-id>` 形式と解釈して InstanceID を取り出すため、空だと一切登録できない。

正攻法は、out-of-tree cloud-provider-aws (= AWS CCM) を導入したうえで、kubeadm の InitConfiguration / JoinConfiguration の `kubeletExtraArgs` に `cloud-provider=external` と `provider-id=aws:///<az>/<instance-id>` を埋め込む構成。これにより:

1. **kubelet 登録時点で providerID が即時にセットされる** → LBC は CCM の到着を待たずに InstanceID を解決できる。
2. **CCM は uninitialized taint を除去する** → `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule` が外れ、CoreDNS など taint を tolerate しない Deployment が schedule される。
3. **node に zone/region/instance-type label が付与される** → multi-AZ topology を必要とする schedulrer ヒントや EBS CSI driver が機能する。

本レポートは、なぜ providerID が必要だったかという最初の "なぜ" から、ファイル単位の差分、検証手順、トラブルシューティングまでを一連で記録したものである。読了後、同じパターンを別クラスタに移植する際にこの 1 本を見れば足りる状態を目指す。

---

## 1. 発生していた事象と影響範囲

### 1.1 観測されていた症状

最初に「外から http が通らない」という形で報告された事象を、観測した順に並べる。

| 観測ポイント | 期待挙動 | 実際 |
|------------|---------|-----|
| `kubectl get nodes` | 6 ノード Ready | 6 ノード Ready (見た目は健全) |
| `kubectl get pods -A` | LBC, traefik, coredns すべて Running | 同上、Running |
| AWS console: NLB | Healthy targets > 0 | **healthy targets = 0** |
| AWS console: target group `k8s-traefik-traefik-df452a5320` | targets が登録されている | **targets 0** |
| `curl https://<NLB-DNS>/` | 200 もしくは 404 (traefik から) | **TCP connection timeout** |

つまり Kubernetes のレイヤから見るとすべて正常だが、AWS の負荷分散レイヤから K8s ノードへの導線が一切張られていないという、典型的な "controller が AWS に対して仕事をしていない" パターンだった。

### 1.2 AWS LBC が出していた決定的なログ

`kubectl logs -n kube-system deploy/aws-load-balancer-controller -f` の抜粋:

```
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-2-119.ap-northeast-2.compute.internal"}
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-2-27.ap-northeast-2.compute.internal"}
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-4-49.ap-northeast-2.compute.internal"}
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-4-72.ap-northeast-2.compute.internal"}
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-4-233.ap-northeast-2.compute.internal"}
{"level":"warn","ts":"2026-05-17T03:21:11Z","msg":"providerID is not specified for node: ip-10-0-2-217.ap-northeast-2.compute.internal"}
{"level":"info","ts":"2026-05-17T03:21:11Z","msg":"successful reconcile","reconcileID":"...","targetGroup":"k8s-traefik-traefik-df452a5320","targetCount":0}
```

`providerID is not specified` という warn が 6 ノードぶん毎回出ていた。LBC はそれでもクラッシュせず "reconcile 成功 / target 0 件" として正常終了するため、**ログを丁寧に読まない限り問題に気づきにくい**。実際、`kubectl get pods` だけ見ていたら永遠に気づかなかったケースである。

### 1.3 影響範囲: traefik 経由の Web 入口が全断

本クラスタは traefik を ingress-class として使い、ArgoCD で同期している外部マニフェストリポジトリから `IngressRoute` を流し込む構成。traefik は LoadBalancer (NLB) 経由で外部に晒される。

```
インターネット
    │
    ▼
[NLB] ──── target group ──── 0 targets ❌
    │
    ▼  (届かない)
[traefik Service]
    │
    ▼
各種 Pod
```

NLB の target group が空なので、`*.example.com` 系のすべてのドメインが TCP レベルで死ぬ。ArgoCD UI、社内ダッシュボード、API ゲートウェイがまとめて沈黙。

ただし VPC 内部から Service 名で叩く通信 (例: pod → pod、ArgoCD → 同 cluster) は影響を受けない。あくまで「AWS 負荷分散経由の外向き経路」だけが死ぬ症状であることが切り分けのポイントだった。

---

## 2. 根本原因 — `.spec.providerID` 空問題

### 2.1 Node オブジェクトの providerID とは何か

Kubernetes の Node リソースには `.spec.providerID` というフィールドがある。型は文字列で、規約は次のとおり。

```
<cloud-provider>://<provider-specific-id>
```

AWS の場合の規約 (cloud-provider-aws による):

```
aws:///<availability-zone>/<ec2-instance-id>
```

例: `aws:///ap-northeast-2a/i-0123456789abcdef0`

このフィールドは **kubelet が登録時に自分で埋めるか、Cloud Controller Manager が後追いで埋めるかのどちらか**。プレーンな kubeadm はこのいずれの設定もしないので、デフォルトでは空。

### 2.2 AWS LBC が providerID をどう使うか

AWS Load Balancer Controller は、`Service type=LoadBalancer` や `Ingress` を ALB/NLB として実体化するが、target group へのバックエンド登録には 2 つのモードがある。

| targetType | バックエンド | 識別子 |
|-----------|------------|-------|
| `ip`       | Pod IP     | Pod IP (CNI が割り当てる) |
| `instance` | EC2 instance + NodePort | EC2 InstanceID |

本クラスタは traefik を NodePort 経由で受ける `instance` モードを使っていた。LBC のソースコード (aws-load-balancer-controller の `pkg/k8s/node_utils.go` 周辺) は、Node から InstanceID を取得するときに次の優先順位で見る。

1. `.spec.providerID` を `aws:///<az>/<id>` として parse → InstanceID
2. 取れなかったら諦める (= target group に登録しない)

LBC は意図的に EC2 DescribeInstances を Name タグや IP で引いて InstanceID を逆引きしない設計になっている。理由は AWS API 呼び出しコストとレート制限、それから一意性保証 (タグや IP は重複し得る)。よって providerID が空 = LBC からは詰み。

### 2.3 なぜ kubeadm 単体だと providerID は空のままなのか

ここが本件の核心。kubeadm は cloud-provider に対して中立で、CA・control plane の static manifest を生成しつつ、kubelet と controller-manager にはオプションを一切渡さない (デフォルト)。

kubelet が providerID を自分で埋めるための経路は次の 3 つ。

1. **`--cloud-provider=<aws|gce|...>`** (in-tree): kubelet が自分で IMDS を読んで埋める。**1.25 以降 AWS の in-tree は削除**。
2. **`--cloud-provider=external`**: 自分では埋めない。CCM が後で埋める前提。**uninitialized taint を自分で付与する**。
3. **`--provider-id=<string>`** flag: 起動時に固定の値を直接埋める。external モードと併用可能。

何もしないと kubelet は in-tree でも external でもないモードで起動し、providerID は空のまま node が登録される。CCM もいないので誰も埋めにこない → 永遠に空。

本クラスタもこのパターンに該当していた。kubeadm init / kubeadm join をデフォルト設定のまま使っていたため、6 ノード全部が空 providerID で登録されていた。

---

## 3. cloud-provider の歴史 — in-tree から out-of-tree へ

なぜ "external" や CCM が必要なのか、背景を押さえておくと運用判断が早くなる。

### 3.1 in-tree cloud-provider の時代 (k8s ≤ 1.20)

Kubernetes の初期は AWS / GCE / Azure 用のロジックがコア kubelet と controller-manager に直接埋め込まれていた。kubelet 起動オプションに `--cloud-provider=aws` を渡すと:

- kubelet が IMDS から InstanceID/AZ を読み、Node の providerID と label を埋める
- kube-controller-manager の cloud-loop が Service type=LoadBalancer に対して CLB を作る
- node controller が EC2 状態を見てゴーストノードを削除する

このアーキテクチャは「k8s コアに各クラウドの依存が居座る」「Kubernetes リリースとクラウド SDK の更新が同期せざるを得ない」など保守上の問題が大きく、SIG Cloud Provider で out-of-tree 化が決議された。

### 3.2 KEP-2392 と "external cloud provider"

[KEP-2392 (Removal of in-tree cloud providers)](https://github.com/kubernetes/enhancements/tree/master/keps/sig-cloud-provider/2392-cloud-provider-removal) で次の段階的移行が決まった。

| フェーズ | 内容 |
|--------|------|
| α       | `--cloud-provider=external` flag を kubelet/KCM に追加。CCM (= 別 binary) が in-tree ロジックを引き継ぐ。 |
| β       | 各クラウド向け CCM が安定。`--cloud-provider=external` 推奨化。 |
| GA      | in-tree のコードを kubernetes/kubernetes から削除。 |

`--cloud-provider=external` は in-tree モードと違って kubelet 自身は AWS API を一切叩かない。代わりに「自分は cloud に紐づいた node です。CCM 来るまで動かさないでね」というシグナルとして `node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule` taint を node に付ける。

### 3.3 k8s 1.25 で in-tree AWS が消えた

[v1.25 リリースノート](https://kubernetes.io/blog/2022/08/23/kubernetes-v1-25-release/) で AWS の in-tree cloud-provider は最終的に削除された。本クラスタが使っている 1.30 でも当然削除済み。よって "今後新しく AWS で kubeadm を立てるなら out-of-tree CCM 一択" という前提が固まっている。

### 3.4 自己管理 kubeadm クラスタが取る選択肢

`--cloud-provider=external` を採用するうえで、本クラスタにとっての選択肢は次の 3 つだった。

| 案 | providerID の出どころ | CCM | コメント |
|----|---------------------|-----|---------|
| A  | CCM が後追いで埋める   | 必須 | 標準的だが、kubelet 登録から CCM が動くまでの間 LBC が "providerID 空" 警告を出す。また hostname が AWS の private DNS と一致していないと CCM が EC2 を引けない (本クラスタは独自 hostname を使っているので NG)。 |
| B  | kubelet `--provider-id` flag で先に埋める。CCM はゼロ。 | 不要 | 最小コスト。ただし node の zone/region label や node 削除時の cleanup は手動。 |
| C  | kubelet `--provider-id` flag で先に埋め、かつ CCM も入れる | 必須 | 起動時から providerID あり (= LBC 即解決) + CCM が他の補助も担う。両取り。 |

**選択は C**。理由:

- LBC の `providerID is not specified` warning を起動直後すら出させない。
- CCM が `topology.kubernetes.io/zone` / `region` / `node.kubernetes.io/instance-type` を埋めると、EBS CSI driver や topology-aware scheduling が機能する。
- node が EC2 上で terminate されたあと、CCM の node-controller が Kubernetes 側からも削除する (= ghost node 防止)。

---

## 4. AWS Cloud Controller Manager の中身

### 4.1 リポジトリと配布形態

- Upstream: https://github.com/kubernetes/cloud-provider-aws
- Helm chart: https://kubernetes.github.io/cloud-provider-aws (chart 名 `aws-cloud-controller-manager`)
- Container image: `registry.k8s.io/provider-aws/cloud-controller-manager:vX.Y.Z`

`aws-cloud-controller-manager` という単一の binary に node / route / service / volume の 4 つのループが入っている。

### 4.2 内部で動く 4 つの controller

CCM が起動すると、内部で次の controller を leader-election 経由で 1 つだけアクティブにする。

#### node-controller

- 新しく `Ready=Unknown` で登録された node について、`.spec.providerID` を見て EC2 DescribeInstances → instance を引き、次を行う:
  - `.spec.providerID` が空なら埋める。
  - label を埋める:
    - `topology.kubernetes.io/zone=ap-northeast-2a`
    - `topology.kubernetes.io/region=ap-northeast-2`
    - `node.kubernetes.io/instance-type=t3.large` (etc.)
    - `failure-domain.beta.kubernetes.io/zone` / `region` (deprecated だが互換のため)
  - `.status.addresses` を InternalIP / Hostname / InternalDNS / ExternalDNS で正規化。
  - `node.cloudprovider.kubernetes.io/uninitialized` taint を除去 (= scheduler に "schedule して OK" と伝える)。
- node が削除されたとき、対応する EC2 instance が terminate されていたら kubernetes 上からも node を削除する。

#### route-controller

- VPC の route table に Pod CIDR ごとの blackhole/route を作る。**本クラスタでは無効化** (Calico の IP-in-IP が pod NW を完結させているため)。

#### service-controller

- `Service type=LoadBalancer` に対して CLB (classic load balancer) を自動作成する。**本クラスタでは AWS LBC が ALB/NLB を作るため事実上未使用**。controller を完全に無効化することはできないが、LoadBalancer Service を作らないので衝突しない。
- 注意: 仮に annotation 無しで `Service type=LoadBalancer` を作ると、CCM が CLB を作りに行ってしまう可能性がある。LBC が provision するのは特定の annotation を持つ場合のみなので。詳細は §9.7。

#### volume-controller (deprecated)

- in-tree EBS volume の dynamic provisioning。**out-of-tree EBS CSI driver で置き換えるべき**。`--external-cloud-volume-plugin` flag を指定しないと CCM はこれを起動しない。本クラスタは IRSA で EBS CSI を別途入れる前提なので CCM の volume-controller は起動させない。

### 4.3 uninitialized taint の意味と除去メカニズム

kubelet が `--cloud-provider=external` で起動すると、node 登録のリクエストに次の taint を含める:

```yaml
spec:
  taints:
    - key: node.cloudprovider.kubernetes.io/uninitialized
      value: "true"
      effect: NoSchedule
```

これは「自分は cloud 由来の情報を埋めていないので、cloud-aware な workload を schedule しないでね」というシグナル。Default scheduler はこの taint を tolerate しない pod を弾く。

CCM の node-controller がこの node を初期化 (= providerID 検証 + label 付与) すると、最後にこの taint を patch で削除する。

| 状態 | taint | スケジュール可能な pod |
|------|------|---------------------|
| 起動直後 | あり | uninitialized を tolerate する pod のみ (= CNI DaemonSet, kube-proxy, CCM) |
| CCM 初期化後 | なし | 全 pod |

**重要**: CoreDNS Deployment は default だと uninitialized taint を tolerate しない。よって CCM が動くまで CoreDNS は Pending のまま。これが §6.8 で addons playbook を 2 段構えにした理由になる。

### 4.4 本クラスタで使う controller と無効化する controller

| Controller | 使う | 設定 |
|-----------|-----|-----|
| node       | ○ (本命) | デフォルトで有効 |
| route      | × | `--configure-cloud-routes=false` で無効化 |
| service    | △ (CLB を作らない限り無害) | デフォルト有効のまま放置 (annotation 無しの LoadBalancer Service を作らない運用に依存) |
| volume     | × | `--external-cloud-volume-plugin` を指定しない (デフォルトで起動しない) |

CCM の Helm chart `args:` に渡す主要 flag:

```yaml
args:
  - --v=2
  - --cloud-provider=aws
  - --cluster-name={{ cluster_name }}
  - --configure-cloud-routes=false
  - --use-service-account-credentials=true
```

---

## 5. アーキテクチャ全体像

### 5.1 シーケンス図 — ノード起動から LBC への登録まで

```
[EC2 起動]
     │
     ▼
[cloud-init で user_data 実行: hostnamectl set-hostname ap-northeast-2a-worker-01]
     │
     ▼
[ansible: kubeadm_join_worker role]
     │   1. IMDSv2 token を取得
     │   2. instance-id, AZ を IMDS から取得
     │   3. master から kubeadm token + ca hash を取得
     │   4. /etc/kubernetes/kubeadm-join-config.yaml を render
     │   5. kubeadm join --config <file>
     ▼
[kubelet 起動]
     │   --cloud-provider=external
     │   --provider-id=aws:///ap-northeast-2a/i-0abc...
     │
     ▼
[kubelet が Node を register]
     │   spec.providerID = "aws:///ap-northeast-2a/i-0abc..."   ← 起動と同時に埋まる
     │   spec.taints = [uninitialized:NoSchedule]               ← kubelet が自分で付ける
     │
     ▼
[CCM (master の DaemonSet) がこの node を観測]
     │   1. providerID を parse して EC2 DescribeInstances
     │   2. zone/region/instance-type を label として set
     │   3. addresses を整形
     │   4. uninitialized taint を patch で削除
     │
     ▼
[CoreDNS / aws-lbc 等の Pod が schedule される]
     │
     ▼
[AWS LBC が node を見て target group に register]
     │   providerID から InstanceID を取り、Service NodePort 経由で登録
     ▼
[NLB target group に EC2 が並ぶ]
     │
     ▼
[外部からの HTTP / TCP が通る]
```

**ポイント**: providerID は kubelet 登録時点で既に埋まっているので、AWS LBC は CCM の到着を待たない。CCM はあくまで補助 (taint 除去 + label) として後追いで動く。

### 5.2 静的 manifest と DaemonSet の関係

CCM は kubelet ではなく Kubernetes の Pod として動くが、kubeadm の "static pod" ではなく **通常の DaemonSet として helm でインストール**する。

| 種類 | 配置場所 | 何で動かす |
|------|--------|-----------|
| static pod | `/etc/kubernetes/manifests/*.yaml` | kubelet が直接起動 (apiserver, etcd, controller-manager, scheduler) |
| DaemonSet  | apiserver 上の DaemonSet resource | scheduler 経由 |

CCM を static pod にする選択肢もある (`kubeadm-config.yaml` の `controllerManager.extraArgs` のさらに先) が、本構成では Helm で DaemonSet として入れる。理由:

- Helm chart のアップグレードがそのまま使える。
- CCM の crash で apiserver が apiserver pod を再起動 (=巻き添え) するリスクがない。
- 値の上書きが values.yaml で一元化できる。

ただし DaemonSet なので scheduler が必要 → **scheduler が動いてさえいれば、kubelet uninitialized taint を tolerate して control-plane に schedule される** (CCM 自身は tolerations を持っている)。

### 5.3 認証経路 — IRSA を使わず Node IAM Role を使う理由

CCM は AWS API を叩く (EC2 DescribeInstances 等)。その credential 取得には大きく 2 経路ある。

| 経路 | 仕組み | 採否 |
|-----|------|-----|
| IRSA | ServiceAccount → projected SA token → STS:AssumeRoleWithWebIdentity → IAM Role | × (overkill) |
| Node IAM Role | pod が hostNetwork=true で動き、IMDS にアクセス → instance profile credential | ○ (採用) |

本クラスタでは IRSA を別途構成済 (EBS CSI driver 用) だが、CCM については Node IAM Role を使う。理由:

- CCM は master ノードでだけ動く。master の instance profile (`ktcloud_cluster_node_profile`) に CCM 用ポリシーを足せば済む。
- IRSA を CCM に使うと、認証チェーンが「pod が EC2 を叩くために、まず S3 上の JWKS を引いて、STS に行って…」と複雑になる。
- master が壊れて CCM が落ちた時、IRSA のチェーンも怪しい時に切り分けが難しい。

ということで CCM の Helm chart を入れる際は `serviceAccount.create=true` のまま、Pod が IMDS 経由で Node IAM Role の credential を使う。IAM 側で `ktcloud-cluster-node-role` に CCM 必要権限をアタッチする。

---

## 6. 実装 — ファイル単位の詳細

### 6.1 変更ファイル一覧

| ファイル | 役割 | 種類 |
|--------|-----|-----|
| `terraform/iam.tf` | CCM 用 IAM inline policy 追加 | 修正 |
| `ansible/roles/kubeadm_init/templates/kubeadm-config.yaml.j2` | InitConfiguration 追加、controllerManager.extraArgs.cloud-provider=external 追加 | 修正 |
| `ansible/roles/kubeadm_init/tasks/main.yaml` | IMDSv2 から instance-id / AZ を取得するタスク追加 | 修正 |
| `ansible/roles/kubeadm_join_worker/tasks/main.yaml` | join command parse + IMDSv2 取得 + JoinConfiguration render | 修正 |
| `ansible/roles/kubeadm_join_worker/templates/kubeadm-join-config.yaml.j2` | JoinConfiguration template | 新規 |
| `ansible/roles/aws_ccm/tasks/main.yaml` | CCM Helm install + uninitialized taint 除去の待機 | 新規 |
| `ansible/playbooks/addons.yaml` | 2 段 play へ分割 (CCM を kube-system Ready gate より前) | 修正 |
| `ansible/group_vars/all.yaml` | `aws_ccm_namespace` 変数追加 | 修正 |
| `CLAUDE.md` | アーキテクチャ説明、addon playbook 順序、prereq に CCM 記載追加 | 修正 |

### 6.2 Terraform: `terraform/iam.tf`

既存の `data "aws_iam_role" "ktcloud_cluster_node_role"` (out-of-band で作られている前提) に、CCM 必要権限を **inline policy** として attach する。

なぜ inline で別 policy ではなく `aws_iam_role_policy` (= inline) を選ぶか:

- `aws_iam_policy` + `aws_iam_role_policy_attachment` でも同じ結果になるが、policy resource が独立すると `terraform destroy` で role 側に detach 残骸が残るケースがある (data source の role を Terraform は管理していないため)。
- inline は role と運命を共にする (role を消したら policy も消える) ので、本構成のように role が外で生きている前提のときに副作用が小さい。

権限は cloud-provider-aws の [prerequisites doc](https://cloud-provider-aws.sigs.k8s.io/prerequisites/) に挙がっている標準セットから、本クラスタで実際に使う controller のぶんだけ。具体的には:

- `ec2:Describe*` 系: node controller が必要。
- `ec2:CreateTags`, `ModifyInstanceAttribute`, `ModifyVolume`, `AttachVolume`, `DetachVolume`: CSI driver や source/dest check の調整。一部冗長だが、運用負担を下げるため最小同等を維持。
- `iam:CreateServiceLinkedRole` (`elasticloadbalancing.amazonaws.com`, `autoscaling.amazonaws.com` 限定): CCM 起動時に必要に応じて SLR を作る。
- `kms:DescribeKey`: EBS 暗号化 volume の topology 確認時に呼ばれる。

完成版 `terraform/iam.tf`:

```hcl
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
```

注意点:

- `iam:CreateServiceLinkedRole` は `condition` で `iam:AWSServiceName` を `elasticloadbalancing.amazonaws.com` と `autoscaling.amazonaws.com` に限定。任意のサービスの SLR を作らせない最小化。
- `ec2:CreateTags` の resource は `*` のまま。**本来は `Resource` を絞り、condition で `ec2:ResourceTag/kubernetes.io/cluster/<name>=owned` 等を入れたほうがより安全**。今回は CCM が tag 経由でクラスタ識別を行うので、起動の確実性を優先して `*`。将来的に絞りたければ §10.1 参照。

### 6.3 Ansible: `roles/kubeadm_init/templates/kubeadm-config.yaml.j2`

kubeadm v1beta3 の config は複数 YAML document を `---` 区切りで 1 ファイルに並べる方式。本構成は次の 3 document を持つ。

1. `InitConfiguration` — kubelet の起動 flag を入れる。
2. `ClusterConfiguration` — apiserver, controller-manager, etcd, network 等。
3. `KubeletConfiguration` — kubelet 共通の設定 (cgroup driver など)。

#### InitConfiguration

```yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "{{ containerd_cri_socket }}"
  kubeletExtraArgs:
    cloud-provider: external
    provider-id: "aws:///{{ aws_instance_az }}/{{ aws_instance_id }}"
```

- `criSocket`: containerd の UDS。既に group_vars にあったので変数化。
- `kubeletExtraArgs.cloud-provider`: external → in-tree を切り、uninitialized taint を付与させる。
- `kubeletExtraArgs.provider-id`: master 自身の providerID を IMDS から取った値で先に固定。

`aws_instance_az` / `aws_instance_id` は `tasks/main.yaml` で IMDSv2 から取得する Ansible fact。

#### ClusterConfiguration

既存ブロック (apiServer.certSANs, IRSA まわり) は維持。`controllerManager.extraArgs.cloud-provider=external` を追加:

```yaml
controllerManager:
  extraArgs:
    cloud-provider: external
```

これにより kube-controller-manager の起動時 flag に `--cloud-provider=external` が渡る。意味は「自分は cloud-aware な制御 (node controller, route controller, service controller) はしない。CCM に任せる」。これをしないと KCM の node controller が CCM とぶつかる (どちらが authoritative か曖昧になる)。

#### apiServer については cloud-provider flag は **設定しない**

過去のドキュメントを引きずって `apiServer.extraArgs.cloud-provider=external` を書く誤りが散見されるが、kube-apiserver の `--cloud-provider` flag は 1.21 以降廃止 (もしくは no-op)。書くと unknown flag で apiserver が CrashLoopBackOff になる場合があるので明示的に書かない。

#### 完成版

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "{{ containerd_cri_socket }}"
  kubeletExtraArgs:
    cloud-provider: external
    provider-id: "aws:///{{ aws_instance_az }}/{{ aws_instance_id }}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "v{{ kubernetes_version }}.0"
controlPlaneEndpoint: "{{ ansible_default_ipv4.address }}:6443"
networking:
  podSubnet: "{{ pod_subnet }}"
apiServer:
  certSANs:
    - "{{ ansible_default_ipv4.address }}"
    - "127.0.0.1"
    - "localhost"
{% if irsa_oidc_issuer_url is defined %}
  extraArgs:
    service-account-issuer: "{{ irsa_oidc_issuer_url }}"
    api-audiences: "sts.amazonaws.com,https://kubernetes.default.svc.cluster.local"
    service-account-jwks-uri: "{{ irsa_oidc_issuer_url }}/openid/v1/jwks"
{% endif %}
controllerManager:
  extraArgs:
    cloud-provider: external
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

### 6.4 Ansible: `roles/kubeadm_init/tasks/main.yaml`

#### 追加した部分

`/etc/kubernetes/kubeadm-config.yaml` を render する前に、IMDSv2 経由で次を取得する。

- `aws_instance_id`: 自インスタンスの ID
- `aws_instance_az`: 自インスタンスの AZ

IMDSv2 は token-based なので、まず `PUT /latest/api/token` で短命 token を取り、それを `X-aws-ec2-metadata-token` ヘッダで以降のリクエストに付ける。

```yaml
- name: IMDSv2 token を取得
  ansible.builtin.uri:
    url: http://169.254.169.254/latest/api/token
    method: PUT
    headers:
      X-aws-ec2-metadata-token-ttl-seconds: "60"
    return_content: true
  register: imds_token

- name: 自インスタンスの instance-id を取得
  ansible.builtin.uri:
    url: http://169.254.169.254/latest/meta-data/instance-id
    headers:
      X-aws-ec2-metadata-token: "{{ imds_token.content }}"
    return_content: true
  register: imds_instance_id

- name: 自インスタンスの AZ を取得
  ansible.builtin.uri:
    url: http://169.254.169.254/latest/meta-data/placement/availability-zone
    headers:
      X-aws-ec2-metadata-token: "{{ imds_token.content }}"
    return_content: true
  register: imds_az

- name: IMDS から取得した値を fact 化
  ansible.builtin.set_fact:
    aws_instance_id: "{{ imds_instance_id.content }}"
    aws_instance_az: "{{ imds_az.content }}"
```

#### なぜ IMDSv1 ではなく v2 か

- IMDSv1 は token なしで読めるので、SSRF 攻撃で credential を抜かれるリスクが恒常的。
- v2 は PUT + token なので、HTTP GET だけしか発行できない SSRF では到達できない。
- 本クラスタの EC2 インスタンスは `HttpTokens=optional` (Terraform 側でデフォルト) のはずだが、念のため v2 経路を使う実装に統一しておけば、将来 `HttpTokens=required` に変えても壊れない。

#### kubeadm-config.yaml render → kubeadm init

その後の `kubeadm init` 自体は既存タスクのまま。`--config /etc/kubernetes/kubeadm-config.yaml` を渡しているので新しい InitConfiguration が効く。

#### 冪等性

- `kubeadm init` は `creates: {{ admin_conf_path }}` で `/etc/kubernetes/admin.conf` がある場合 skip。
- IMDS 取得タスクは毎回実行されるが side effect なし。

### 6.5 Ansible: `roles/kubeadm_join_worker/tasks/main.yaml`

ここがいちばん作り替えた箇所。以前は次のような単純な流れだった。

```
master で `kubeadm token create --print-join-command` 実行
↓ 結果を fact として全 worker に配布
↓ worker で `<join command> --cri-socket <containerd>` をシェル実行
```

これだと kubeletExtraArgs を渡せない。`kubeadm join` の bare command (token + hash + apiserver endpoint をそのまま argv) では `--node-extra-arg` のような後付け方法がない。よって **JoinConfiguration YAML を render して `kubeadm join --config <file>` に切り替える**。

#### 1. master 側で必要情報を生成

`kubeadm token create --print-join-command` の出力例:

```
kubeadm join 10.0.2.217:6443 --token a1b2c3.aaaaaaaaaaaaaaaa --discovery-token-ca-cert-hash sha256:bcd234...
```

これを `delegate_to: master`, `run_once: true` で 1 度だけ実行し、3 つの値を抜き出す:

- apiServer endpoint (`10.0.2.217:6443`)
- token (`a1b2c3.aaaaaaaaaaaaaaaa`)
- CA cert hash (`sha256:bcd234...`)

抽出は `regex_search` + group 参照:

```yaml
- name: join コマンドから endpoint / token / hash を抽出
  ansible.builtin.set_fact:
    kubeadm_apiserver_endpoint: "{{ worker_join_cmd_raw.stdout
        | regex_search('kubeadm join (\\S+)', '\\1') | first }}"
    kubeadm_token: "{{ worker_join_cmd_raw.stdout
        | regex_search('--token (\\S+)', '\\1') | first }}"
    kubeadm_ca_cert_hash: "{{ worker_join_cmd_raw.stdout
        | regex_search('--discovery-token-ca-cert-hash (\\S+)', '\\1') | first }}"
```

`regex_search(pattern, group1, group2, ...)` は group reference を渡すと group 値のリストを返す。`| first` で 1 つ目を取る。

#### 2. master から全 worker に値を配布

これは元コードと同じパターン。fact を delegate_facts で配る:

```yaml
- name: 抽出した値を worker 全台に fact として配布
  ansible.builtin.set_fact:
    kubeadm_apiserver_endpoint: "{{ kubeadm_apiserver_endpoint }}"
    kubeadm_token: "{{ kubeadm_token }}"
    kubeadm_ca_cert_hash: "{{ kubeadm_ca_cert_hash }}"
  delegate_to: "{{ item }}"
  delegate_facts: true
  loop: "{{ groups['workers'] }}"
```

#### 3. 各 worker で自分の IMDS を読む

`kubeadm_init` と同じ仕組み。IMDSv2 token → instance-id → AZ。

#### 4. JoinConfiguration を render

`templates/kubeadm-join-config.yaml.j2` を `/etc/kubernetes/kubeadm-join-config.yaml` に展開。

#### 5. `kubeadm join --config` 実行

```yaml
- name: kubeadm join の実行（--config 使用）
  ansible.builtin.command: kubeadm join --config /etc/kubernetes/kubeadm-join-config.yaml
  args:
    creates: /etc/kubernetes/kubelet.conf
  register: worker_join_result
  failed_when:
    - worker_join_result.rc is defined
    - worker_join_result.rc != 0
    - "'already exists' not in (worker_join_result.stderr | default(''))"
```

- `creates: /etc/kubernetes/kubelet.conf` で冪等化 (join 済 worker は再実行しても何もしない)。
- `failed_when` で "already exists" は無視。再 join を試したときに発生するメッセージ。

### 6.6 Ansible: `roles/kubeadm_join_worker/templates/kubeadm-join-config.yaml.j2`

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "{{ kubeadm_apiserver_endpoint }}"
    token: "{{ kubeadm_token }}"
    caCertHashes:
      - "{{ kubeadm_ca_cert_hash }}"
nodeRegistration:
  criSocket: "{{ containerd_cri_socket }}"
  kubeletExtraArgs:
    cloud-provider: external
    provider-id: "aws:///{{ aws_instance_az }}/{{ aws_instance_id }}"
```

各フィールドの意味:

| フィールド | 内容 |
|----------|-----|
| `discovery.bootstrapToken.apiServerEndpoint` | join 先 apiserver (IP:port) |
| `discovery.bootstrapToken.token` | bootstrap token (= `kubeadm token create` の出力) |
| `discovery.bootstrapToken.caCertHashes` | apiserver CA の SHA256 hash。MITM 防止のため caCertHashes と token の組み合わせで信頼を確立する。 |
| `nodeRegistration.criSocket` | container runtime endpoint (containerd UDS) |
| `nodeRegistration.kubeletExtraArgs.cloud-provider` | `external` |
| `nodeRegistration.kubeletExtraArgs.provider-id` | `aws:///<az>/<instance-id>` |

注: `kubeletExtraArgs` の値は YAML 上はキー名がハイフン記法 (`cloud-provider`)。実体は kubelet の `--cloud-provider` flag。

### 6.7 Ansible: `roles/aws_ccm/tasks/main.yaml`

CCM を helm で入れる新規 role。流れは:

1. helm repo `aws-cloud-controller-manager` を登録 (URL: https://kubernetes.github.io/cloud-provider-aws)。
2. `helm install` で `aws-cloud-controller-manager` chart を `kube-system` にデプロイ。
3. uninitialized taint が全 node から消えるまで待機。

#### Helm values の主要ポイント

```yaml
args:
  - --v=2
  - --cloud-provider=aws
  - --cluster-name={{ cluster_name }}
  - --configure-cloud-routes=false
  - --use-service-account-credentials=true
```

- `--cloud-provider=aws`: AWS 用のコードパスを使う。
- `--cluster-name=kt-cloud-cluster`: tag 経由のクラスタ識別 (`kubernetes.io/cluster/kt-cloud-cluster=owned`) と一致させる。
- `--configure-cloud-routes=false`: VPC route table をいじらない。Calico (IPIP) が pod NW を完結させているため不要。
- `--use-service-account-credentials=true`: leader election や node patch に CCM 専用 SA を使う (RBAC 最小化)。

```yaml
nodeSelector:
  node-role.kubernetes.io/control-plane: ""
```

- control-plane でだけ動かす。CCM は単一 instance が動けばよく、leader election を考えても通常は master 1 台 + spare 数台。

```yaml
tolerations:
  - key: node.cloudprovider.kubernetes.io/uninitialized
    value: "true"
    effect: NoSchedule
  - key: node-role.kubernetes.io/control-plane
    effect: NoSchedule
  - key: node-role.kubernetes.io/master
    effect: NoSchedule
```

- 自分自身が uninitialized taint を tolerate しないと、起動できない。
- master の `node-role.kubernetes.io/control-plane:NoSchedule` taint を tolerate しないと control-plane に schedule されない。
- 古い `node-role.kubernetes.io/master:NoSchedule` も互換のため一応 tolerate しておく。

#### taint 除去待機タスク

```yaml
- name: CCM が master の uninitialized taint を除去するまで待機
  ansible.builtin.shell: |
    set -o pipefail
    kubectl --kubeconfig={{ admin_conf_path }} get node \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")].key}{"\n"}{end}' \
      | awk '$2 != "" { bad=1 } END { exit bad ? 1 : 0 }'
  args:
    executable: /bin/bash
  register: ccm_taint_check
  changed_when: false
  retries: 30
  delay: 5
  until: ccm_taint_check.rc == 0
```

各 node の uninitialized taint を jsonpath で抜き出し、awk で「1 つでも空でないやつがあれば bad」と判定。`retries: 30, delay: 5` なので最大 150 秒待つ。

この待機がないと、次の play (LBC など) で kube-system pods Ready gate が永遠に Pending するという闇のループに入る可能性がある。

### 6.8 Ansible: `playbooks/addons.yaml`

#### 元の構造

1 つの play で:

```yaml
hosts: master
pre_tasks:
  - kube-system 全 pod が Running になるまで待機  ← この gate
roles:
  - helm
  - aws_lbc
  - argocd
  - traefik (条件付き)
```

#### 問題

CCM を追加すると、gate (`kube-system 全 pod Running`) で **CoreDNS が永遠に Pending** になる。理由:

1. 全 node が kubelet `--cloud-provider=external` で起動 → uninitialized taint 付き。
2. CoreDNS Deployment はその taint を tolerate しないので Pending。
3. CCM がまだ起動していないので taint も消えない。
4. `pre_tasks` の gate は CoreDNS が Running になるのを待つ → 永遠に終わらない。

つまり「先に CCM を入れて taint を消さないと、kube-system Ready gate を超えられない」というデッドロックになる。

#### 解決策

play を 2 つに分ける:

```yaml
- name: 事前段 — Helm と AWS CCM
  hosts: master
  become: true
  roles:
    - role: helm
    - role: aws_ccm

- name: 本段 — AWS LBC / ArgoCD / Traefik
  hosts: master
  become: true
  pre_tasks:
    - 既存の kube-system Ready gate
  roles:
    - role: aws_lbc
    - role: argocd
    - role: traefik (条件付き)
```

- Play 1: gate なしで helm + CCM を入れる。CCM が taint を消した時点で終了。
- Play 2: 既存の gate を維持。CCM のおかげで CoreDNS は Running になっているので gate を通過 → LBC 等を入れる。

#### helm role に依存がないことの確認

helm role は単に helm binary を `/usr/local/bin/helm` に置くだけで、K8s クラスタとの通信を必要としない。`current_helm.rc != 0 or helm_version not in current_helm.stdout` で版チェックする以外は完全にローカル処理。よって CCM より前に置いても問題ない。

#### aws_ccm role 内での helm 利用は OK

CCM のインストールは `kubernetes.core.helm` module 経由で apiserver と通信する。apiserver は static pod で kubeadm init 直後から動いているので、kube-system 全 pod が Ready でなくても CCM Helm デプロイは成功する。

### 6.9 Ansible: `group_vars/all.yaml`

```yaml
aws_region: "ap-northeast-2"
cluster_name: "kt-cloud-cluster"
aws_lbc_namespace: "kube-system"
aws_ccm_namespace: "kube-system"   # 追加
```

`aws_ccm` role が namespace を引くための変数。`kube-system` に置く理由:

- kube-system は cluster の system component を集める標準的な namespace。
- CCM は cluster 必須コンポーネントなので業務 workload と分離した system namespace が妥当。
- AWS LBC と同居しても衝突しない (リソース名が異なる)。

---

## 7. ライブクラスタへの応急処置 (記録)

IaC を直す前段として、本番稼働中のクラスタには **kubectl で直接 providerID を patch する応急処置** を入れていた。記録として残す。

### 7.1 状況把握コマンド

```bash
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PROVIDER_ID:.spec.providerID
NAME                       PROVIDER_ID
ap-northeast-2a-master-01  <none>
ap-northeast-2a-worker-01  <none>
ap-northeast-2a-worker-02  <none>
ap-northeast-2b-worker-01  <none>
ap-northeast-2b-worker-02  <none>
ap-northeast-2b-worker-03  <none>
```

全 node `<none>`。EC2 console で各 node の AZ と InstanceID を控えて、対応表を作る:

| Node | AZ | InstanceID |
|------|----|-----------|
| ap-northeast-2a-master-01 | ap-northeast-2a | i-0xxxxx... |
| ap-northeast-2a-worker-01 | ap-northeast-2a | i-0yyyyy... |
| ... | ... | ... |

### 7.2 providerID 直接 patch

```bash
$ kubectl patch node ap-northeast-2a-master-01 \
    -p '{"spec":{"providerID":"aws:///ap-northeast-2a/i-0xxxxx..."}}'

$ kubectl patch node ap-northeast-2a-worker-01 \
    -p '{"spec":{"providerID":"aws:///ap-northeast-2a/i-0yyyyy..."}}'

# ... 6 ノードぶん繰り返し
```

成功確認:

```bash
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PROVIDER_ID:.spec.providerID
NAME                       PROVIDER_ID
ap-northeast-2a-master-01  aws:///ap-northeast-2a/i-0xxxxx...
ap-northeast-2a-worker-01  aws:///ap-northeast-2a/i-0yyyyy...
...
```

### 7.3 LBC の挙動確認

```bash
$ kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20
{"level":"info","ts":"...","msg":"successful reconcile","targetGroup":"k8s-traefik-traefik-df452a5320","targetCount":5}
```

target count が 0 から 5 (worker 数) に変わったのを確認。master は NodePort backend として登録されない (= control-plane taint で NodePort を持つ DaemonSet が居ない、もしくは LBC が control-plane を除外する) ので 5 ノード。

AWS console で NLB target group を見ても 5 つの instance が healthy で並んでいる。`curl https://<NLB-DNS>/` が応答するようになる。

**注意**: この応急処置は kubelet 再起動や node 再作成で取れる。永続化には IaC 側 (本レポート §6) の変更が必要。

---

## 8. 検証手順

IaC 変更を反映した後の `make cluster-up` → `make verify` で次を順に確認する。

### 8.1 providerID が全 node に埋まっていること

```bash
$ kubectl get nodes -o custom-columns=NAME:.metadata.name,PROVIDER_ID:.spec.providerID
NAME                       PROVIDER_ID
ap-northeast-2a-master-01  aws:///ap-northeast-2a/i-0xxxxxxxxxx
ap-northeast-2a-worker-01  aws:///ap-northeast-2a/i-0yyyyyyyyyy
ap-northeast-2a-worker-02  aws:///ap-northeast-2a/i-0zzzzzzzzzz
ap-northeast-2b-worker-01  aws:///ap-northeast-2b/i-0aaaaaaaaaa
ap-northeast-2b-worker-02  aws:///ap-northeast-2b/i-0bbbbbbbbbb
ap-northeast-2b-worker-03  aws:///ap-northeast-2b/i-0cccccccccc
```

全 6 ノードに `aws:///<az>/<instance-id>` 形式で埋まっていること。format error (例: `aws://<az>/<id>` のように slash が足りない) は LBC が parse 失敗するので注意。

### 8.2 uninitialized taint がないこと

```bash
$ kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.taints[?(@.key=="node.cloudprovider.kubernetes.io/uninitialized")]}{"\n"}{end}'
ap-northeast-2a-master-01
ap-northeast-2a-worker-01
ap-northeast-2a-worker-02
ap-northeast-2b-worker-01
ap-northeast-2b-worker-02
ap-northeast-2b-worker-03
```

2 列目 (taint) がすべて空であること。1 つでも空でなければ CCM がその node を初期化していない (= 何か起きている)。§9.2 参照。

### 8.3 zone/region label が CCM で付いていること

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone,topology.kubernetes.io/region,node.kubernetes.io/instance-type
NAME                       STATUS   ROLES           AGE   VERSION   ZONE              REGION            INSTANCE-TYPE
ap-northeast-2a-master-01  Ready    control-plane   10m   v1.30.x   ap-northeast-2a   ap-northeast-2    t3.large
ap-northeast-2a-worker-01  Ready    <none>          9m    v1.30.x   ap-northeast-2a   ap-northeast-2    t3.medium
...
```

CCM の node-controller が動いていれば zone / region / instance-type すべて埋まる。空なら CCM が動いていないか IAM 権限不足 (§9.1)。

### 8.4 CCM Pod が control-plane で Ready であること

```bash
$ kubectl get pods -n kube-system -l k8s-app=aws-cloud-controller-manager -o wide
NAME                                          READY   STATUS    RESTARTS   AGE   IP           NODE                       NOMINATED NODE   READINESS GATES
aws-cloud-controller-manager-xxxxx            1/1     Running   0          10m   10.0.2.217   ap-northeast-2a-master-01   <none>           <none>
```

`hostNetwork: true` なので IP は master の private IP。

### 8.5 AWS LBC ログに providerID 欠落エラーがないこと

```bash
$ kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=5m | grep -i provideri
# (出力なし、または "providerID is not specified" が出ない)
```

過去 5 分のログに `providerID is not specified` が一切ないこと。

### 8.6 ALB/NLB の target group が登録されていること

```bash
$ aws elbv2 describe-target-groups --query 'TargetGroups[?contains(TargetGroupName, `traefik`)]' --output table

$ aws elbv2 describe-target-health \
    --target-group-arn arn:aws:elasticloadbalancing:ap-northeast-2:123456789012:targetgroup/k8s-traefik-traefik-df452a5320/xxxxxxxx \
    --query 'TargetHealthDescriptions[*].[Target.Id,TargetHealth.State]' \
    --output table
-------------------------------------
|       DescribeTargetHealth        |
+----------------------+------------+
|  i-0yyyyyyyyyy       |  healthy   |
|  i-0zzzzzzzzzz       |  healthy   |
|  i-0aaaaaaaaaa       |  healthy   |
|  i-0bbbbbbbbbb       |  healthy   |
|  i-0cccccccccc       |  healthy   |
+----------------------+------------+
```

5 ノード ぶん `healthy`。master は NodePort をリッスンしていないので含まれないのが正常。

### 8.7 traefik 経由の HTTP 通信が通ること

```bash
$ curl -sv https://<NLB-DNS-name>/  2>&1 | tail -20
< HTTP/2 404
< content-type: text/plain; charset=utf-8
<
404 page not found
```

404 でも、それは traefik が応答した結果 (= NLB → NodePort → traefik まで届いている)。TCP timeout で死ぬのが NG。
任意の IngressRoute が刺さっているドメインで叩けばその backend の応答が返る。

---

## 9. トラブルシューティング

### 9.1 CCM Pod が CrashLoopBackOff になる (IAM 権限不足)

#### 症状

```bash
$ kubectl get pods -n kube-system -l k8s-app=aws-cloud-controller-manager
NAME                                   READY   STATUS             RESTARTS   AGE
aws-cloud-controller-manager-xxxxx     0/1     CrashLoopBackOff   3          2m

$ kubectl logs -n kube-system aws-cloud-controller-manager-xxxxx
...
E0517 ... reflector.go:138] AccessDenied: User: arn:aws:sts::123...:assumed-role/ktcloud-cluster-node-role/i-0xxx is not authorized to perform: ec2:DescribeInstances
...
```

#### 原因

`ktcloud-cluster-node-role` に CCM 必要権限が attach されていない。Terraform 側の `aws_iam_role_policy.ccm` リソースが apply されていないか、role 名が違う。

#### 対処

```bash
$ aws iam list-role-policies --role-name ktcloud-cluster-node-role
{
  "PolicyNames": [
    "ktcloud-cluster-ccm-policy"
  ]
}

$ aws iam get-role-policy --role-name ktcloud-cluster-node-role --policy-name ktcloud-cluster-ccm-policy
```

`ktcloud-cluster-ccm-policy` がなければ `make tf-apply` を実行。あるが該当 action が含まれていなければ `terraform/iam.tf` の `data.aws_iam_policy_document.ccm` を確認・修正。

### 9.2 uninitialized taint が消えない

#### 症状

```bash
$ kubectl describe node ap-northeast-2a-worker-01 | grep -A 3 Taints
Taints:             node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
```

CoreDNS や ArgoCD などが Pending のまま。

#### 原因の可能性

| 仮説 | 切り分け |
|-----|---------|
| CCM Pod がそもそも起動していない | `kubectl get pods -n kube-system -l k8s-app=aws-cloud-controller-manager` |
| CCM が IAM AccessDenied | §9.1 と同じ |
| providerID format が間違っている | `kubectl get node <name> -o jsonpath='{.spec.providerID}'` で `aws:///<az>/<id>` か確認 |
| node の providerID と AWS 実体が一致しない (例: 旧 EC2 の id が残っている) | DescribeInstances で存在するか確認 |

#### 対処

providerID format ミスは多い。`aws://<az>/<id>` (slash が 1 つ) や `<az>/<id>` (prefix なし) は CCM が parse できず taint を消さない。Terraform の `data "aws_iam_role"` で URL が大文字小文字違いになっていないか確認。

### 9.3 join した worker の providerID が空

#### 症状

新しく追加した worker だけ providerID が空。

#### 原因の可能性

- JoinConfiguration が render されていない (旧 join command を直接実行していた)。
- `kubeadm join --config` ではなく古い形式で実行している。
- IMDS が disabled (`HttpEndpoint=disabled`) になっている (= terraform 側で `metadata_options` を強制 disable していると死ぬ)。

#### 対処

```bash
# join 設定が render された痕跡
$ ssh worker-XX 'sudo cat /etc/kubernetes/kubeadm-join-config.yaml'

# 実際に kubelet に渡された引数
$ ssh worker-XX 'sudo cat /var/lib/kubelet/kubeadm-flags.env'
KUBELET_KUBEADM_ARGS="--cloud-provider=external --provider-id=aws:///ap-northeast-2a/i-... ..."
```

`kubeadm-flags.env` に `--provider-id` が無ければ JoinConfiguration の段で抜けている。Ansible role の出力ログを遡って render が成功しているか確認。

### 9.4 controller-manager が起動しない

#### 症状

`kube-controller-manager` static pod が CrashLoopBackOff。

```
E0517 ... unknown flag: --cloud-provider
```

#### 原因

kubeadm のバージョンによっては `--cloud-provider=external` が deprecated → 完全削除。1.30 では external は受け付けるはず。

#### 対処

`kubeadm version` を確認。1.29 以下なら念のため `--cloud-provider=` (空文字) を試す。1.31 以降は仕様変化を確認 (KEP-2392 の進捗を参照)。

### 9.5 IMDSv2 の token 取得が 403 を返す

#### 症状

```
fatal: [worker-01]: FAILED! => {"changed": false, "msg": "Status code was 403 ..."}
```

#### 原因

EC2 instance の `metadata_options` で:
- `HttpEndpoint=disabled` (= IMDS 自体無効)
- `HttpTokens=required` で TTL を超えた token 再利用

または、`HttpPutResponseHopLimit=1` で hop limit が低く、container 経由のアクセスがブロックされている (本作業の Ansible は host で実行されるので関係ないはず)。

#### 対処

```bash
$ aws ec2 describe-instances --instance-ids i-0xxx \
    --query 'Reservations[].Instances[].MetadataOptions'
```

`HttpEndpoint` が `enabled` であること、`HttpTokens` が `required` か `optional` であること。`disabled` なら Terraform で明示的に enable。

### 9.6 CoreDNS が Pending のまま

#### 症状

```bash
$ kubectl get pods -n kube-system | grep coredns
coredns-xxxxxxxxxx-xxxxx   0/1     Pending   0          5m
coredns-xxxxxxxxxx-yyyyy   0/1     Pending   0          5m
```

#### 原因

CCM が動いておらず uninitialized taint が消えていない。§9.2 と同根。

#### 対処

CCM Pod のログを確認 → IAM 権限 (§9.1) または providerID format (§9.2) の問題を疑う。両方 OK なら CCM 自体のクラッシュを確認:

```bash
$ kubectl describe pod -n kube-system -l k8s-app=aws-cloud-controller-manager
$ kubectl logs -n kube-system -l k8s-app=aws-cloud-controller-manager --previous
```

### 9.7 CCM が Service コントローラとして CLB を作ろうとする

#### 症状

annotation なしで `Service type=LoadBalancer` を作ったとき、想定外に Classic Load Balancer (CLB) が作られる。

#### 原因

CCM の service-controller がデフォルトで有効になっており、AWS LBC が "自分の管轄ではない" と判断した Service (= LBC 用 annotation がない) を CCM が引き取って CLB を作る。

#### 対処

`Service type=LoadBalancer` を作る場合は必ず LBC 用の annotation を付ける:

```yaml
metadata:
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-type: external
    service.beta.kubernetes.io/aws-load-balancer-nlb-target-type: instance
    service.beta.kubernetes.io/aws-load-balancer-scheme: internet-facing
```

これらの annotation がついていると LBC が NLB を作り、CCM の service-controller は手を出さない。

annotation 漏れを完全に防ぎたければ:

- CCM の chart values で `--controllers` を `*,-service` のように Service controller だけ無効化する (chart によって flag 名が違うので注意)。
- もしくは admission webhook (kyverno 等) で `service.beta.kubernetes.io/aws-load-balancer-type` 必須の policy を入れる。

---

## 10. セキュリティ・運用上の留意点

### 10.1 IAM ポリシースコープの最小化

現状の `aws_iam_role_policy.ccm` は `Resource: "*"`。実運用で絞るなら:

```hcl
condition {
  test     = "StringEquals"
  variable = "ec2:ResourceTag/kubernetes.io/cluster/${var.cluster_name}"
  values   = ["owned"]
}
```

を `Modify*` / `CreateTags` の statement に追加すると、本クラスタの node 以外を CCM がいじれなくなる。CCM の初期化フェーズで自身の instance に対して tag を作るケースもあるので、event-driven な失敗を観測しながら絞る。

### 10.2 IMDSv2 強制

Terraform 側で `aws_instance` resource に次を追加すれば IMDSv1 を完全に拒否できる:

```hcl
metadata_options {
  http_endpoint               = "enabled"
  http_tokens                 = "required"
  http_put_response_hop_limit = 2
}
```

`http_put_response_hop_limit = 2` は container 内から IMDS を読む場合に必要 (1 だと container ネットワークから hop が 1 つ多くて到達不能)。pod が IMDS を直接使う構成 (= 本クラスタの CCM) なら 2 が安全側。

Ansible の IMDS 取得タスクは host (= EC2 直) で動くので hop limit の影響は受けない。

### 10.3 providerID と node 削除の関係

CCM の node-controller は、Kubernetes node に対応する EC2 instance が terminate されていた場合、Kubernetes node も削除する。これにより:

- ASG 等で node が入れ替わったとき、自動で ghost node が掃除される。
- 逆に、何らかの理由で EC2 が一時的に Stopped 状態だと node を消されてしまう可能性がある (現行版 CCM は Stopped を terminate と区別する仕様だが、過去バグあり)。

運用上は、メンテナンスで EC2 を停止する場合に短時間で再開させるか、`kubectl cordon` で外しておく。

### 10.4 EBS volume topology との連携

CCM が `topology.kubernetes.io/zone` を埋めると、EBS CSI driver は zone-aware に PVC を bind できる。本クラスタは IRSA + EBS CSI driver を別途構成しているので、CCM が label を埋めることが前提条件として効いてくる。

検証:

```bash
$ kubectl get nodes -L topology.kubernetes.io/zone
NAME                       STATUS   ROLES           AGE   VERSION   ZONE
ap-northeast-2a-master-01  Ready    control-plane   1h    v1.30.x   ap-northeast-2a
ap-northeast-2b-worker-03  Ready    <none>          1h    v1.30.x   ap-northeast-2b
```

PVC を `WaitForFirstConsumer` の StorageClass で作ったとき、pod が schedule される node の zone で EBS volume が作成される。

### 10.5 control-plane を冗長化したときの CCM のリーダー選出

本クラスタは control-plane 1 台構成 (= 単一障害点) だが、将来 HA 化したときに CCM が問題になるか:

- CCM は leader-election (Lease object 経由) に対応。chart の `args` に `--leader-elect=true` (デフォルト true) で複数 Pod の中から 1 つだけ active になる。
- DaemonSet なので control-plane が増えると CCM Pod も増えるが、active leader は常に 1 つ。

HA 化したら次のチェック:

```bash
$ kubectl get lease -n kube-system cloud-controller-manager
NAME                       HOLDER                                            AGE
cloud-controller-manager   aws-cloud-controller-manager-xxxxx_a1b2c3d4-...   1h
```

`HOLDER` が 1 つだけ。

---

## 11. EKS との比較

| 観点 | EKS | 自己管理 kubeadm + CCM (本構成) |
|-----|-----|----------------------------|
| CCM のホスティング | AWS 管理 (見えない) | 自分で DaemonSet として運用 |
| IAM 権限 | EKS Cluster Role / Pod Identity Agent | 自分で role + policy を組む |
| providerID 設定 | EKS Worker bootstrap script が --provider-id を渡す | 自分で kubeadm config に埋め込む (本作業) |
| 等価機能 | 完全に動く | 動く (= 本作業のゴール) |
| 運用負担 | 低 | 中 (IaC で吸収済) |
| コスト | EKS cluster: 0.10 USD/h | 0 (master EC2 のみ) |

EKS は CCM を意識しなくていいが、その代わりに blackbox。kubeadm + CCM は手間がかかるが、流れと依存関係が完全に見える。学習用途・小規模ステージングには後者の透明性が刺さる。

---

## 12. オペレーションランブック

### 12.1 ゼロから構築する手順

```bash
# 0. 前提
#    - ktcloud-cluster-node-role が既に存在し、LBC ポリシーがアタッチ済
#    - aws configure で credential 設定済
#    - terraform/backend.tfvars に S3 bucket 設定済

# 1. SSH キー生成
make ssh-key

# 2. Terraform 初期化
make tf-init

# 3. AWS インフラ + IAM CCM policy 作成
make tf-apply

# 4. Bastion fingerprint 受理
make bastion-accept

# 5. Ansible 疎通確認
make ansible-ping

# 6. クラスタ構築 (bootstrap → control-plane → workers → CCM → LBC → ArgoCD)
make cluster-up

# 7. 検証 (§8 参照)
make verify

# 8. providerID が埋まっていること
kubectl get nodes -o custom-columns=NAME:.metadata.name,PROVIDER_ID:.spec.providerID
```

### 12.2 既存クラスタへの CCM 追加 (本ケースの再現方法)

既に動いているクラスタに後から CCM だけ入れる場合 (= ライブパッチ後の正規化):

```bash
# A. Terraform で IAM policy だけ apply
make tf-apply

# B. kubelet 設定の patch
#    各 node で /var/lib/kubelet/kubeadm-flags.env に下記を追加し kubelet を restart
#      --cloud-provider=external
#      --provider-id=aws:///<az>/<instance-id>
#    (実運用では IaC で再 provision するほうが安全)

# C. controllerManager の patch
#    /etc/kubernetes/manifests/kube-controller-manager.yaml に
#      - --cloud-provider=external
#    を追加 (kubelet が manifest を観測して再起動する)

# D. CCM の Helm install
cd ansible
ansible-playbook -i inventory.ini playbooks/addons.yaml --tags ccm,aws_ccm

# E. uninitialized taint が消えるのを確認 (§8.2)

# F. LBC を再起動 (キャッシュ更新)
kubectl -n kube-system rollout restart deploy aws-load-balancer-controller
```

実運用では C と B は「全 worker を 1 台ずつ drain → reset → rejoin」のローリング手順を取るほうが事故率が低い。本構成は cluster-clear → cluster-up でフルやり直しが受け入れられる規模なので、後者を推奨。

### 12.3 CCM Helm release のアップグレード

```bash
# 現在の release
helm list -n kube-system | grep aws-cloud-controller-manager

# 最新版 chart 確認
helm repo update aws-cloud-controller-manager
helm search repo aws-cloud-controller-manager/aws-cloud-controller-manager --versions | head

# 既存 values を確認
helm get values aws-cloud-controller-manager -n kube-system

# upgrade (chart version 指定)
helm upgrade aws-cloud-controller-manager \
    aws-cloud-controller-manager/aws-cloud-controller-manager \
    -n kube-system \
    --version <new-chart-version> \
    --values <existing-values.yaml>
```

注意: CCM の chart は kubernetes/kubernetes と完全な version 同期ではないが、major Kubernetes バージョンに対応した CCM image を使う必要がある (k8s 1.30 → CCM v1.30.x のような対応)。アップグレード前に [release notes](https://github.com/kubernetes/cloud-provider-aws/releases) を確認。

### 12.4 CCM の撤去 (使わなくなった場合)

仮に CCM を抜く場合、何を巻き戻すか:

1. `helm uninstall aws-cloud-controller-manager -n kube-system`
2. kubelet `--cloud-provider=external` を外す (= 何も指定しない)。kubelet 再起動。
3. kube-controller-manager の `--cloud-provider=external` を外す。
4. 全 node の `node.cloudprovider.kubernetes.io/uninitialized` taint が残っていたら手動 patch で削除。
5. `aws_iam_role_policy.ccm` を Terraform で削除。

このとき providerID は引き続き Node に残るので、LBC は動き続ける (kubelet が起動時に --provider-id を渡している限り)。

---

## 13. 用語集

| 用語 | 説明 |
|-----|-----|
| CCM | Cloud Controller Manager。k8s コアから分離されたクラウド連携 controller。 |
| in-tree cloud-provider | k8s コアに組み込まれた cloud 用ロジック。AWS は 1.25 で削除。 |
| out-of-tree cloud-provider | 別 binary として動く CCM。AWS は cloud-provider-aws。 |
| providerID | Node.spec.providerID。`<provider>://<id>` 形式。 |
| uninitialized taint | `node.cloudprovider.kubernetes.io/uninitialized:NoSchedule`。kubelet が `--cloud-provider=external` で起動したときに自分で付ける。 |
| IMDS | Instance Metadata Service。EC2 上の `169.254.169.254`。 |
| IMDSv2 | token-based の IMDS。`PUT /latest/api/token` → ヘッダで使い回し。 |
| Node IAM Role | EC2 instance profile に紐づいた IAM role。pod は IMDS 経由で credential を取れる。 |
| IRSA | IAM Roles for Service Accounts。pod の SA token を STS に渡して role を引く。 |
| LBC | AWS Load Balancer Controller。ALB/NLB を K8s から自動 provision。 |
| target group | ALB/NLB のバックエンド集合。EC2 instance か IP の集合。 |
| targetType: instance | EC2 instance + NodePort をバックエンドにする LBC のモード。 |
| targetType: ip | Pod IP 直接をバックエンドにするモード。 |
| Calico IP-in-IP | Pod 間通信を IP-in-IP でカプセル化する Calico の encapsulation モード。 |
| kubeadm-config.yaml | kubeadm init/join の設定 YAML。複数 document を `---` で区切る。 |
| InitConfiguration | kubeadm init 用の document。nodeRegistration を持つ。 |
| JoinConfiguration | kubeadm join 用の document。discovery と nodeRegistration を持つ。 |
| ClusterConfiguration | apiserver, kcm 等 cluster-wide な document。 |
| service-linked-role | AWS が特定サービス用に作る IAM role。`iam:CreateServiceLinkedRole` で作成。 |

---

## 14. 参考資料

- Kubernetes 公式: [Cloud Controller Manager Administration](https://kubernetes.io/docs/tasks/administer-cluster/running-cloud-controller/)
- KEP-2392: [Removal of in-tree cloud providers](https://github.com/kubernetes/enhancements/tree/master/keps/sig-cloud-provider/2392-cloud-provider-removal)
- cloud-provider-aws: [Repository](https://github.com/kubernetes/cloud-provider-aws)
- cloud-provider-aws: [Prerequisites & IAM policy](https://cloud-provider-aws.sigs.k8s.io/prerequisites/)
- cloud-provider-aws: [Helm chart values](https://github.com/kubernetes/cloud-provider-aws/tree/master/charts/aws-cloud-controller-manager)
- AWS LBC: [Installation guide](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/deploy/installation/)
- AWS LBC: [Target type docs](https://kubernetes-sigs.github.io/aws-load-balancer-controller/latest/guide/targetgroupbinding/targetgroupbinding/)
- kubeadm: [Configuring kubelet via kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/kubelet-integration/)
- kubeadm: [v1beta3 config reference](https://kubernetes.io/docs/reference/config-api/kubeadm-config.v1beta3/)
- AWS: [Instance Metadata Service v2 documentation](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)

---

## 付録 A: 完成版 kubeadm-config.yaml の例

`/etc/kubernetes/kubeadm-config.yaml` (= テンプレート render 後)。実値は架空。

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  kubeletExtraArgs:
    cloud-provider: external
    provider-id: "aws:///ap-northeast-2a/i-0123456789abcdef0"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: "v1.30.0"
controlPlaneEndpoint: "10.0.2.217:6443"
networking:
  podSubnet: "192.168.0.0/16"
apiServer:
  certSANs:
    - "10.0.2.217"
    - "127.0.0.1"
    - "localhost"
  extraArgs:
    service-account-issuer: "https://kt-cloud-cluster-oidc-123456789012.s3.ap-northeast-2.amazonaws.com"
    api-audiences: "sts.amazonaws.com,https://kubernetes.default.svc.cluster.local"
    service-account-jwks-uri: "https://kt-cloud-cluster-oidc-123456789012.s3.ap-northeast-2.amazonaws.com/openid/v1/jwks"
controllerManager:
  extraArgs:
    cloud-provider: external
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
```

`kubeadm init --config /etc/kubernetes/kubeadm-config.yaml` を実行すると、次が起こる:

1. `InitConfiguration.nodeRegistration.kubeletExtraArgs` が kubelet の起動 flag (`--cloud-provider=external --provider-id=aws:///...`) に変換され、`/var/lib/kubelet/kubeadm-flags.env` に書かれる。
2. `ClusterConfiguration.apiServer.extraArgs` が `/etc/kubernetes/manifests/kube-apiserver.yaml` の command 配列に追加される (IRSA 用 flag)。
3. `ClusterConfiguration.controllerManager.extraArgs` が `/etc/kubernetes/manifests/kube-controller-manager.yaml` の command 配列に `--cloud-provider=external` として追加される。
4. `KubeletConfiguration` 全体が `/var/lib/kubelet/config.yaml` に書かれる。

### kubeadm-flags.env の例 (init 後)

```
KUBELET_KUBEADM_ARGS="--cgroup-driver=systemd --cloud-provider=external --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock --hostname-override=ap-northeast-2a-master-01 --pod-infra-container-image=registry.k8s.io/pause:3.9 --provider-id=aws:///ap-northeast-2a/i-0123456789abcdef0"
```

---

## 付録 B: 完成版 kubeadm-join-config.yaml の例

worker での `/etc/kubernetes/kubeadm-join-config.yaml`:

```yaml
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: JoinConfiguration
discovery:
  bootstrapToken:
    apiServerEndpoint: "10.0.2.217:6443"
    token: "a1b2c3.aaaaaaaaaaaaaaaa"
    caCertHashes:
      - "sha256:1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
nodeRegistration:
  criSocket: "unix:///var/run/containerd/containerd.sock"
  kubeletExtraArgs:
    cloud-provider: external
    provider-id: "aws:///ap-northeast-2a/i-0abcdef0123456789"
```

`kubeadm join --config /etc/kubernetes/kubeadm-join-config.yaml` で:

1. discovery: token + apiserver endpoint で apiserver に到達。caCertHashes で apiserver の CA 真正性を検証 (MITM 防止)。
2. nodeRegistration: kubelet に渡す flag を構成。
3. 結果として `/etc/kubernetes/kubelet.conf` が生成され、kubelet が起動する。

---

## 付録 C: CCM が node に付与する label / annotation 一覧

CCM の node-controller が AWS から取得して node に書き込む情報の一覧。

### Label

| キー | 値の例 | 用途 |
|-----|-------|-----|
| `topology.kubernetes.io/zone` | `ap-northeast-2a` | zone-aware scheduling, EBS topology |
| `topology.kubernetes.io/region` | `ap-northeast-2` | region-aware scheduling |
| `node.kubernetes.io/instance-type` | `t3.medium` | spec ベースの scheduling |
| `failure-domain.beta.kubernetes.io/zone` | `ap-northeast-2a` | レガシー互換 |
| `failure-domain.beta.kubernetes.io/region` | `ap-northeast-2` | レガシー互換 |
| `beta.kubernetes.io/instance-type` | `t3.medium` | レガシー互換 |
| `kubernetes.io/hostname` | `ap-northeast-2a-master-01` | kubelet が登録、CCM は触らない場合あり |

### Annotation

| キー | 値の例 | 用途 |
|-----|-------|-----|
| `node.alpha.kubernetes.io/providerID` | (廃止) | 古い実装。今は `.spec.providerID` を直接使う。 |
| `csi.volume.kubernetes.io/nodeid` | (CSI 起動時) | EBS CSI が自身で書く。CCM は関与しない。 |

### Status.Addresses

CCM は kubelet が登録した addresses を AWS から取った値で上書き/補完する。

```yaml
status:
  addresses:
    - type: InternalIP
      address: 10.0.2.119
    - type: Hostname
      address: ap-northeast-2a-worker-01    # OS hostname
    - type: InternalDNS
      address: ip-10-0-2-119.ap-northeast-2.compute.internal   # AWS private DNS
```

---

## 付録 D: CCM IAM ポリシー全文 (JSON)

`aws iam get-role-policy --role-name ktcloud-cluster-node-role --policy-name ktcloud-cluster-ccm-policy --query PolicyDocument --output json` の出力相当。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "CCMRead",
      "Effect": "Allow",
      "Action": [
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
        "ec2:DescribeVpcs"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CCMTagAndModify",
      "Effect": "Allow",
      "Action": [
        "ec2:CreateTags",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifyVolume",
        "ec2:AttachVolume",
        "ec2:DetachVolume"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CCMServiceLinkedRole",
      "Effect": "Allow",
      "Action": "iam:CreateServiceLinkedRole",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "iam:AWSServiceName": [
            "elasticloadbalancing.amazonaws.com",
            "autoscaling.amazonaws.com"
          ]
        }
      }
    },
    {
      "Sid": "CCMKMSDescribe",
      "Effect": "Allow",
      "Action": "kms:DescribeKey",
      "Resource": "*"
    }
  ]
}
```

---

## 付録 E: 各 controller の在野ログサンプル

### CCM Pod 起動時の正常ログ (抜粋)

```
I0517 03:55:01.123456       1 controllermanager.go:160] Version: v1.30.0
I0517 03:55:01.234567       1 controllermanager.go:251] Starting "cloud-node"
I0517 03:55:01.345678       1 node_controller.go:165] Sending events to api server.
I0517 03:55:01.456789       1 controllermanager.go:251] Starting "cloud-node-lifecycle"
I0517 03:55:01.567890       1 node_lifecycle_controller.go:113] Sending events to api server.
I0517 03:55:01.678901       1 controllermanager.go:251] Starting "service"
I0517 03:55:01.789012       1 controller.go:227] Starting service controller
I0517 03:55:01.890123       1 controllermanager.go:251] Starting "route"  # route controller は --configure-cloud-routes=false なら起動しない、もしくは即終了
I0517 03:55:01.901234       1 leaderelection.go:248] attempting to acquire leader lease kube-system/cloud-controller-manager...
I0517 03:55:02.012345       1 leaderelection.go:258] successfully acquired lease kube-system/cloud-controller-manager
I0517 03:55:02.123456       1 node_controller.go:419] Initializing node ap-northeast-2a-master-01 with cloud provider
I0517 03:55:02.234567       1 node_controller.go:507] Successfully initialized node ap-northeast-2a-master-01 with cloud provider
I0517 03:55:02.345678       1 node_controller.go:419] Initializing node ap-northeast-2a-worker-01 with cloud provider
I0517 03:55:02.456789       1 node_controller.go:507] Successfully initialized node ap-northeast-2a-worker-01 with cloud provider
...
```

`Successfully initialized node X with cloud provider` が CCM が node から uninitialized taint を消すフェーズ。これが 6 ノード ぶん出れば成功。

### AWS LBC 起動時の正常ログ (抜粋)

```
{"level":"info","ts":"2026-05-17T03:55:30Z","msg":"version","GitVersion":"v2.7.x","GitCommit":"...","BuildDate":"..."}
{"level":"info","ts":"2026-05-17T03:55:30Z","msg":"starting podInfo","podName":"aws-load-balancer-controller-xxx"}
{"level":"info","ts":"2026-05-17T03:55:31Z","msg":"setup","controller":"targetGroupBinding"}
{"level":"info","ts":"2026-05-17T03:55:31Z","msg":"setup","controller":"service"}
{"level":"info","ts":"2026-05-17T03:55:31Z","msg":"setup","controller":"ingress"}
{"level":"info","ts":"2026-05-17T03:55:32Z","msg":"Starting Controller","controller":"targetGroupBinding"}
{"level":"info","ts":"2026-05-17T03:55:35Z","msg":"successful reconcile","controller":"targetGroupBinding","targetGroup":"k8s-traefik-traefik-df452a5320","targetCount":5}
```

`targetCount: 5` が見えれば LBC は target group へ EC2 instance を登録できている。

### kubelet --cloud-provider=external の起動ログ (抜粋)

```
I0517 03:54:30.123456    1234 kubelet.go:392] "Adding node label from cloud provider" labelKey="..."
I0517 03:54:30.234567    1234 kubelet_node_status.go:73] "Attempting to register node" node="ap-northeast-2a-worker-01"
I0517 03:54:30.345678    1234 kubelet_node_status.go:76] "Successfully registered node" node="ap-northeast-2a-worker-01"
I0517 03:54:30.456789    1234 kubelet.go:2331] "SyncLoop ADD" source="api" pods=["..."]
```

kubelet 自身が AWS API を叩かないため、in-tree モード時にあった `aws_cloud.go` 系のログは出ない。

---

## 付録 F: ライブパッチ作業の生ログ

復旧時に取った作業ログを匿名化して保存。再発時に同じ手順を取るための参考。

```bash
# 1. 現状把握
$ kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
ap-northeast-2a-master-01	
ap-northeast-2a-worker-01	
ap-northeast-2a-worker-02	
ap-northeast-2b-worker-01	
ap-northeast-2b-worker-02	
ap-northeast-2b-worker-03	

# 2. EC2 console で各 node の InstanceID と AZ を確認
$ aws ec2 describe-instances \
    --filters "Name=tag:kubernetes.io/cluster/kt-cloud-cluster,Values=owned" \
    --query 'Reservations[].Instances[].[Tags[?Key==`Name`]|[0].Value, Placement.AvailabilityZone, InstanceId]' \
    --output table
-----------------------------------------------------------------------------
|                          DescribeInstances                                 |
+----------------------------+-------------------+--------------------------+
|  ap-northeast-2a-master-01 |  ap-northeast-2a  |  i-0aaaaaaaaaaaaaaaa     |
|  ap-northeast-2a-worker-01 |  ap-northeast-2a  |  i-0bbbbbbbbbbbbbbbb     |
|  ap-northeast-2a-worker-02 |  ap-northeast-2a  |  i-0cccccccccccccccc     |
|  ap-northeast-2b-worker-01 |  ap-northeast-2b  |  i-0dddddddddddddddd     |
|  ap-northeast-2b-worker-02 |  ap-northeast-2b  |  i-0eeeeeeeeeeeeeeee     |
|  ap-northeast-2b-worker-03 |  ap-northeast-2b  |  i-0ffffffffffffffff     |
+----------------------------+-------------------+--------------------------+

# 3. providerID を patch
$ for row in \
    "ap-northeast-2a-master-01:ap-northeast-2a:i-0aaaaaaaaaaaaaaaa" \
    "ap-northeast-2a-worker-01:ap-northeast-2a:i-0bbbbbbbbbbbbbbbb" \
    "ap-northeast-2a-worker-02:ap-northeast-2a:i-0cccccccccccccccc" \
    "ap-northeast-2b-worker-01:ap-northeast-2b:i-0dddddddddddddddd" \
    "ap-northeast-2b-worker-02:ap-northeast-2b:i-0eeeeeeeeeeeeeeee" \
    "ap-northeast-2b-worker-03:ap-northeast-2b:i-0ffffffffffffffff" ; do
  IFS=: read -r node az id <<<"$row"
  kubectl patch node "$node" \
    -p "{\"spec\":{\"providerID\":\"aws:///$az/$id\"}}"
done
node/ap-northeast-2a-master-01 patched
node/ap-northeast-2a-worker-01 patched
node/ap-northeast-2a-worker-02 patched
node/ap-northeast-2b-worker-01 patched
node/ap-northeast-2b-worker-02 patched
node/ap-northeast-2b-worker-03 patched

# 4. 確認
$ kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.providerID}{"\n"}{end}'
ap-northeast-2a-master-01	aws:///ap-northeast-2a/i-0aaaaaaaaaaaaaaaa
ap-northeast-2a-worker-01	aws:///ap-northeast-2a/i-0bbbbbbbbbbbbbbbb
ap-northeast-2a-worker-02	aws:///ap-northeast-2a/i-0cccccccccccccccc
ap-northeast-2b-worker-01	aws:///ap-northeast-2b/i-0dddddddddddddddd
ap-northeast-2b-worker-02	aws:///ap-northeast-2b/i-0eeeeeeeeeeeeeeee
ap-northeast-2b-worker-03	aws:///ap-northeast-2b/i-0ffffffffffffffff

# 5. LBC が target group に登録するのを待ってログ確認
$ kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=20 -f
{"level":"info","ts":"2026-05-17T04:01:14Z","msg":"successful reconcile","reconcileID":"...","targetGroup":"k8s-traefik-traefik-df452a5320","targetCount":5}
{"level":"info","ts":"2026-05-17T04:01:14Z","msg":"adding targets","targetGroup":"k8s-traefik-traefik-df452a5320","targets":[{"instanceID":"i-0bbbbbbbbbbbbbbbb","port":32218},{"instanceID":"i-0cccccccccccccccc","port":32218},...]}

# 6. SG rule 自動追加の確認
$ aws ec2 describe-security-groups \
    --group-ids sg-XXX \
    --query 'SecurityGroups[0].IpPermissions[?ToPort==`32218`]' --output json
[
  {
    "FromPort": 32218,
    "IpProtocol": "tcp",
    "ToPort": 32218,
    "UserIdGroupPairs": [
      {"GroupId": "sg-NLB-backend", "UserId": "123..."}
    ]
  }
]

# 7. 外部疎通
$ curl -sI https://service.example.com/ | head -1
HTTP/2 200
```

ここから IaC 修正 (本作業) に進み、次回 `make cluster-clear && make cluster-up` で同じ状態が自動再現する状態に持ち込んだ。

---

以上で本レポートを終わる。要点を再掲する。

- LBC の `providerID is not specified` は、in-tree cloud-provider を喋らない kubeadm 構成での "AWS が見えてない" シグナル。
- 正攻法は kubelet `--cloud-provider=external` + `--provider-id=aws:///<az>/<id>` を kubeadm の Init/JoinConfiguration で固定し、out-of-tree CCM を control-plane に常駐させること。
- IAM は `ktcloud-cluster-node-role` への inline policy として Terraform で管理。
- Ansible 側は kubeadm_init と kubeadm_join_worker に IMDSv2 取得を足し、aws_ccm role を addons playbook の前段に置く 2 段構え。
- 結果として、providerID は kubelet 登録時点で埋まり、LBC は CCM の到着を待たずに target group へ即時登録できる。CCM は taint 除去 + zone/region label 付与で補助的に働く。
