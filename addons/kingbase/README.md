# KubeBlocks 管理金仓 KingbaseES 生产高可用方案

本目录提供面向 KubeBlocks 0.8.x 的 KingbaseES V9 高可用 Addon。方案使用 KB 0.8 的
独立 `ComponentDefinition` 引用模式（Cluster 中使用 `componentDef`），Helm Chart
就是当前 `addons/kingbase/` 目录。

该方案已经实现 KubeBlocks 生命周期接管、三副本同步流复制、角色服务、自动故障转移、
计划切换、旧主 rejoin、TLS/密码认证、全量备份、PDB、调度约束和监控告警。所有 KB 0.8
支持的日常变更均通过 OpsRequest 入口；它仍须使用
目标金仓版本、CPU/OS、CSI 和 Kubernetes 环境完成故障与恢复验收，才能进入生产。
验收边界见 [`PRODUCTION-READINESS.md`](PRODUCTION-READINESS.md)。

## 架构

```text
                         KubeBlocks 0.8
               Cluster / OpsRequest / Backup
                              |
              +---------------+---------------+
              |               |               |
          Kingbase-0       Kingbase-1      Kingbase-2
          primary          standby         standby
              |               |               |
              +------ synchronous WAL --------+
              |
      rw Service (primary)       ro Service (standby)

每个 Pod: KingbaseES + HA manager + role probe + optional exporter
选主依据: Kubernetes Lease + Pod WAL LSN/timeline 注解
```

写权限由 Kubernetes Lease 唯一授权。主库每 2 秒续租；无法确认写权限超过 15 秒时本地
立即隔离，备库按本地单调时钟观察 Lease resourceVersion 连续 30 秒未变化后才能竞争，
不依赖节点之间的墙上时钟同步。候选按 timeline、WAL LSN 排序，默认
`maximumLagOnFailoverBytes=0`。计划切换会冻结新写入、断开现有业务会话、checkpoint，等待
目标备库追到最终 WAL 位点后，再停旧主并释放 Lease。

## 前置条件

- KubeBlocks `0.8.x` 已安装；其他大版本的 CRD/API 不兼容。
- 至少 3 个可调度节点；生产建议跨 3 个可用区。
- 经数据库 fsync/断电验证的复制型 CSI StorageClass。
- 可用的 KubeBlocks BackupRepo；启用告警时需 Prometheus Operator CRD。
- 金仓合法介质、license，以及与目标 CPU/OS 对应的安装依赖。
- 严格防脑裂场景必须配置基础设施 STONITH/节点电源隔离。

`kingbase-system` 应作为专用受信命名空间：NetworkPolicy 允许其中的 KubeBlocks 操作和
备份 Pod 访问数据库；其他命名空间只有同时带 `kingbase-access=true` 命名空间标签和
`kingbase-client=true` Pod 标签时才能访问 54321。

## 1. 构建镜像

下载与本方案匹配的官方 Docker archive。目标集群为 amd64，当前使用官网列出的
`V009R001C010B0004` x86_64 Docker 包：

```bash
curl --fail --location --retry 3 \
  -A 'Mozilla/5.0' \
  -e 'https://www.kingbase.com.cn/download.html' \
  -o /secure/path/KingbaseES_V009R001C010B0004_x86_64_Docker.tar \
  'https://kingbase.oss-cn-beijing.aliyuncs.com/upload/KESV9-baseline/allmode/V009R001C010/docker/KingbaseES_V009R001C010B0004_x86_64_Docker.tar'

docker load -i /secure/path/KingbaseES_V009R001C010B0004_x86_64_Docker.tar
docker image inspect kingbase_v009r001c010b0004_single_x86:v1

docker build \
  --build-arg UPSTREAM_IMAGE=kingbase_v009r001c010b0004_single_x86:v1 \
  -t docker.io/wallykk/kingbase:v9r1c10-b0004-21 \
  addons/kingbase/image

docker push docker.io/wallykk/kingbase:v9r1c10-b0004-21
```

包装镜像只复用官方金仓二进制，不执行官方 archive 的默认入口脚本；它会将挂载的
`license.dat` 写入金仓运行时读取的位置后启动本方案的 HA supervisor。临时授权可在[金仓授权页](https://www.kingbase.com.cn/download.html#authorization?authorcurrV=V9R1C10)
申请，并且只能用于联调和验收，生产必须替换为与 CPU 架构、版本和部署规模相符的正式授权。请在构建前确认厂商
发布的版本、授权条款和校验和。不要把 Docker archive、license 或私有仓库凭据提交到 Git，也不要把许可证复制进镜像。
ARM 环境必须使用厂商 aarch64 Docker 包重新构建，不能给 x86_64 镜像改标签冒充 ARM 镜像。
`values-production.yaml` 因此默认把 Pod 限制到 `kubernetes.io/arch=amd64`；使用经过验证的
aarch64 镜像时必须同时替换镜像摘要并把该节点选择器改为 `arm64`。

## 2. 准备命名空间和 Secret

```bash
kubectl create namespace kingbase-system --dry-run=client -o yaml | kubectl apply -f -

kubectl -n kingbase-system create secret generic kingbase-license \
  --from-file=license.dat=/secure/path/license.dat \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n kingbase-system create secret generic kingbase-tls \
  --from-file=tls.crt=/secure/path/tls.crt \
  --from-file=tls.key=/secure/path/tls.key \
  --from-file=ca.crt=/secure/path/ca.crt \
  --dry-run=client -o yaml | kubectl apply -f -

openssl rand -hex 32 > /secure/path/kingbase-ha-token
kubectl -n kingbase-system create secret generic kingbase-ha-token \
  --from-file=token=/secure/path/kingbase-ha-token \
  --dry-run=client -o yaml | kubectl apply -f -
```

证书至少应覆盖集群 rw/ro Service 和 headless Pod DNS。集群内复制默认 `verify-ca`；业务
客户端建议使用 `verify-full`。数据库 system/replication 密码由 KubeBlocks 生成并存入
Credential Secret，不写入 values。

## 3. 配置并安装

[`values-production.yaml`](values-production.yaml) 已指向 `docker.io/wallykk/kingbase:v9r1c10-b0004-21`；
Chart 默认同时固定已验收镜像摘要
`sha256:79afd89a27074c693c56fee550cdf3d3532e503a064be78d5f0891fceab4f699`。
生产上线前应将镜像复制到组织控制的仓库，完成漏洞扫描和签名验证，并把 `image.repository`
与 `image.digest` 一起替换；自建新镜像时若暂时只使用 tag，必须显式把 `image.digest` 设为空。
部署前仍必须设置一个可提供每副本至少 500Gi 的生产 CSI `cluster.storageClassName`。若 KubeBlocks Helm release 名不是 `kubeblocks`，还需设置：

```yaml
kubeblocks:
  name: kubeblocks
  releaseName: <实际 KubeBlocks Helm release 名>
  namespace: <KubeBlocks controller 所在命名空间>
```

默认 NetworkPolicy 仅向该控制命名空间放行 lorry `3501/TCP`，供 KubeBlocks 完成账号
Provision 和 Component/OpsRequest 协调；它不因此获得数据库 `54321/TCP` 的业务访问权限。
若 controller 命名空间不是默认的 `kb-system`，必须在安装前覆盖该值，否则扩缩容等
OpsRequest 会停在等待 Component 更新的状态。

安装 Addon 和示例三副本集群：

```bash
helm upgrade --install kingbase-addon addons/kingbase \
  --namespace kubeblocks \
  -f addons/kingbase/values-production.yaml
```

KB 0.8 会在创建 Component 时快照 ComponentDefinition 的 runtime。镜像或运行时配置升级应使用
新的 ComponentDefinition/Cluster 名称和受控迁移，不能仅更新一个已经运行 Cluster 的
ComponentDefinition 后期待现有 Pod 滚动更新。

默认生产参数包括：3 副本、`DoNotTerminate`、宿主机硬反亲和、PDB
`minAvailable=2`、500Gi PVC、同步提交和每日全量备份。KB 0.8 的 Cluster API 不支持
新版的 zone spread 字段，跨可用区调度需通过节点标签/亲和策略和底层调度器配置保证。若集群没有 3 个满足
条件的节点，Pod 会保持 Pending，这是预期的安全行为。

默认 `synchronous_standby_names=ANY 1 (*)` 允许任意一个同步备库确认提交，优先保障一个
备库故障时仍可写，但自动故障转移只能选择观测到 WAL 最靠前的备库，不能据此承诺绝对
RPO=0。若业务以零丢数优先，可设置为 `ANY 2 (*)`，代价是任一备库不可用都会阻塞写入。

## 4. 验证集群

```bash
kubectl -n kingbase-system get cluster kingbase-prod
kubectl -n kingbase-system get pod,svc,pvc -l app.kubernetes.io/instance=kingbase-prod -o wide
kubectl -n kingbase-system get lease kingbase-prod-kingbase-primary -o yaml
kubectl -n kingbase-system get pod \
  -l app.kubernetes.io/instance=kingbase-prod \
  -o custom-columns=NAME:.metadata.name,ROLE:.metadata.labels.kubeblocks\.io/role,LSN:.metadata.annotations.kingbase-ha\.sealos\.io/last-wal-lsn
```

验收时必须看到恰好一个 `primary`、两个 `standby`，rw Service 只有一个 endpoint，ro
Service 有两个 endpoint，主库 `pg_stat_replication` 至少一个连接为同步状态。

## 5. 计划切换

自动选择最优备库：

```yaml
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: kingbase-switchover-001
  namespace: kingbase-system
spec:
  clusterRef: kingbase-prod
  type: Switchover
  switchover:
    - componentName: kingbase
      instanceName: "*"
```

指定候选时，把 `instanceName` 改成实际 standby Pod 名。操作会短暂将新事务设为只读并断开
现有业务会话；客户端必须支持重连和事务重试。候选追到最终 WAL 后旧主才会停库并释放
Lease。恢复后优先 `sys_rewind`，失败时保留旧数据并全量重建。每次 OpsRequest 必须使用
新名称。

## 测试集群重建

生产 Cluster 保持 `DoNotTerminate`。仅在确认旧测试 Cluster 已删除、其 Pod 和 PVC 已全部消失后，
若要在同一 namespace 使用相同 Cluster 名称重建，可删除遗留的
`<cluster>-<component>-primary` Lease 再创建新 Cluster。该 Lease 由 HA manager 创建，在 KB 0.8
中不带 Cluster owner reference；运行中的生产 Cluster 绝不能删除它。

## 6. 备份

安装后 KubeBlocks 会生成 `kingbase-prod-kingbase-backup-policy`。正式操作使用 KB 0.8
原生 `Backup` OpsRequest，由 controller 自动创建并追踪底层 DataProtection `Backup` CR：

```yaml
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: kingbase-prod-backup-001
  namespace: kingbase-system
spec:
  clusterRef: kingbase-prod
  type: Backup
  backupSpec:
    backupName: kingbase-prod-backup-001-data
    backupPolicyName: kingbase-prod-kingbase-backup-policy
    backupMethod: kingbase-basebackup
    deletionPolicy: Retain
    retentionPeriod: 7d
```

定时策略默认每天 UTC 18:00、保留 7 天。当前提供的是可恢复全量物理备份，不是 PITR；
`sys_basebackup` 使用物理复制协议，BackupPolicy 必须选择 `replication` 系统账号，不能
改成普通 `system` 账号，否则会被 `sys_hba.conf` 拒绝。

卷快照方法由 `backup.snapshotEnabled` 显式控制，默认关闭。启用前必须为 PVC 的
StorageClass 配置匹配的 `VolumeSnapshotClass`，并实际验证 `VolumeSnapshot.status.readyToUse`
以及从快照恢复到新 PVC；仅有 Snapshot CRD 或“SnapshotCreated”事件不代表备份可用。当前
测试集群的 `openebs-vg-lvm`（`local.csi.openebs.io`）创建的快照长期保持
`readyToUse=false`、`restoreSize=0`，因此本方案没有把卷快照宣称为已完成能力，继续使用已验收的
物理全量备份。
上线前必须执行一次“恢复到新 Cluster + 业务数据校验”，不能只检查 Backup CR 为 Completed。
KB 0.8 原生恢复使用 `Restore` OpsRequest，在同一 namespace 以新的 `clusterRef` 创建目标
Cluster，不能原地覆盖源集群：

```yaml
apiVersion: apps.kubeblocks.io/v1alpha1
kind: OpsRequest
metadata:
  name: kingbase-prod-restore-001
  namespace: kingbase-system
spec:
  clusterRef: kingbase-prod-restore-001
  type: Restore
  restoreSpec:
    backupName: kingbase-prod-backup-001-data
    volumeRestorePolicy: Parallel
```

模板见 [`tests/restore-full-test.yaml`](tests/restore-full-test.yaml)。测试集群已使用
`kingbase-test-backup-ops-b20-r2-data` 实际创建新的三副本 Cluster：Restore OpsRequest
`kingbase-restore-b20-r4` 为 `Succeed`，目标 Cluster 为 `Running`，恢复前写入的业务标记可查询，
主库有两个 `streaming` 备库。测试节点存储余量很小，因此仅将这份测试 Backup 的 Cluster
Snapshot annotation 调整为每副本 `320Mi`；源 Cluster 和源 PVC 仍保持 `640Mi`，生产恢复不能
用此测试容量替代容量评审。

恢复时 Pod 0 使用物理备份成为新主，Pod 1/2 会清理各自解包的数据并通过 `sys_basebackup`
从新主重建，避免多个副本直接启动同一份 basebackup 后产生 WAL 分叉。KB 0.8.2 的
Backup/Restore 字段是 `backupSpec`/`restoreSpec`；更新版本的 `backup`/`restore` 字段不能直接
用于该集群。`kubeblocks` 与 `kubeblocks-dataprotection` 两个 Deployment 还必须共同使用
`kubeblocks-secret/dataProtectionEncryptionKey` 作为 `DP_ENCRYPTION_KEY`，否则恢复系统账号会因
控制器密钥不一致而解密失败；`scripts/preflight-kb08.sh` 会检查这一项。

## 7. 参数重配

KB 0.8 通过 `ComponentDefinition.spec.configs` 管理用户配置。模板会把
`kingbase-user.conf` 挂载到每个 Pod，并由入口脚本 include；默认只开放
`log_min_duration_statement` 这类可热加载参数。同步复制、WAL、归档、TLS、监听地址和
`primary_conninfo` 不在用户配置文件中，不能通过重配改写。
`configuration.namespace` 为空时配置模板位于 Helm release namespace；生产 values 将它
显式放在 `kingbase-system`，该命名空间必须在安装前存在。

配置模板见 [`templates/configuration.yaml`](templates/configuration.yaml)，
操作样例见 [`tests/reconfigure-test.yaml`](tests/reconfigure-test.yaml)。修改
对应 namespace 的 ConfigMap 后，使用一次性的 `Reconfiguring` OpsRequest 验证热加载；需要
重启的参数必须使用 `Serial` 更新并检查三个成员始终保持一个 primary。KB 0.8 对
`spec.configs` 标记为不可更新，已有 Cluster 若创建时没有该字段，不能直接补丁添加；应按
备份恢复流程创建带配置模板的新 Cluster 后再演练。当前测试集群已完成 ConfigMap/CRD
server-side dry-run，但未对运行中的旧 Cluster 原地加配置。

## 8. 外部暴露

使用 KB 0.8 `Expose` OpsRequest 只暴露 `primary` 的 rw Service。测试清单
[`tests/expose-nodeport-test.yaml`](tests/expose-nodeport-test.yaml) 使用临时 NodePort，
对应的 [`tests/expose-nodeport-disable-test.yaml`](tests/expose-nodeport-disable-test.yaml)
负责回收。生产应优先使用受控 LoadBalancer、固定来源网段和 TLS `verify-full`；不要把
standby/ro Service 或数据库端口直接暴露到公网。NetworkPolicy 和云防火墙必须同时允许
明确的来源，否则 NodePort 对象成功不等于业务连接可达。

## 9. CPU/内存升降配与存储扩容

不要直接修改运行中 Pod、StatefulSet 或 PVC。对 KB 0.8 Cluster 必须创建一次性的
`OpsRequest`，字段使用 `clusterRef`。本目录的
[`scripts/scale-kb08.sh`](scripts/scale-kb08.sh) 会在提交前确认：Cluster 为 `Running`、
所有 Kingbase Pod 已 Ready、恰好一个 primary 和至少两个 standby，且没有其他未结束的
OpsRequest。它不会使用 `force`。

垂直升降配会滚动更新 Pod；业务客户端必须支持连接重试和事务重试。目标值覆盖 Kingbase
主容器完整的 CPU/内存 request/limit，不能只提供其中一个字段：

```bash
bash addons/kingbase/scripts/scale-kb08.sh vertical \
  --namespace kingbase-system --cluster kingbase-prod \
  --request-cpu 3 --request-memory 12Gi \
  --limit-cpu 6 --limit-memory 24Gi
```

存储只允许扩容，不能缩小。脚本会逐块检查 data PVC 的当前容量，并要求对应的
StorageClass 声明 `allowVolumeExpansion=true`。CSI 后端仍必须有足够的实际容量：

```bash
bash addons/kingbase/scripts/scale-kb08.sh volume \
  --namespace kingbase-system --cluster kingbase-prod --storage 750Gi
```

先附加 `--dry-run` 以做服务器端 CRD 校验。操作提交后脚本会等待 `OpsRequest` 到达
`Succeed`，再检查所有 Pod Ready 并输出实际资源或 PVC 容量。应在变更记录中保存
OpsRequest 名称、目标规格和前后资源；后续 Helm 升级前也应把已批准的目标规格同步到环境
专用 values 文件，避免配置基线漂移。测试集群的可直接执行样例在
[`tests/vertical-scaling-test.yaml`](tests/vertical-scaling-test.yaml)、
[`tests/vertical-scaling-downscale-test.yaml`](tests/vertical-scaling-downscale-test.yaml) 和
[`tests/volume-expansion-test.yaml`](tests/volume-expansion-test.yaml)。先执行升配并完成 HA
验证，再执行降配；确认资源基线恢复且集群稳定后，最后才执行不可逆的卷扩容。

KB 0.8.2 原生支持的操作入口包括 `Start`、`Stop`、`Restart`、`Switchover`、
`VerticalScaling`、`HorizontalScaling`、`VolumeExpansion`、`Reconfiguring`、`Expose`、
`Backup` 和 `Restore`。本目录对应的测试清单均使用 `clusterRef`。KB 0.8.2 的 CRD 没有
`RebuildInstance` 类型；备库故障后的重建由本方案 HA manager 通过 `sys_rewind`/全量
`sys_basebackup` 自动 rejoin，不能伪造为不存在的 OpsRequest 类型。
账号/数据库自助管理的 `DataScript` 需要 KubeBlocks controller 注册 `kingbase` lorry
engine；目标 KB 0.8.2 未提供该注册，当前不把它宣称为可执行能力。版本升级同样需要先提供
匹配金仓镜像的 `ClusterVersion`，在此之前不提交 `Upgrade` OpsRequest。

## 10. 本地校验

```bash
helm lint addons/kingbase
helm lint addons/kingbase -f addons/kingbase/values-production.yaml
python3 -m unittest discover -s addons/kingbase/image/tests -v
bash -n addons/kingbase/image/*.sh
python3 -m py_compile addons/kingbase/image/*.py
```

本地检查只能覆盖模板和控制逻辑。最终必须对目标集群执行 server-side dry-run、镜像启动、
备份恢复以及节点/网络/存储故障演练。

## 11. 部署前检

在实际安装前执行只读检查。它不会创建或删除 Kubernetes 资源；若任一硬性前提不满足会以
非零状态退出：

```bash
KINGBASE_NAMESPACE=kingbase-system \
KINGBASE_STORAGE_CLASS=<已核准的 StorageClass> \
KINGBASE_IMAGE=<已推送的金仓镜像> \
bash addons/kingbase/scripts/preflight-kb08.sh
```

前检会检查 KB 0.8 CRD、创建权限、命名空间、license/TLS/HA token Secret、节点数、
BackupRepo、StorageClass 和同一存储类的 Pending PVC。它不能在不创建 Pod 的情况下证明
私有镜像仓库可拉取，也不能替代数据库故障演练。
