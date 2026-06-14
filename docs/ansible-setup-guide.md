# Ansible 構築手順書

制御ホスト **192.168.30.50** から Ansible で controller / worker を構築し、
Clabernetes + SR Linux ラボをデプロイするまでの手順。

---

## 0. 前提・全体像

| 役割 | IP | 構築後の状態 |
|------|-----|------|
| 制御ホスト（Ansible 実行元） | 192.168.30.50 | venv に ansible を導入 |
| controller | 192.168.30.60 | control-plane / kubectl / helm |
| worker1 | 192.168.30.61 | worker |
| worker2 | 192.168.30.62 | worker |

- SSH ユーザー / パスワードは `inventory/group_vars/all.yml` で設定（`ansible_user` は任意に変更可、パスワードは `****` でマスク）。鍵認証は配布済み前提（未配布なら後述）。
- Ansible は **エージェントレス**。制御ホストにのみインストールし、各ノードへは SSH 経由でモジュールを送り込んで実行する。
- 構築フロー: **Phase 1（OS/ランタイム）→ 2（init）→ 3（join）→ 4（Calico）→ 5（MetalLB）→ 6（Clabernetes）→ 7（ラボ）**。

```
[制御ホスト .50]  ── SSH ──▶ controller / worker1 / worker2
   .venv/bin/ansible-playbook        各ノードで apt / kubeadm / kubectl ... を実行
```

---

## 1. 制御ホストへ Ansible を導入（Python venv + pip）

```bash
cd <リポジトリのルート>

# venv 用パッケージ（無ければ）
echo '****' | sudo -S apt-get update -q
echo '****' | sudo -S apt-get install -y python3.12-venv python3-pip

# venv 作成 & Ansible 一式
python3 -m venv .venv
.venv/bin/pip install --upgrade pip wheel
.venv/bin/pip install ansible kubernetes jsonpatch
```

> pip 版 `ansible` には `kubernetes.core` / `community.general` / `ansible.posix` の各 collection が同梱される。
> `kubernetes` / `jsonpatch`（Python ライブラリ）は制御ホスト側では必須ではないが、入れておくと検証に使える。

### バージョン確認

```bash
.venv/bin/ansible --version            # => ansible [core 2.21.x]
.venv/bin/ansible-galaxy collection list | grep -E "kubernetes.core|community.general|ansible.posix"
# => kubernetes.core 6.x / community.general 13.x / ansible.posix 2.x
```

### （任意）collection を明示導入

pip 同梱で足りるが、再現性のため `requirements.yml` から導入することもできる。

```bash
cd ansible
../.venv/bin/ansible-galaxy collection install -r requirements.yml
```

---

## 2. SSH 鍵の配布（未配布の場合のみ）

鍵認証が未設定なら、先に配布してパスワードレス化する。

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N "" -f ~/.ssh/id_ed25519
for IP in 192.168.30.60 192.168.30.61 192.168.30.62; do
  sshpass -p '****' ssh-copy-id -o StrictHostKeyChecking=no <user>@${IP}
done
```

> 鍵を配らない場合は `inventory/group_vars/all.yml` の `ansible_ssh_pass` を有効化するか、
> `ansible-playbook ... --ask-pass` を使う。

---

## 3. インベントリと変数の確認

ディレクトリ構成:

```
ansible/
├── ansible.cfg                     # 接続・出力設定
├── requirements.yml                # collection 一覧
├── inventory/
│   ├── hosts.yml                   # controller / workers / k8s_cluster
│   └── group_vars/all.yml          # 認証・バージョン・CIDR・接続モード
└── playbooks/
    ├── site.yml                    # Phase 1〜6 一括
    ├── 01-node-prep.yml 〜 06-clabernetes.yml
    ├── 07-deploy-lab.yml           # ラボ構築
    └── reset.yml                   # 0 ベース初期化
```

主要変数（`inventory/group_vars/all.yml`、`-e key=value` で上書き可）:

| 変数 | 既定値 | 意味 |
|------|--------|------|
| `ansible_user` / `ansible_become_pass` | `<user>` / `****` | SSH / sudo 認証（任意に変更可・パスワードはマスク）|
| `k8s_version` / `k8s_minor` | 1.36.1 / v1.36 | Kubernetes |
| `containerd_version` | 2.3.1 | containerd |
| `c9s_version` | 0.5.0 | Clabernetes / clabverter |
| `pod_cidr` / `service_cidr` | 10.244.0.0/16 / 10.96.0.0/12 | CIDR |
| `metallb_range` | 192.168.30.200-192.168.30.250 | LB プール |
| `connectivity` | slurpeeth | ラボ接続モード（slurpeeth/vxlan）|
| `kubeconfig` | /home/`<user>`/.kube/config | controller の kubeconfig（`ansible_user` から導出）|
| `k8s_venv` / `k8s_python` | /home/`<user>`/.k8s-ansible-venv | kubernetes.core 用 Python（`ansible_user` から導出）|

### 疎通確認

```bash
cd ansible
../.venv/bin/ansible all -m ping       # 全ノードが SUCCESS / pong
../.venv/bin/ansible controller -b -m command -a id   # become(root) 動作確認
```

---

## 4. クラスタ + Clabernetes 構築（Phase 1〜6）

```bash
cd ansible
../.venv/bin/ansible-playbook playbooks/site.yml
```

`site.yml` は次を順に `import_playbook` する。

1. **01-node-prep**（全ノード）: カーネルモジュール / sysctl / swap off / containerd v2.3.1 / runc / CNI plugins / kubeadm・kubelet・kubectl v1.36.1
2. **02-control-plane**（controller）: `kubeadm init` + kubeconfig 配置（TTRPC 失敗時は reset→restart→再 init を rescue）
3. **03-workers**（workers）: `kubeadm token create` で join コマンド生成 → 各 worker で join
4. **04-calico**（controller/workers）: controller 用 Python venv 作成 → Tigera Operator → worker containerd 再起動 → Installation CR（Pod CIDR 明示）→ 全ノード Ready 待ち
5. **05-metallb**（controller）: MetalLB native → IPAddressPool / L2Advertisement
6. **06-clabernetes**（controller）: helm バイナリ導入 → `kubernetes.core.helm` で manager 導入（`wait:false`）→ rollout 確認

完了確認:

```bash
../.venv/bin/ansible controller -b=false -m command -a "kubectl get nodes" \
  -e "ansible_command_timeout=30"
# => controller / worker1 / worker2 が Ready
```

> 個別 Phase だけ流したい場合は `ansible-playbook playbooks/04-calico.yml` のように単体実行も可能（冪等）。

---

## 5. ラボ構築（Phase 7）

```bash
cd ansible
# 既定 slurpeeth（推奨）
../.venv/bin/ansible-playbook playbooks/07-deploy-lab.yml
# vxlan で試す場合
../.venv/bin/ansible-playbook playbooks/07-deploy-lab.yml -e connectivity=vxlan
```

処理内容:
1. `git` でラボ（srlinux-vlan-handling-lab）取得
2. `clabverter`（docker）で manifests 生成 → `/tmp/manifests.yml`
3. slurpeeth の場合は `lineinfile` で `spec.connectivity: slurpeeth` を注入
4. `kubectl apply` で適用

> SR Linux はブートに 1〜3 分かかる。適用直後は Pod が `Running` でも内部が起動途中。
> 動作確認は **[Nornir 構築手順](./nornir-setup-guide.md)** の `verify_lab.py` で行う。

---

## 6. 0 ベース初期化（破壊的）

```bash
cd ansible
../.venv/bin/ansible-playbook playbooks/reset.yml -e reset_confirm=yes
```

`-e reset_confirm=yes` が無いと `assert` で停止する（誤実行防止）。
全ノードで `kubeadm reset` → 設定/状態ディレクトリ削除 → CNI インターフェース除去 → containerd 再起動。
再構築は `site.yml` から（containerd / k8s パッケージは残るため高速）。

---

## 7. つまずきポイント（実機検証で対処済み）

| 症状 | 対処 |
|------|------|
| `Missing sudo password` | `group_vars` は **インベントリ隣接**（`inventory/group_vars/`）に置く。離れた場所だと読まれない |
| `kubectl` が `localhost:8080 connection refused` | kubectl タスクの play に `environment: {KUBECONFIG: "{{ kubeconfig }}"}` を付与（非対話 SSH の `$HOME` 依存回避）|
| helm が `clabernetes-config not ready` で timeout | `wait:false`。`clabernetes-config` ConfigMap は manager 起動後に生成されるため。rollout は別タスクで確認 |
| Calico `installations CRD not found` | `until` で CRD 出現を待ってから `kubectl wait` / Installation 適用 |
| `apt` ロック競合（unattended-upgrades） | apt タスクに `lock_timeout: 300` |
| `community.general.yaml` callback 削除エラー | `ansible.cfg` で `stdout_callback=default` + `result_format=yaml` |

---

## 関連ドキュメント
- [Ansible Playbook 解説](./ansible-playbook-explained.md)

