#ifndef QOS_DBA_H
#define QOS_DBA_H

#include "config_parser.h"

// 这里可以添加DBA算法相关的函数声明
int qos_dba_init(void);
int qos_dba_run(void);
void qos_dba_stop(void);
int qos_dba_adjust_bandwidth(void);
int get_class_bandwidth_stats(const char *classid, int is_upload, 
                              int *min_bw, int *max_bw, int *cur_bw, int *used_bw);
int update_bandwidth_usage(const char *classid, int is_upload, int used_kbps);
void qos_dba_set_total_bandwidth(int upload_kbps, int download_kbps);

#endif /* QOS_DBA_H */