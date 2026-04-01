# 上传类别定义 - 四大类 (总上传带宽: 50Mbps = 50000kbit)
config upload_class 'uclass_1'  # 实时 (游戏/语音/实时视频)
	option name 'realtime'
	option priority '1'
	option dscp '46'            # EF -> Voice 队列
	option percent_bandwidth '12'  # 占总上传带宽的12% = 6Mbps
	option per_min_bandwidth '60'      # 保证带宽占类别带宽的60% = 3.6Mbps
	option per_max_bandwidth '200'      # 允许借用
	option minRTT 'No'
	option description 'Game/VoIP'

config upload_class 'uclass_2'  # 视频流 (流媒体、视频会议)
	option name 'video'
	option priority '2'
	option dscp '34'            # AF41 -> Video 队列
	option percent_bandwidth '28'  # 占总上传带宽的28% = 14Mbps
	option per_min_bandwidth '40'      # 保证带宽占类别带宽的40% = 5.6Mbps
	option per_max_bandwidth '200'     # 最大带宽占类别带宽的200% = 28Mbps
	option minRTT 'No'
	option description 'Streaming/Video'

config upload_class 'uclass_3'  # 普通流量 (网页、应用、小文件)
	option name 'normal'
	option priority '3'
	option dscp '0'             # CS0 -> Best Effort 队列
	option percent_bandwidth '45'  # 占总上传带宽的45% = 22.5Mbps
	option per_min_bandwidth '0'      # 无保证带宽
	option per_max_bandwidth '200'     # 最大带宽占类别带宽的200% = 45Mbps
	option minRTT 'No'
	option description 'Web/Application'

config upload_class 'uclass_4'  # 大文件/后台流量 (P2P, 文件传输)
	option name 'bulk'
	option priority '4'
	option dscp '8'             # CS1 -> Bulk 队列
	option percent_bandwidth '15'  # 占总上传带宽的15% = 7.5Mbps
	option per_min_bandwidth '0'      # 无保证带宽
	option per_max_bandwidth '100'     # 最大带宽占类别带宽的100% = 7.5Mbps
	option minRTT 'No'
	option description 'File/P2P'

# 下载类别定义 - 四大类 (总下载带宽: 100Mbps = 100000kbit)
config download_class 'dclass_1'  # 实时 (游戏/语音/实时视频)
	option name 'realtime'
	option priority '1'
	option dscp '46'             # EF -> Voice 队列
	option percent_bandwidth '10'  # 占总下载带宽的10% = 10Mbps
	option per_min_bandwidth '60'  # 保证带宽占类别带宽的60% = 6Mbps
	option per_max_bandwidth '200'   #允许借用
	option minRTT 'Yes'
	option description 'Game/VoIP'

config download_class 'dclass_2'  # 视频流 (流媒体、视频会议)
	option name 'video'
	option priority '2'
	option dscp '34'             # AF41 -> Video 队列
	option percent_bandwidth '25'  # 占总下载带宽的25% = 25Mbps
	option per_min_bandwidth '40'  # 保证带宽占类别带宽的40% = 10Mbps
	option per_max_bandwidth '200'   #允许借用
	option minRTT 'No'
	option description 'Streaming/Video'

config download_class 'dclass_3'  # 普通流量 (网页、应用、小文件)
	option name 'normal'
	option priority '3'
	option dscp '0'               # CS0 -> Best Effort 队列
	option percent_bandwidth '50'  # 占总下载带宽的50% = 50Mbps
	option per_min_bandwidth '0'      # 无保证带宽
	option per_max_bandwidth '200'     # 最大带宽占类别带宽的200% = 100Mbps
	option minRTT 'No'
	option description 'Web/Application'

config download_class 'dclass_4'  # 大文件/后台流量 (P2P, 文件传输)
	option name 'bulk'
	option priority '4'
	option dscp '8'               # CS1 -> Bulk 队列
	option percent_bandwidth '15'  # 占总下载带宽的15% = 15Mbps
	option per_min_bandwidth '0'      # 无保证带宽
	option per_max_bandwidth '100'     # 最大带宽占类别带宽的100% = 15Mbps
	option minRTT 'No'
	option description 'File/P2P'

# ========================= 上传规则 (egress) =========================
# 类别映射：
#   uclass_1: realtime
#   uclass_4: bulk
#   uclass_2: video
#   uclass_3: normal

# ---------- 实时流量 (realtime) ----------
config upload_rule 'upload_rule_1'  # DNS 查询 (小包实时)
    option enabled '1'
    option class 'uclass_1'
    option order '1'
    option family 'inet'
    option dstport '53,5353'
    option connbytes_kb '<=10'
    option proto 'udp'

config upload_rule 'upload_rule_2'  # 游戏/语音 (常见 UDP 端口)
    option enabled '1'
    option class 'uclass_1'
    option order '2'
    option family 'inet'
    option proto 'udp'
    option dstport '3074,3478-3480,3659,6000-7000,27015-27030,27960-27970'

config upload_rule 'upload_rule_3'  # VoIP/SIP
    option enabled '1'
    option class 'uclass_1'
    option order '3'
    option family 'inet'
    option proto 'udp'
    option dstport '5060-5061,10000-20000'

config upload_rule 'upload_rule_icmp'  # ICMP 实时（ping）
    option enabled '1'
    option class 'uclass_1'
    option order '4'
    option family 'inet'
    option proto 'icmp'
    option description 'ICMP ping'

config upload_rule 'upload_rule_ntp'  # NTP 时间同步
    option enabled '1'
    option class 'uclass_1'
    option order '5'
    option family 'inet'
    option proto 'udp'
    option dstport '123'
    option description 'NTP'

# ---------- 大流量/大文件 (bulk) ----------
config upload_rule 'upload_rule_7'  # HTTP/HTTPS 大文件上传（≥2MB）
    option enabled '1'
    option class 'uclass_4'
    option order '6'
    option family 'inet'
    option proto 'tcp'
    option dstport '80,443,8080'
    option connbytes_kb '>=2048'
    option description 'HTTP/HTTPS大流量上传'

config upload_rule 'upload_rule_6'  # FTP/SSH 大文件上传（≥2MB）
    option enabled '1'
    option class 'uclass_4'
    option order '7'
    option family 'inet'
    option proto 'tcp'
    option dstport '20,21,22'
    option connbytes_kb '>=2048'
    option description 'FTP/SSH大流量上传'

config upload_rule 'upload_rule_8'  # P2P 专用端口
    option enabled '1'
    option class 'uclass_4'
    option order '8'
    option family 'inet'
    option proto 'tcp_udp'
    option dstport '6881-6999,4662,4672,6346,6347,1214,6699,6882-6900,2710'
    option description 'P2P专用端口'

config upload_rule 'upload_rule_9'  # 非标准端口大流量 TCP (≥10MB)
    option enabled '1'
    option class 'uclass_4'
    option order '9'
    option family 'inet'
    option proto 'tcp'
    option dstport '1024-65535'
    option connbytes_kb '>=10240'
    option description '大流量TCP上传'

config upload_rule 'upload_rule_10'  # 非标准端口大流量 UDP (≥5MB)
    option enabled '1'
    option class 'uclass_4'
    option order '10'
    option family 'inet'
    option proto 'udp'
    option dstport '1024-65535'
    option connbytes_kb '>=5120'
    option description '大流量UDP上传'

# ---------- 视频数据流 (video) ----------
config upload_rule 'upload_video_2'  # 视频数据流（≥200KB 且 <2MB）
    option enabled '1'
    option class 'uclass_2'
    option order '11'
    option family 'inet'
    option proto 'tcp'
    option dstport '80,443,1935,1936,554,8554,8080,8081'
    option connbytes_kb '>=200'
    option description '视频数据流'

config upload_rule 'upload_video_quic'  # QUIC 视频（≥512KB）
    option enabled '1'
    option class 'uclass_2'
    option order '12'
    option family 'inet'
    option proto 'udp'
    option dstport '443,784,8853'
    option connbytes_kb '>=512'
    option description 'QUIC视频上传'

config upload_rule 'upload_video_1'  # 视频信令/小片段（≤200KB）
    option enabled '1'
    option class 'uclass_2'
    option order '13'
    option family 'inet'
    option proto 'tcp'
    option dstport '80,443,1935,1936,554,8554,8080,8081'
    option connbytes_kb '<=200'
    option description '视频信令/小片段'

# ---------- 普通流量 (normal) ----------
config upload_rule 'upload_rule_4'  # 小文件HTTPS (≤10KB)
    option enabled '1'
    option class 'uclass_3'
    option order '14'
    option family 'inet'
    option dstport '80,443,853'
    option connbytes_kb '<=10'
    option proto 'tcp'

config upload_rule 'upload_rule_5'  # 网页浏览中等流量（10-768KB）
    option enabled '1'
    option class 'uclass_3'
    option order '15'
    option family 'inet'
    option proto 'tcp'
    option dstport '80,443,8080'
    option connbytes_kb '10-768'

config upload_rule 'upload_rule_11'  # TCP 动态端口小流量 (≤256KB)
    option enabled '1'
    option class 'uclass_3'
    option order '16'
    option family 'inet'
    option proto 'tcp'
    option dstport '1024-10000,20000-65535'
    option connbytes_kb '<=256'
    option description 'TCP动态端口小流量'

config upload_rule 'upload_rule_12'  # UDP 动态端口（无大小限制）
    option enabled '1'
    option class 'uclass_3'
    option order '17'
    option family 'inet'
    option proto 'udp'
    option dstport '1024-10000,20000-65535'
    option description 'UDP动态端口'


# ========================= 下载规则 (ingress) =========================
# 与上传规则对称，端口匹配使用 srcport

# ---------- 实时流量 (realtime) ----------
config download_rule 'download_rule_1'  # DNS 响应
    option enabled '1'
    option class 'dclass_1'
    option order '1'
    option family 'inet'
    option srcport '53,5353'
    option connbytes_kb '<=10'
    option proto 'udp'

config download_rule 'download_rule_2'  # 游戏/语音 (常见 UDP 端口)
    option enabled '1'
    option class 'dclass_1'
    option order '2'
    option family 'inet'
    option proto 'udp'
    option srcport '3074,3478-3480,3659,6000-7000,27015-27030,27960-27970'

config download_rule 'download_rule_3'  # VoIP/SIP
    option enabled '1'
    option class 'dclass_1'
    option order '3'
    option family 'inet'
    option proto 'udp'
    option srcport '5060-5061,10000-20000'

config download_rule 'download_rule_icmp'  # ICMP 实时（ping）
    option enabled '1'
    option class 'dclass_1'
    option order '4'
    option family 'inet'
    option proto 'icmp'
    option description 'ICMP ping'

config download_rule 'download_rule_ntp'  # NTP 时间同步
    option enabled '1'
    option class 'dclass_1'
    option order '5'
    option family 'inet'
    option proto 'udp'
    option srcport '123'
    option description 'NTP'

# ---------- 大流量/大文件 (bulk) ----------
config download_rule 'download_rule_6'  # HTTP/HTTPS大文件下载（≥2MB）
    option enabled '1'
    option class 'dclass_4'
    option order '6'
    option family 'inet'
    option srcport '80,443,8080,20,21'
    option connbytes_kb '>=2048'
    option proto 'tcp'

config download_rule 'download_rule_7'  # P2P 专用端口
    option enabled '1'
    option class 'dclass_4'
    option order '7'
    option family 'inet'
    option proto 'tcp_udp'
    option srcport '6881-6999,4662,4672,6346,6347,1214,6699,6882-6900,2710'
    option description 'P2P专用端口'

config download_rule 'download_rule_8'  # 非标准端口大流量 TCP (≥10MB)
    option enabled '1'
    option class 'dclass_4'
    option order '8'
    option family 'inet'
    option proto 'tcp'
    option srcport '1024-65535'
    option connbytes_kb '>=10240'
    option description '大流量TCP下载'

config download_rule 'download_rule_9'  # 非标准端口大流量 UDP (≥5MB)
    option enabled '1'
    option class 'dclass_4'
    option order '9'
    option family 'inet'
    option proto 'udp'
    option srcport '1024-65535'
    option connbytes_kb '>=5120'
    option description '大流量UDP下载'

# ---------- 视频数据流 (video) ----------
config download_rule 'download_video_2'  # 视频数据流（≥200KB 且 <2MB）
    option enabled '1'
    option class 'dclass_2'
    option order '10'
    option family 'inet'
    option proto 'tcp'
    option srcport '80,443,1935,1936,554,8554,8080,8081'
    option connbytes_kb '>=200'
    option description '视频数据流（HTTP/RTMP/RTSP）'

config download_rule 'download_video_3'  # QUIC 视频（≥512KB）
    option enabled '1'
    option class 'dclass_2'
    option order '11'
    option family 'inet'
    option proto 'udp'
    option srcport '443,784,8853'
    option connbytes_kb '>=512'
    option description 'QUIC视频流'

config download_rule 'download_video_1'  # 视频信令/小片段（≤200KB）
    option enabled '1'
    option class 'dclass_2'
    option order '12'
    option family 'inet'
    option proto 'tcp'
    option srcport '80,443,1935,1936,554,8554,8080,8081'
    option connbytes_kb '<=200'
    option description '视频信令/小片段'

# ---------- 普通流量 (normal) ----------
config download_rule 'download_rule_4'  # 小文件HTTPS (≤10KB)
    option enabled '1'
    option class 'dclass_3'
    option order '13'
    option family 'inet'
    option srcport '443,853'
    option connbytes_kb '<=10'
    option proto 'tcp'

config download_rule 'download_rule_5'  # 网页浏览中等流量（10-768KB）
    option enabled '1'
    option class 'dclass_3'
    option order '14'
    option family 'inet'
    option proto 'tcp'
    option srcport '80,443,8080'
    option connbytes_kb '10-768'

config download_rule 'download_rule_10'  # TCP 动态端口小流量 (≤256KB)
    option enabled '1'
    option class 'dclass_3'
    option order '15'
    option family 'inet'
    option proto 'tcp'
    option srcport '1024-10000,20000-65535'
    option connbytes_kb '<=256'
    option description 'TCP动态端口小流量'

config download_rule 'download_rule_11'  # UDP 动态端口（无大小限制）
    option enabled '1'
    option class 'dclass_3'
    option order '16'
    option family 'inet'
    option proto 'udp'
    option srcport '1024-10000,20000-65535'
    option description 'UDP动态端口'

# ========================= 可选：游戏 TCP 端口补充（默认禁用） =========================
# config upload_rule 'upload_game_tcp'
#     option enabled '0'
#     option class 'uclass_1'
#     option order '6'
#     option family 'inet'
#     option proto 'tcp'
#     option dstport '25565,27015-27036'
#     option description '游戏TCP端口(Minecraft/Steam等)'

# config download_rule 'download_game_tcp'
#     option enabled '0'
#     option class 'dclass_1'
#     option order '6'
#     option family 'inet'
#     option proto 'tcp'
#     option srcport '25565,27015-27036'
#     option description '游戏TCP端口(Minecraft/Steam等)'