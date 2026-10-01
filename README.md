# openstack-trove-images

Trove 的全部制品流水线,与 VM 操作系统镜像(`openstack-cloud-images`)分开维护。

Trove 代码来自 fork [`fivetime/openstack-trove`](https://github.com/fivetime/openstack-trove)
的 `master-fivetime` 分支(`master` 只跟上游;基于上游 master 而非 stable/2026.1,因为上游 datastore 的工作都落在 master)。这个 fork 按容器架构重新移植了 2020 年
`aa1d4d22 Datastore containerization` 删掉的 datastore,因此**guest 镜像、数据库镜像、
备份镜像都必须和 fork 配套**,不能用上游 tarballs / quay 上的现成品。

| 目录 | 制品 | 去向 | 状态 |
|---|---|---|---|
| `guest/` | guest 虚机镜像(Ubuntu noble + docker + trove-guestagent) | Glance | ✅ 流水线已建 |
| —— | 各数据库的容器镜像 | 不用构建:官方镜像经 harbor 代理缓存拉取 | ✅ |
| `backup/` | 各数据库的备份容器镜像 | ghcr.io,guest 经 harbor 代理缓存拉取 | ✅ 流水线已建 |

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

### 构建期间优先 IPv4(`guest/elements/build-prefer-ipv4`)

构建在 chroot 里用 apt 和 pip 装包,二者都按 `getaddrinfo` 返回的顺序逐个试地址,IPv6 在前。
构建机的 IPv6 出网不通时,每个连接都要先等超时才轮到 IPv4。2026-09-29 实例:正常 15 分钟的构建,
在"装 guest agent 依赖"这一步卡到 90 分钟上限被取消,日志里全是
`ReadTimeoutError("HTTPSConnectionPool(host='pypi.org' ...` 后重试,平均每个请求 4 分钟。

**构建机自己配了优先 IPv4 也没用** —— chroot 里有它自己的 `/etc/gai.conf`。

这个元素在 `pre-install.d` 往 chroot 的 `/etc/gai.conf` 加一行优先 IPv4,在 `finalise.d` 删掉,
成品镜像和不带这个元素构建出来的一样;流水线挂载镜像核对时会确认这一行没有留下。
通过 master 的 trovestack 提供的 `DIB_LOCAL_ELEMENTS_PATH` + `TROVE_DIB_EXTRA_ELEMENTS` 接入,不改 fork 里的元素。

**怎么判断是不是这个问题**:手动跑 `Probe runner egress` 工作流(`.github/workflows/probe-egress.yaml`)。
它对 pypi.org、files.pythonhosted.org、opendev.org、archive.ubuntu.com 的**每一个地址**分别发请求。
2026-09-29 的结果:所有 IPv4 地址 200,**所有** IPv6 地址连接超时(不是部分地址)。
只发一个请求看通不通是不够的:各个客户端各自挑地址,一个通了不代表其它地址也通。

> 根因在网络侧(runner 所在租户网段的 IPv6 出网),不在这个仓库。这里只是让构建不受它影响。

### 需要的仓库配置

Secrets(和 `openstack-cloud-images` 相同):`OS_AUTH_URL` `OS_USERNAME` `OS_PASSWORD`
`OS_PROJECT_NAME` `OS_PROJECT_DOMAIN_NAME` `OS_USER_DOMAIN_NAME` `OS_REGION_NAME`。
需要 admin 权限:把镜像 owner 设成 service 项目只有 admin 能做。

Variable:`OS_GATEWAY_VIP` —— runner 解析不了 `*.openstack.svc.cluster.local`,
流水线把 keystone/glance 的名字写进 `/etc/hosts` 指到网关 VIP(网关按 Host 头路由,
所以 URL 里必须保留名字,不能直接换成 IP)。

Runner:`self-hosted`(RaaS)。构建要 sudo、loop/nbd 设备和 debootstrap。

## 数据库镜像

数据库本身用各家**官方镜像**,不需要构建。guest 虚机里的 docker 按
`[<datastore>] docker_image` + `:<datastore 版本号>` 拉取,指到 harbor 的代理缓存即可(匿名可拉):

| datastore | `docker_image` |
|---|---|
| mysql | `harbor.tue.jp/cache-dockerhub/library/mysql` |
| mariadb | `harbor.tue.jp/cache-quay/openstack.trove/mariadb`(上游自建,见 trove `playbooks/images/mariadb/`) |
| postgresql | `harbor.tue.jp/cache-dockerhub/library/postgres` |
| redis | `harbor.tue.jp/cache-dockerhub/library/redis` |
| percona | `harbor.tue.jp/cache-dockerhub/percona/percona-server` |
| pxc | `harbor.tue.jp/cache-dockerhub/percona/percona-xtradb-cluster` |
| mongodb | `harbor.tue.jp/cache-dockerhub/library/mongo`(⚠ 8.0 系列在 6.19+ 内核上拒绝启动 `SERVER-121912`,注册 8.2) |
| cassandra | `harbor.tue.jp/cache-dockerhub/library/cassandra` |
| couchdb | `harbor.tue.jp/cache-dockerhub/library/couchdb` |
| couchbase | `harbor.tue.jp/cache-dockerhub/library/couchbase`(社区版的 tag 是 `community-7.6.2`,⚠ 无前缀的 `7.6.2` 是企业版;Trove 拿**版本号**当 tag,所以 `--version-number community-7.6.2`) |
| vertica | `harbor.tue.jp/cache-dockerhub/opentext/vertica-k8s`(官方已不出 CE 镜像,用 k8s 镜像;tag 带 `-minimal`,版本号注册成 tag 如 `25.4.0-0-minimal`;⚠ 26.1 起不再接受镜像自带的 CE license,要用 `vertica_license` 模块装正式 license) |
| db2 | `harbor.tue.jp/cache-icr/db2_community/db2`(icr.io 的代理缓存,10-01 新建;社区版镜像,装 IBM 发的 license 即升级为对应版本,同一个镜像) |
| valkey | `harbor.tue.jp/cache-dockerhub/valkey/valkey` |
| keydb | `harbor.tue.jp/cache-quay/openstack.trove/keydb`(Docker Hub 上的 tag 是 `x86_64_v6.3.3` 这种带架构前缀的,对不上版本号;上游重打过 tag 放在 quay) |

**datastore 的版本号就是镜像 tag**(Victoria 起的规矩):注册 `7.2` 这个版本,拉的就是 `redis:7.2`。
上表每一行都用表里的版本实测过匿名拉取(2026-09-29);新增版本前先验证 tag 存在。

## 备份镜像

工作流 `.github/workflows/build-backup-images.yaml`,矩阵在 `backup/images.json`。

guest agent 做备份/恢复时,在这个镜像里执行 `python3 main.py --driver=<备份策略> ...`,所以镜像里
必须是 **fork 的** `backup/` 代码 —— 上游镜像不认识 fork 新增的驱动。tag 同样是 datastore 版本号。

- 产物:`ghcr.io/fivetime/trove/db-backup-<datastore>:<版本>`,用工作流自带的 token 推送,不需要额外凭据
- guest 侧配置:`backup_docker_image = harbor.tue.jp/cache-ghcr/fivetime/trove/db-backup-<datastore>`
- 在 GitHub 托管的 runner 上构建(只是 `docker build`,不需要 RaaS)
- 每天 03:30 UTC 定时 + 手动;只有 fork 的 `backup/` 目录自上次构建后有改动才重建
  (镜像标签 `jp.tue.trove.backup-revision` 记着构建时 `backup/` 的最后一个 commit)
- 推送前验证:按该 datastore 的默认备份策略,在镜像里照 `main()` 的顺序解析参数并导入驱动类
  (`backup/smoke.py`);同时确认一个不存在的驱动名会被拒绝

> 验证不能用 `main.py --driver=X --help`:`--help` 在校验驱动名之前就退出了,传一个不存在的驱动也返回 0。

> 首次推送后实测(2026-09-29):`ghcr.io/fivetime/trove/db-backup-redis:7.2` 直接匿名拉取 200,
> 经 `harbor.tue.jp/cache-ghcr/...` 匿名拉取也是 200,没有做任何可见性设置。
> 以后新增的镜像如果拉取返回 401/404,先到 GitHub 的 Packages 页面看这个包是不是 private。

新增 datastore 或版本:往 `backup/images.json` 加一行。`strategy` 填 guest agent 实际传给 `--driver` 的值,
即该 datastore 的 app 类 `get_backup_strategy()` 的返回值 —— **不一定等于** `[<datastore>] backup_strategy` 的默认值:
MySQL 和 Percona 的默认值是 `innobackupex`,实际永远返回 `xtrabackup`(`trove/guestagent/datastore/mysql/service.py`)。
第一版流水线从配置默认值取策略名,结果对 mysql 镜像验证的是 guest 不会用的驱动。

## 单元测试

`tools/run-unit-tests.sh <trove 检出目录> [flake8 路径...]` —— 在和服务镜像相同的 Python(3.12)与
约束文件下,跑 Trove 单元测试、备份容器单元测试和 flake8。先把检出目录复制一份再跑,
不会在源码树里留下 `.stestr`、`trove_test.sqlite` 之类;未提交的改动也会被带上。

测试**串行**执行:这些测试共用一个 sqlite 文件,并发跑会随机报 `database is locked`,
而且失败的用例每次都不一样,很容易被误判成代码问题。

