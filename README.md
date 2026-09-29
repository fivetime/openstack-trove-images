# openstack-trove-images

Trove 的全部制品流水线,与 VM 操作系统镜像(`openstack-cloud-images`)分开维护。

Trove 代码来自 fork [`fivetime/openstack-trove`](https://github.com/fivetime/openstack-trove)
的 `master-fivetime` 分支(`master` 只跟上游;基于上游 master 而非 stable/2026.1,因为上游 datastore 的工作都落在 master)。这个 fork 按容器架构重新移植了 2020 年
`aa1d4d22 Datastore containerization` 删掉的 datastore,因此**guest 镜像、数据库镜像、
备份镜像都必须和 fork 配套**,不能用上游 tarballs / quay 上的现成品。

| 目录 | 制品 | 去向 | 状态 |
|---|---|---|---|
| `guest/` | guest 虚机镜像(Ubuntu noble + docker + trove-guestagent) | Glance | ✅ 流水线已建 |
| `datastores/<ds>/` | 各数据库的容器镜像 | harbor | 待做 |
| `backup/` | 各数据库的备份容器镜像 | harbor | 待做 |

## guest 镜像

工作流 `.github/workflows/build-guest-image.yaml`。

**为什么必须从 fork 构建:** guest agent 的源码在构建时烤进镜像(`/opt/guest-agent`,
装进 `/opt/guest-agent-venv`),它和控制面(taskmanager/conductor)走 RPC。上游镜像里的
agent 不认识 fork 新增的 datastore。

**怎么保证同一 commit:** 直接用 fork 里的 `integration/scripts/trovestack build-image`
和它自带的 dib elements,不做改动。guest-agent element 通过 dib 的 source-repositories
取源码,流水线用 `DIB_REPOLOCATION_guest_agent` / `DIB_REPOREF_guest_agent` 把它指到
刚检出的那个 commit。构建完挂载镜像核对 `/opt/guest-agent` 的 HEAD,不等就失败。

**触发:** 每天 03:00 UTC 定时 + 手动(可指定 `trove_ref`、`force`)。每次先比较分支
头 commit 和 Glance 上最新 guest 镜像的 `trove_commit` 属性,相同就跳过。

**Glance 里的形态:**

- 名字 `trove-guest-ubuntu-noble-fivetime`,标签 `trove` + `fivetime`
- `raw` 格式 —— Glance 默认存储是 RBD,Cinder/Nova 只对 raw 做 COW 克隆
- `private`,owner = `service` 项目 —— Trove 用 service 项目的 trove 用户建实例,租户看不到
- 属性 `trove_commit=<sha>`、`hypervisor_type=qemu`(混合云调度需要)、`hw_rng_model=virtio`
- 只保留最近 3 版;还被 RBD 克隆占着的旧版删不掉,会跳过

datastore version 按**镜像标签**注册,不按 ID,新构建自动被新实例使用:

```bash
openstack datastore version create <版本> <datastore> <manager> "" \
    --image-tags trove,fivetime --active
```

### 需要的仓库配置

Secrets(和 `openstack-cloud-images` 相同):`OS_AUTH_URL` `OS_USERNAME` `OS_PASSWORD`
`OS_PROJECT_NAME` `OS_PROJECT_DOMAIN_NAME` `OS_USER_DOMAIN_NAME` `OS_REGION_NAME`。
需要 admin 权限:把镜像 owner 设成 service 项目只有 admin 能做。

Variable:`OS_GATEWAY_VIP` —— runner 解析不了 `*.openstack.svc.cluster.local`,
流水线把 keystone/glance 的名字写进 `/etc/hosts` 指到网关 VIP(网关按 Host 头路由,
所以 URL 里必须保留名字,不能直接换成 IP)。

Runner:`self-hosted`(RaaS)。构建要 sudo、loop/nbd 设备和 debootstrap。

## 单元测试

`tools/run-unit-tests.sh <trove 检出目录> [flake8 路径...]` —— 在和服务镜像相同的 Python(3.12)与
约束文件下,跑 Trove 单元测试、备份容器单元测试和 flake8。先把检出目录复制一份再跑,
不会在源码树里留下 `.stestr`、`trove_test.sqlite` 之类;未提交的改动也会被带上。

测试**串行**执行:这些测试共用一个 sqlite 文件,并发跑会随机报 `database is locked`,
而且失败的用例每次都不一样,很容易被误判成代码问题。

