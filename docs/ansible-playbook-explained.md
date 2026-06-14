# Ansible Playbook 解説

`ansible/` 配下の Playbook を、設計意図・使用モジュール・要点ごとに解説する。
手順は [Ansible 構築手順](./ansible-setup-guide.md) を参照。

---

## 全体設計

- **エージェントレス**: 制御ホストの venv に ansible のみ導入。各ノードへ SSH でモジュールを送って実行。
- **Phase 分割 + `import_playbook`**: shell 版（`build/`）と同じ Phase 1〜7 を 1 ファイル 1 Phase に対応させ、`site.yml` で束ねる。個別実行も冪等。
- **モジュール優先 + 要所で command**: OS 層は専用モジュール（apt / modprobe / sysctl / get_url / unarchive / systemd_service / dpkg_selections）、Kubernetes 層は `kubernetes.core`（k8s / helm）。kubeadm と「リモート URL の kubectl apply」だけは `command`（モジュールでは表現しにくい・URL 取得が絡むため）。

```
site.yml
 ├─ 01-node-prep.yml      hosts: k8s_cluster   （全ノード, become）
 ├─ 02-control-plane.yml  hosts: controller
 ├─ 03-workers.yml        hosts: controller→workers→controller
 ├─ 04-calico.yml         hosts: controller / workers（複数 play）
 ├─ 05-metallb.yml        hosts: controller
 └─ 06-clabernetes.yml    hosts: controller
07-deploy-lab.yml         hosts: controller   （ラボ。site.yml とは別実行）
reset.yml                 hosts: k8s_cluster  （破壊的・ガード付き）
```

---

## ansible.cfg / inventory / group_vars

### ansible.cfg
```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
stdout_callback = default          # community.general.yaml は 12+ で削除済み
result_format = yaml               # 出力を YAML 整形（旧 yaml callback の代替）
callbacks_enabled = ansible.posix.profile_tasks   # タスク所要時間表示
deprecation_warnings = False
[ssh_connection]
pipelining = True                  # SSH 往復を減らし高速化
```

### inventory/hosts.yml
`controller` / `workers` グループと、両者をまとめた `k8s_cluster` を定義。
Phase 1 と reset は `k8s_cluster`、それ以外は `controller`（一部 `workers`）を対象にする。

### inventory/group_vars/all.yml（**配置が重要**）
認証・バージョン・CIDR・接続モードを集約。
**`group_vars` はインベントリ隣接（`inventory/group_vars/`）に置く**こと。
プロジェクト直下など離れた場所だと読み込まれず `ansible_become_pass` 未定義 →
`Missing sudo password` になる。

---

## 01-node-prep.yml — Phase 1（OS / ランタイム）

`hosts: k8s_cluster`, `become: true`。全ノード共通の下ごしらえ。

| ブロック | モジュール | 要点 |
|---|---|---|
| カーネルモジュール | `community.general.modprobe` + `copy` | overlay / br_netfilter / **vxlan** を即ロード + `/etc/modules-load.d` で永続化 |
| sysctl | `ansible.posix.sysctl` | bridge-nf-call-iptables 等を `/etc/sysctl.d/k8s.conf` に書き reload |
| swap | `command: swapoff -a` + `replace`（fstab）| swap 無効化と fstab コメントアウト |
| 依存パッケージ | `apt` (`lock_timeout: 300`) | jq / curl / gpg 等。**lock_timeout で unattended-upgrades とのロック競合を回避** |
| containerd | `unarchive`(creates) / `get_url` | v2.3.1 バイナリ展開 + systemd unit |
| runc / CNI | `uri`→`get_url` / `unarchive` | GitHub API で最新 tag 取得（`delegate_to: localhost, run_once`）→ ダウンロード |
| containerd 設定 | `command: containerd config default` → `copy`(`regex_replace`) | `SystemdCgroup = true` に書き換えて配置。変更時は handler で restart |
| containerd 起動 | `systemd_service` | enable + start（TTRPC 予防の restart は handler）|
| k8s リポジトリ | `get_url` / `command: gpg --dearmor`(creates) / `apt_repository` | キーリング + apt source |
| kube パッケージ | `dpkg_selections`(unhold) → `apt`(`allow_change_held_packages`) → `dpkg_selections`(hold) | v1.36.1 ピン留め + hold |

**ポイント**
- `creates:` / `unarchive` の冪等性で再実行が安全・高速。
- 最新 tag 取得の `uri` は `delegate_to: localhost` + `run_once: true` で 1 回だけ叩く。
- `notify: restart containerd` ハンドラで設定変更時のみ再起動。

---

## 02-control-plane.yml — Phase 2（init）

`hosts: controller`, `become: true`, `environment: {KUBECONFIG: ...}`。

```yaml
- block:
    - command: kubeadm init ... ( creates: /etc/kubernetes/admin.conf )
  rescue:
    - shell: kubeadm reset -f; systemctl restart containerd; sleep 8   # TTRPC 対策
    - command: kubeadm init ...
```

- `creates:` で **冪等**（既に init 済みならスキップ）。
- `block/rescue` で **TTRPC shim 失敗時に自動リカバリ**（reset→restart→再 init）。
- kubeconfig 配置: `file`(~/.kube) → `copy`(remote_src, admin.conf → ~/.kube/config, owner=`{{ ansible_user }}`)。
- **play に `environment: KUBECONFIG`** を付けるのが要。kubectl タスク（become:false）が
  非対話 SSH の `$HOME` 解決に依存して `localhost:8080` を見るのを防ぐ。

---

## 03-workers.yml — Phase 3（join）

3 つの play で構成。

1. `hosts: controller`: `command: kubeadm token create --print-join-command` → `set_fact`。
2. `hosts: workers`: containerd を restart（TTRPC 予防）→ `command: {{ hostvars['controller'].kube_join_command }} --cri-socket=...`（`creates: /etc/kubernetes/kubelet.conf` で冪等）。
3. `hosts: controller`: `kubectl get nodes` で確認。

- join コマンドはトークンを**動的生成**して `hostvars` 経由で worker に渡す（固定値を埋め込まない）。

---

## 04-calico.yml — Phase 4（CNI）

4 つの play。Pod CIDR を `10.244.0.0/16` に明示するため Operator + Installation 方式。

| play | 内容 | 使用モジュール |
|---|---|---|
| 4a prepare | controller に **kubernetes.core 用 Python venv** を作成 | `apt`(python3-venv) / `command`(venv) / `pip`(virtualenv: kubernetes, PyYAML) |
| 4b operator | Tigera Operator 適用 + rollout 待ち | `uri`(最新 tag) / `command: kubectl apply --server-side --force-conflicts` |
| 4c worker restart | Installation 前に worker containerd を restart（TTRPC 予防）| `systemd_service` |
| 4d installation | CRD 出現待ち → Installation/APIServer 適用 → 全ノード Ready 待ち | `command`(`until`) / **`kubernetes.core.k8s`** |

**ポイント**
- `kubernetes.core.k8s` は controller の **専用 venv の Python** で実行（`vars: ansible_python_interpreter: "{{ k8s_python }}"`）。
  apt 等は system python のままにし、k8s モジュールのときだけ切り替える（venv に python3-apt が無いため全体切替は不可）。
- **CRD discovery 競合**対策: `kubectl get crd installations.operator.tigera.io` を `until` でリトライしてから `kubectl wait`。
- Operator 再適用での field manager 競合を避けるため `apply --server-side --force-conflicts`。

---

## 05-metallb.yml — Phase 5（LoadBalancer）

`hosts: controller`。

1. `uri` で最新 tag → `command: kubectl apply -f <metallb-native.yaml>`。
2. `command: kubectl wait`（speaker/controller Ready）。
3. **`kubernetes.core.k8s`** で `IPAddressPool`(192.168.30.200-250) と `L2Advertisement` を適用（venv Python）。

上流マニフェスト（リモート URL）は `command kubectl apply`、自前 CR はモジュール、という住み分け。

---

## 06-clabernetes.yml — Phase 6（manager）

`hosts: controller`。

```yaml
- unarchive: helm バイナリ（uri で最新 tag → get.helm.sh）   # /usr/local/bin/helm
- shell: 旧 pending-install リリースを掃除（冪等性）
- kubernetes.core.helm:                                      # venv Python
    chart_ref: oci://ghcr.io/srl-labs/clabernetes/clabernetes
    chart_version: "0.5.0"
    wait: false                                              # ★
- command: kubectl -n c9s rollout status deploy/clabernetes-manager
```

**ポイント**
- `wait: false` が肝。`clabernetes-config` ConfigMap は **manager 起動後に実行時生成**されるため、
  helm `--wait` がそれを待ち続けて `context deadline exceeded` になる。`wait:false` にして
  rollout は後続の `kubectl rollout status` で別途確認する。
- 失敗で `pending-install` のまま止まった旧リリースを前段の `shell` で `helm uninstall` して再実行可能に。

---

## 07-deploy-lab.yml — Phase 7（ラボ）

`hosts: controller`。接続モードは `connectivity`（既定 slurpeeth、`-e connectivity=vxlan` で切替）。

```yaml
- git: ラボ clone
- command: id -u                       # clabverter コンテナの --user 用
- command:                             # ★ shell リダイレクトを避け argv で実行
    argv: [docker, run, --user, "{{ uid }}", -v, "{{ lab_dir }}:/clabernetes/work",
           --rm, "ghcr.io/.../clabverter:0.5.0", --stdout, --naming, non-prefixed]
  register: clabverter_out
- copy: content="{{ clabverter_out.stdout }}" dest=/tmp/manifests.yml   # stdout のみ書く
- lineinfile:                          # slurpeeth のときだけ注入
    insertafter: '^spec:$'
    line: '  connectivity: slurpeeth'
  when: connectivity == 'slurpeeth'
- command: kubectl apply -f /tmp/manifests.yml
```

**ポイント**
- clabverter の出力は **stdout=YAML / stderr=INFO ログ**。`command`(argv) で実行し
  `register.stdout` を `copy` で書けば、INFO ログを混入させずに manifests を得られる。
  shell の `2>/dev/null > file` リダイレクトは ansible 経由だと `rc=2` で失敗したため argv 方式に変更。
- slurpeeth 注入は `lineinfile insertafter: '^spec:$'`（Topology CR の spec 直下、1 箇所のみ）。

---

## reset.yml — 0 ベース初期化（破壊的）

`hosts: k8s_cluster`, `become: true`。

```yaml
- assert: that: reset_confirm | default('') == 'yes'     # ガード
- command: kubeadm reset -f            ( failed_when: false )
- file: state=absent  ( /etc/cni/net.d, /etc/kubernetes, /var/lib/etcd, ~/.kube )
- command: ip link del {vxlan.calico, cni0, flannel.1}   ( failed_when: false )
- systemd_service: containerd restarted
```

- `-e reset_confirm=yes` 必須。無ければ `assert` で停止し誤実行を防ぐ。

---

## モジュール採用方針まとめ

| 層 | 採用 | 理由 |
|---|---|---|
| OS / パッケージ / サービス | `apt` / `modprobe` / `sysctl` / `get_url` / `unarchive` / `systemd_service` / `dpkg_selections` | 冪等・宣言的に書ける |
| 自前 Kubernetes リソース | `kubernetes.core.k8s` / `kubernetes.core.helm` | CR・Helm を構造化定義でき差分管理しやすい |
| kubeadm / 上流 URL の kubectl apply | `command` / `shell` | モジュール非対応・URL 取得が絡む。`creates`/`changed_when` で冪等性を補う |

---

## 関連ドキュメント
- [Ansible 構築手順](./ansible-setup-guide.md)
- [Nornir 構築手順](./nornir-setup-guide.md) / [Nornir コード解説](./nornir-code-explained.md)
