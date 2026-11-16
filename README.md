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
