# 高质量<免费>交流群

[IPQ技术讨论群](https://qm.qq.com/q/v7nMhzB4oU)

# 高质量<付费>中转站

[Krill-Code](https://www.krill-code.com/register?invite=959NHQCZGT)

# 本地编译器

https://github.com/VIKINGYFY/OWRT-Tools.git

# 自用修改版插件

https://github.com/VIKINGYFY/packages.git

# OpenWRT-CI

官方版：

https://github.com/immortalwrt/immortalwrt.git

自用版：

https://github.com/VIKINGYFY/immortalwrt.git

# U-BOOT

高通版-沉心：

https://github.com/chenxin527/uboot-qsdk12.5-build.git

高通版-小猪：

https://github.com/1980490718/u-boot-2016.git

联发科-全新版：

https://github.com/VIKINGYFY/UBOOT-CI/releases

联发科-官方版：

https://drive.wrt.moe/uboot/mediatek

# 固件简要说明

本仓库仅手动编译，不通过定时任务或清理工作流触发编译。在 Actions 中选择 `OWRT-ALL` → `Run workflow`。

固件信息里的时间为编译开始的时间，方便核对上游源码提交时间。

主构建保留 N100 / x86_64 定制，使用官方 `immortalwrt/immortalwrt` 的 `openwrt-25.12` 分支。该分支跟随 25.12 系列更新，版本标识为 `25.12-SNAPSHOT`，不是固定的正式版标签。

- 默认主题 Aurora，管理地址 `192.168.66.1`。
- `eth0`、`eth1`、`eth2` 桥接为 LAN；`eth3` 为 PPPoE WAN，拨号账号密码由用户填写；WAN IPv6 关闭。
- 保留 Nikki / Mihomo，关闭 HomeProxy，不额外选装原 X86 配置中的 MT79xx 无线驱动和 wpad。
- 保留 Docker / Compose、SQM / CAKE、BBR / fq、ethtool、irqbalance、coreutils-timeout 和 SFTP 服务。
- 内核分区 128 MB，根分区 2048 MB，使用 SquashFS，生成 IMG / VMDK。

已同步 CI 上游 `VIKINGYFY/OpenWRT-CI` 的 `6a66469`，保留以上定制。其他平台配置与手动构建入口仍保留。

## N100 网络调优

X86 固件通过 `Scripts/X86-Tune.sh` 生成并启用 `net_turbo` 服务及网络热插拔脚本。构建时使用 `DESTDIR`，仅生成固件文件，不修改构建主机网络。该脚本与本地维护的 `openwrt/x86/openwrt-optimize.sh` 保持一致。

- 物理网卡使用 `packet_steering=2`，允许四核处理收包；PPPoE、Mihomo TUN、Tailscale 和 `wg0` 使用四核 RPS。
- SQM 新配置默认下载 `1000000`、上传 `50000` kbit/s；已有带宽值保留。
- PPPoE 使用 CAKE `overhead 46`、`mpu 84`；接口名包含 VLAN 后缀时使用 `overhead 50`。
- 保留 BBR/fq、CPU 自适应调频和关闭 flow offloading 的设置。
- 热插拔脚本处理 TUN、PPPoE、Tailscale 和 `wg0` 的重新创建，Mihomo TUN MTU 保持 1460。

在已运行的路由器上执行安装脚本会应用配置并重启 SQM，应在允许短暂网络抖动时操作。它不会主动重新拨号或重启 Nikki。不要把旧版 `net_turbo` 文件加入升级保留列表，以免覆盖新固件内的版本。


# 目录简要说明

workflows——自定义CI配置

Scripts——自定义脚本

Config——自定义配置

## Star History

<a href="https://www.star-history.com/?repos=vikingyfy%2Fopenwrt-ci&type=date&legend=top-left">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://api.star-history.com/chart?repos=vikingyfy/openwrt-ci&type=date&legend=top-left" />
 </picture>
</a>
