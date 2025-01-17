---
name: Release Checklist
about: Release checklist.
title: ''
labels: ''
assignees: ''

---

# Changelog

## Features
- [ ] Features

## Bug fixes
- [ ] Bug fixes

## Enhancements
- [ ] Enhancements

## Tech debt
- [ ] Tech debt

# 通用
- [ ] 关闭 SSH 服务
- [ ] 清除 .bash_history（包括 ubuntu 和 root 用户）
- [ ] 安装 arping 防止同网段虚机和 IP 地址频繁重建引起的问题（apt install iputils-arping）
- [ ] TCP keepalive timeout（基础网络）

# 服务功能测试

- [ ] 写入数据，自定义客户端正常读取
- [ ] 在配置项可自由开启zabbix-agent
- [ ] 在配置项中可自由开关caddy
- [ ] confd升级到最新版本
- [ ] 通过浏览器查看服务日志
- [ ] 日志轮转

# 集群功能测试

## 创建
- [ ] 创建单个节点的集群
- [ ] 创建多个节点的集群
- [ ] 创建常用硬件配置的集群
- [ ] 修改常用配置参数，创建集群

## 横向伸缩
- [ ] 增加节点，数据正常
- [ ] 删除节点

## 纵向伸缩
- [ ] 扩容：服务正常
- [ ] 缩容：服务正常

## 升级
- [ ] 数据不丢
- [ ] 升级后设置日志留存大小限制值，查看日志留存配置生效

## 其他
- [ ] 关闭集群并启动集群
- [ ] 删除集群并恢复集群
- [ ] 备份集群并恢复集群
- [ ] 支持多可用区
- [ ] 切换私有网络
- [ ] 绑定公网 IP(vpc)
- [ ] 基础网络部署
- [ ] 自动伸缩（节点数，硬盘容量）
- [ ] 健康检查和自动重启
- [ ] 服务监控

# 高可用

- [ ] 把三节点集群中的主节点断网，自动做主从切换（允许 10 秒的时间完成主从切换的动作）
- [ ] 客户端通过 sentinel 方式连接，把三节点集群中的主节点断网，数据正常写入和查询（切换过程中读写操作不可用）
- [ ] 客户端通过 VIP 方式连接，把三节点集群中的主节点断网，数据正常写入和查询（切换过程中读写操作不可用）
- [ ] 关闭服务（redis-server/redis-sentinel）后，服务可自动启动

# 压力测试

- [ ] 节点磁盘占满后，该节点的服务状态会显示为不正常
- [ ] 节点磁盘占满，关闭启动集群后，磁盘占满的节点服务状态仍显示为不正常
- [ ] 删除磁盘未占满节点，可以删除
- [ ] 删除磁盘占满节点，可以删除
- [ ] 节点磁盘占满，扩容硬盘后，集群节点恢复正常

# 性能/基准测试

- [ ] 持续读写平均延迟
  >  压测工具：redis-benchmark

# Long Run

- [ ] UI界面中循环进行创建集群--增删节点--重启集群--扩容集群--删除集群的操作
- [ ] 在10G存储，且磁盘使用率为95%的集群中，循环进行增删节点--扩容缩容集群--重启集群的操作

# 上线

- [ ] 老区（广东 1 区、亚太 1 区）有可部署的版本
- [ ] 所有区可以正常部署
- [ ] 服务价格改为 0
- [ ] 版本号合理命名
