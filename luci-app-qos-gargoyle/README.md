### 升级log：
## v1.3.8-5
- 1、ifb是石像鬼官方升级的,和这个没有什么关系。
- 2、新增QOS栏目。
- 3、修复在21.02以上luci崩溃问题。
- 4、修复禁用时luci崩溃问题。
- 5、负载均衡那里没有显示数据（不影响使用）。希望哪个大神帮忙修复下。不会修。
- 6、修复添加规则排序后没有应用到防火墙的问题（没人反馈么？）
- 7、修复删除规则后其余规则乱序或者被误删的问题
- 8、支持多端口写入，不过需要指定的写入规则
- 9、支持流量连接范围限定，一样需要指定的写入规则


### 鸣谢：
来源 QoS Gargoyle: https://github.com/kuoruan/luci-app-qos-gargoyle  1.3.6。 感谢作者的奉献。
来源  https://github.com/Ameykyl/openwrt18.06/tree/master/package/my/luci-app-qos-gargoyle 1.3.8-4
