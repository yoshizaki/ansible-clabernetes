# ansible-clabernetes

Ansible で **Kubernetes クラスタ + Clabernetes** を構築し、Nokia SR Linux のネットワークラボ
（[srlinux-vlan-handling-lab](https://github.com/srl-labs/srlinux-vlan-handling-lab)）を
Kubernetes 上にデプロイするための Playbook 一式です。

制御ホスト（Ansible 実行元）から SSH 経由でエージェントレスに、control-plane 1 台 + worker 2 台を
セットアップします。

## 構成

| 役割 | 既定 IP | 構築後の状態 |
|------|---------|--------------|
| 制御ホスト（Ansible 実行元） | 192.168.30.50 | venv に ansible を導入 |
| controller | 192.168.30.60 | control-plane / kubectl / helm |
| worker1 | 192.168.30.61 | worker |
| worker2 | 192.168.30.62 | worker |

構築フロー（Phase）: **1 OS/ランタイム → 2 init → 3 join → 4 Calico → 5 MetalLB → 6 Clabernetes → 7 ラボ**

| バージョン | 既定値 |
|---|---|
| Kubernetes | 1.36.1 |
| containerd | 2.3.1 |
| Clabernetes / clabverter | 0.5.0 |

## ディレクトリ構成

```
.
├── ansible.cfg                  # 接続・出力設定（inventory パス等）
├── requirements.yml             # 追加 collection（再現用）
├── inventory/
│   ├── hosts.yml                # controller / workers / k8s_cluster
│   └── group_vars/all.yml       # 認証・バージョン・CIDR・接続モード
├── playbooks/
│   ├── site.yml                 # Phase 1〜6 を import_playbook で一括
│   ├── 01-node-prep.yml         # Phase 1: OS / ランタイム
│   ├── 02-control-plane.yml     # Phase 2: kubeadm init
│   ├── 03-workers.yml           # Phase 3: kubeadm join
│   ├── 04-calico.yml            # Phase 4: CNI (Calico)
│   ├── 05-metallb.yml           # Phase 5: LoadBalancer (MetalLB)
│   ├── 06-clabernetes.yml       # Phase 6: Clabernetes manager
│   ├── 07-deploy-lab.yml        # Phase 7: SR Linux ラボ
│   ├── 08-verify-lab.yml        # Phase 8: ラボ動作確認（Ansible のみ）
│   └── reset.yml                # 0 ベース初期化（破壊的）
├── scripts/
│   └── set-credentials.sh       # 認証情報・ホストアドレスの一括変換（apply / mask）
└── docs/
    ├── ansible-setup-guide.md       # 構築手順（詳細）
    └── ansible-playbook-explained.md # Playbook 設計・解説
```

## 前提

- 制御ホストに Python 3.12 と venv が使えること。
- controller / worker への SSH 鍵が配布済み（未配布なら下記参照）。
- 各ノードは sudo 可能なユーザーを持つこと。

## セットアップ

### 1. Ansible 環境（制御ホスト）

```bash
python3 -m venv .venv
.venv/bin/pip install --upgrade pip wheel
.venv/bin/pip install ansible kubernetes jsonpatch

# pip 版 ansible には collection が同梱されるが、再現性のため明示導入も可
.venv/bin/ansible-galaxy collection install -r requirements.yml
```

> pip 版 `ansible` には `kubernetes.core` / `community.general` / `ansible.posix` が同梱されます。

### 2. インベントリ / 変数の調整

`inventory/hosts.yml`（ホスト IP）と `inventory/group_vars/all.yml`（認証・バージョン・CIDR）を
自環境に合わせて編集します。主要変数は `-e key=value` でも上書き可能です。

認証情報とホストアドレスは `scripts/set-credentials.sh` で一括投入できます。
公開リポジトリにはマスク値（`user=admin` / `password="****"`）を残し、**実行直前に実値を流し込み、
push 前に `mask` で戻す**運用を想定しています。

```bash
# 実値を流し込む（ホスト IP の上書きは任意）
scripts/set-credentials.sh apply -u tomo -p password \
    [--controller 192.168.30.60 --worker1 192.168.30.61 --worker2 192.168.30.62]

# 現在値の確認
scripts/set-credentials.sh show

# push 前にパスワードを **** に戻す
scripts/set-credentials.sh mask
```

> **認証情報について**
> - ユーザー名は `ansible_user`（`inventory/group_vars/all.yml`）の **1 箇所**で変更でき、
>   ホームディレクトリ依存のパス（`kubeconfig` / `k8s_venv` / `lab_dir` 等）もこの値から自動導出されます。
> - パスワードは公開用に `****` でマスクしてあります。**実行前に実際の値へ置き換える**か、
>   `--ask-become-pass`（鍵認証 + sudo パスワードを対話入力）を使ってください。
> - 実運用では [ansible-vault](https://docs.ansible.com/ansible/latest/vault_guide/index.html) での暗号化を推奨します。

### 3. SSH 鍵の配布（未配布の場合のみ）

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for IP in 192.168.30.60 192.168.30.61 192.168.30.62; do
  ssh-copy-id -o StrictHostKeyChecking=no <user>@${IP}
done
```

## 実行

`ansible.cfg` で inventory を指定済みのため、**リポジトリ直下**から実行します。

```bash
VENV=.venv/bin

# 疎通確認
$VENV/ansible all -m ping

# A. セットアップ一括（Phase 1〜6 = ラボ構築直前まで）
$VENV/ansible-playbook playbooks/site.yml

# B. ラボ構築（既定 slurpeeth。vxlan は -e connectivity=vxlan）
$VENV/ansible-playbook playbooks/07-deploy-lab.yml
$VENV/ansible-playbook playbooks/07-deploy-lab.yml -e connectivity=vxlan

# C. ラボ動作確認（Ansible のみ。LLDP / bridge MAC / client 間 ping）
$VENV/ansible-playbook playbooks/08-verify-lab.yml

# D. 0 ベース初期化（破壊的・要確認フラグ）
$VENV/ansible-playbook playbooks/reset.yml -e reset_confirm=yes
```

個別 Phase だけ流す場合は `ansible-playbook playbooks/04-calico.yml` のように単体実行も可能（冪等）です。

> SR Linux はブートに 1〜3 分かかります。Pod が `Running` でも内部は起動途中のことがあります。
> `08-verify-lab.yml` は NOS が応答するまで自動でリトライしてから確認を行います。

> **動作確認（`08-verify-lab.yml`）について**
> Clabernetes ではノードが launcher Pod 内の docker コンテナとして動くため、
> `kubectl exec <pod> -- docker exec <node> ...` 経由で SR Linux の `sr_cli` と
> クライアントの `ping` を実行します（**追加コレクション不要**・既存の kubectl 経路のみ）。
> untagged（10.1.0.x）を `assert` で合否判定し、VLAN10/11/QinQ は参考表示します
> （SRL 側に該当 VLAN 設定があれば OK、無ければ NG。いずれも play は止めません）。
> 構築済みラボでの実行結果は untagged / VLAN10 / VLAN11 / QinQ いずれも OK を確認済み。

## Playbook 一覧

| ファイル | Phase | 主なモジュール |
|---|---|---|
| `01-node-prep.yml` | 1 | modprobe / sysctl / apt / get_url / unarchive / systemd_service / dpkg_selections |
| `02-control-plane.yml` | 2 | command(kubeadm) + block/rescue（TTRPC リトライ） |
| `03-workers.yml` | 3 | command(kubeadm join) |
| `04-calico.yml` | 4 | pip(venv) / command(kubectl) / kubernetes.core.k8s |
| `05-metallb.yml` | 5 | command(kubectl) / kubernetes.core.k8s |
| `06-clabernetes.yml` | 6 | unarchive(helm) / kubernetes.core.helm |
| `07-deploy-lab.yml` | 7 | git / command(clabverter) / lineinfile(slurpeeth 注入) / command(kubectl) |
| `08-verify-lab.yml` | 8 | command(kubectl exec → docker exec) / assert（LLDP / bridge MAC / ping） |
| `site.yml` | 1-6 | import_playbook |
| `reset.yml` | - | command(kubeadm reset) / file |

> `kubernetes.core` モジュールは controller 上の専用 venv（`04-calico.yml` で自動作成）の Python で
> 実行します（apt 等は system python のまま）。

## ドキュメント

- [構築手順（詳細）](docs/ansible-setup-guide.md)
- [Playbook 設計・解説](docs/ansible-playbook-explained.md)
