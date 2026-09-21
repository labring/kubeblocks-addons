# KingbaseES HA 生产准入清单

本文是上线门禁，不是功能宣传。所有 P0 项必须在客户实际 Kubernetes、CSI、CPU/OS 和
KingbaseES 版本组合上通过并留存证据。

## 已实现的控制

| 领域 | 当前实现 |
|---|---|
| KubeBlocks 接管 | 独立 ComponentDefinition、ClusterDefinition、Cluster、角色探测、rw/ro Service、OpsRequest switchover。 |
| 一致性 | 三副本，`synchronous_commit=on`，`synchronous_standby_names=ANY 1 (*)`，自动切换相对主库最后成功发布的 WAL 位点最大允许落后 0 byte。 |
| 防双主 | Lease 写权限令牌；15 秒续租失败后本地主库 immediate stop；备库用本地单调时间观察 Lease 30 秒不变后竞争；缺少 Lease 时禁止存量主库继续运行。 |
| 候选选择 | 只选择 Ready、观测未过期、角色为 standby 的 Pod；按 timeline、WAL LSN、Pod 名确定唯一候选。 |
| 旧主恢复 | `sys_rewind` 优先，失败后保存旧目录并执行 `sys_basebackup` 全量重建。 |
| 安全 | TLS、md5 认证、Secret 密码、切换 API Bearer token、NetworkPolicy、受限容器 capabilities，不再使用远程 `trust`。 |
| 可用性 | 3 副本、宿主机硬反亲和、PDB `minAvailable=2`、DoNotTerminate；KB 0.8 通过 `affinity.topologyKeys` 约束拓扑，不使用新版的 zone spread 字段。 |
| 数据保护 | KubeBlocks BackupPolicyTemplate/ActionSet，每日全量物理备份；新三副本 Restore 已实测，恢复主库后两个备库从新主重新克隆；卷快照仅在匹配 CSI 通过 ready/restore 验收后显式启用。 |
| 参数管理 | KB 0.8 `spec.configs` 挂载用户配置 include；HA/WAL/TLS 基础参数不受用户重配。 |
| 可观测性 | 存活、角色、连接备库数、复制延迟指标和 PrometheusRule；数据库运行日志接入 KubeBlocks。 |
| 资源变更 | KB 0.8 `VerticalScaling`、`HorizontalScaling` 与 `VolumeExpansion` OpsRequest；提交脚本会阻止与其他运维操作并发，卷操作只允许扩容。 |
| 运维入口 | KB 0.8 的 Start/Stop/Restart/Switchover/Expose/Backup/Restore/Reconfiguring 均使用 OpsRequest；Backup/Restore 在 0.8.2 使用 `backupSpec`/`restoreSpec`。 |

## P0 上线门禁

- [ ] 金仓原厂确认所用版本支持 `pg_is_in_recovery`、WAL LSN 函数、`sys_basebackup -X fetch`、
  `sys_rewind`、`wal_log_hints`、`default_transaction_read_only`、`pg_stat_activity`、
  `pg_terminate_backend` 和当前 `synchronous_standby_names` 语法。
- [ ] 镜像在目标 x86_64/aarch64 与 openEuler/Kylin/UOS 组合启动，license 挂载路径和到期行为已验证。
- [ ] 已将包装镜像复制到组织控制的仓库，使用扫描、签名验证并固定 `image.digest`，不把个人镜像仓库作为生产供应链信任根。
- [ ] `kubectl apply --server-side --dry-run=server` 验证全部渲染资源，KubeBlocks controller、
  lorry 和 dataprotection 日志无错误。
- [ ] `kubeblocks` 与 `kubeblocks-dataprotection` Deployment 使用同一个
  `kubeblocks-secret/dataProtectionEncryptionKey`；否则 Restore 无法解密系统账号。
- [ ] 连续运行 24 小时，任意时刻恰好一个 primary；rw/ro Service endpoint 与角色一致。
- [ ] 删除主 Pod、停止数据库进程、节点关机、单向/双向网络分区、API Server 隔离均已演练。
- [ ] API 隔离旧主在 15 秒附近停止，任何新主不得早于 Lease 到期出现；旧主恢复后不能提供写服务。
- [ ] 同步备库存在时压测写入，主故障后的业务数据逐笔核对，验证约定 RPO/RTO。
- [ ] CSI 做过节点断电、卷强制 detach/attach、文件系统恢复和磁盘满测试，并确认不会多节点同时挂载 RWO 卷。
- [ ] 手工全量备份、定时备份、恢复到新集群、恢复后校验和备份损坏失败路径均已验证；如启用卷快照，还必须验证 `readyToUse` 和快照恢复。
- [ ] `spec.configs` 在新 Cluster 上通过可热加载与需串行重启参数的演练；已有 Cluster 不得原地补加不可更新配置字段。
- [ ] PDB、硬反亲和、CPU/内存升降配、PVC 扩容和滚动升级在节点维护期间有效，`maxUnavailable=1` 不会同时重启两个成员。
- [ ] 告警真实触发并送达值班系统：实例 Down、主库数异常、无连接备库、复制延迟、备份失败、PVC 水位。
- [ ] 有原厂、KubeBlocks、Kubernetes、CSI 四类故障的责任边界、联系人和回滚 runbook。

## 不能仅靠此 Addon 保证的事项

1. **硬隔离。** 用户态 manager 能处理 API/网络故障，但无法在自身进程被 SIGSTOP、内核冻结、
   宿主机失控或存储错误地双挂载时执行自停。严格生产环境必须配置 BMC/云 API/虚拟化层
   STONITH，或者采用金仓原厂认证的集群管理组件完成节点隔离。
2. **PITR。** 当前只有全量 `sys_basebackup`。若业务要求分钟级恢复点，必须按金仓版本接入
   WAL 归档或 `sys_rman`，并完成时间点恢复演练后才能承诺 PITR。
3. **绝对零丢数。** `ANY 1 (*)` 会在没有同步备库时阻塞提交；RPO=0 只对已成功返回且经过
   同步确认的事务成立，但故障后无法仅凭周期性 WAL 观测证明被选中的就是确认该事务的
   备库。要求严格 RPO=0 时应使用 `ANY 2 (*)` 或原厂认证的同步成员管理机制，并接受相应
   的写可用性代价。
4. **跨地域容灾。** 当前是单 Kubernetes 集群内 HA，不包含跨集群备份复制、异地容灾或多活。
5. **自动全量 rejoin 容量。** rewind 失败时旧数据会保留在同一 PVC，需预留接近一份数据库
   的额外空间；空间不足时应停止自动重建并按 runbook 处理。

## 建议验收顺序

1. 单实例镜像与 SQL 兼容验证。
2. 三副本复制、TLS、Service 路由和持续压测。
3. 计划 switchover 20 次，确认旧主全部成功 rejoin。
4. Pod/进程/节点/API/网络/存储故障矩阵，每类至少 3 次。
5. 备份恢复和业务校验；再补 PITR（如需要）。
6. 扩容、缩容、版本升级、证书轮换、license 轮换和节点维护。
7. 原厂与平台团队共同签署 RPO/RTO 和生产准入报告。

未完成上述门禁前，本目录应标记为“生产候选实现”，不能标记为“已认证生产方案”。
