#!/usr/bin/env bash
# ==============================================================================
# opsbox :: modules/40-disk.sh
# 磁盘与 inode：容量水位、inode 水位、意外只读挂载、IO 延迟、日志体积
#
# 这是运维事故里出现频率最高的一块。三个最容易踩的坑：
#   1. 只看容量不看 inode —— 小文件海把 inode 吃光，df -h 显示还有空间却写不进去。
#   2. 只看总量不看增速 —— 85% 如果一天涨 10% 比 95% 不动更危险。
#   3. 根分区变只读 —— 这已经是硬件/文件系统级故障，不是「空间不够」。
# ==============================================================================

# 列出需要纳入检查的挂载点： "use_pct total_kb used_kb avail_kb mountpoint fstype"
ob_disk_candidates() {
    local df_out mounts
    df_out="$(ob_collect_df 2>/dev/null)" || return 1
    [ -n "$df_out" ] || return 1
    mounts="$(ob_mount_fstypes 2>/dev/null || true)"

    printf '%s\n' "$df_out" | LC_ALL=C awk \
        -v exfs="$OB_CFG_DISK_EXCLUDE_FS" \
        -v exmnt="$OB_CFG_DISK_EXCLUDE_MNT" \
        -v minsz="$OB_CFG_DISK_MIN_SIZE_MB" \
        -v mounts="$mounts" '
        BEGIN {
            n = split(mounts, arr, "\n")
            for (i = 1; i <= n; i++) {
                split(arr[i], kv, " ")
                if (kv[1] != "") fs[kv[1]] = kv[2]
            }
            ne = split(exmnt, ea, "|")
        }
        {
            mnt = $5
            fstype = fs[mnt]
            if (fstype == "") fstype = "unknown"

            if (exfs != "" && fstype ~ "^(" exfs ")$") next

            skip = 0
            for (i = 1; i <= ne; i++) {
                if (ea[i] == "") continue
                if (mnt == ea[i]) { skip = 1; break }
                if (index(mnt, ea[i] "/") == 1) { skip = 1; break }
            }
            if (skip) next

            # 太小的挂载点（如 /boot/efi）不告警，纯噪音
            if ($2 + 0 < minsz * 1024) next

            printf "%s %s %s %s %s %s\n", $1, $2, $3, $4, mnt, fstype
        }
    '
}

# 意外的只读挂载（文件系统进入只读保护模式）
#
# 关键点：只读介质上的挂载（光盘、squashfs 镜像、EFI 分区）本来就是 ro，
# 对它们告警是纯噪音，会让人开始忽略这条检查。因此这里单独用
# OB_CFG_DISK_READONLY_EXCLUDE_FS 过滤只读介质类型，而不是复用容量检查的
# EXCLUDE_FS——后者参与容量水位统计，两者关注的维度不同。
ob_readonly_mounts() {
    local f="${OB_CFG_PROC_ROOT}/mounts"
    [ -r "$f" ] || return 1
    LC_ALL=C awk \
        -v exfs="$OB_CFG_DISK_EXCLUDE_FS" \
        -v roexfs="${OB_CFG_DISK_READONLY_EXCLUDE_FS:-}" \
        -v exmnt="$OB_CFG_DISK_EXCLUDE_MNT" '
        BEGIN { ne = split(exmnt, ea, "|") }
        {
            mnt = $2; fstype = $3; opts = $4
            if (fstype ~ "^(" exfs ")$") next
            if (roexfs != "" && fstype ~ "^(" roexfs ")$") next
            if (opts !~ /(^|,)ro(,|$)/) next
            skip = 0
            for (i = 1; i <= ne; i++) {
                if (ea[i] == "") continue
                if (mnt == ea[i]) { skip = 1; break }
                if (index(mnt, ea[i] "/") == 1) { skip = 1; break }
            }
            if (skip) next
            print mnt
        }
    ' "$f" 2>/dev/null
}

# /proc/diskstats 快照： "sectors ms_io completed_ops"
ob_diskstats_snapshot() {
    local f="${OB_CFG_PROC_ROOT}/diskstats"
    [ -r "$f" ] || return 1
    local disks
    disks="$(ob_whole_disks 2>/dev/null || true)"
    LC_ALL=C awk -v disks="$disks" '
        BEGIN {
            n = split(disks, a, "\n")
            for (i = 1; i <= n; i++) if (a[i] != "") keep[a[i]] = 1
            have_filter = (n > 0 && a[1] != "")
        }
        {
            name = $3
            if (have_filter && !(name in keep)) next
            sectors += $6 + $10    # sectors read + written
            ioms    += $13         # ms spent doing I/O
            ops     += $4 + $8     # reads completed + writes completed
        }
        END { printf "%s %s %s", sectors + 0, ioms + 0, ops + 0 }
    ' "$f" 2>/dev/null
}

# 整盘设备名单（来自 /sys/block），用于把分区从 diskstats 统计中剔除
ob_whole_disks() {
    local d
    if [ -d "${OB_CFG_SYS_ROOT}/block" ]; then
        for d in "${OB_CFG_SYS_ROOT}"/block/*; do
            [ -d "$d" ] || [ -e "$d" ] || continue
            printf '%s\n' "${d##*/}"
        done
    fi
    return 0
}

ob_module_disk() {
    OB_MODULE="disk"

    # ---------------------------------------------------------- 容量水位 ----
    local cands
    cands="$(ob_disk_candidates 2>/dev/null || true)"

    if [ -z "$cands" ]; then
        ob_unknown "disk.usage" "分区使用率" "未采集到可用挂载点" "低于 ${OB_CFG_DISK_WARN}%" \
            "df 不可用或所有挂载点都被排除规则过滤了，请检查 OB_CFG_DISK_EXCLUDE_FS / OB_CFG_DISK_EXCLUDE_MNT 与 OB_CFG_DISK_MIN_SIZE_MB"
    else
        local usage_lines="" detail_lines=""
        local pct total used avail mnt fstype

        while IFS=' ' read -r pct total used avail mnt fstype; do
            [ -n "$mnt" ] || continue
            usage_lines="${usage_lines}$(ob_slug "$mnt") $pct ${mnt}
"
            detail_lines="${detail_lines}${mnt}|$(ob_human_bytes "$((total * 1024))")|$(ob_human_bytes "$((avail * 1024))")|${fstype}
"
        done <<<"$cands"

        ob_check_series "disk.usage" "分区使用率" "$usage_lines" \
            "$OB_CFG_DISK_WARN" "$OB_CFG_DISK_CRIT" "%" \
            "先定位占用：du -x -h --max-depth=1 <挂载点> | sort -h，再查已删除但未释放的文件（lsof +L1）。若是日志型分区，优先配置 logrotate 压缩与保留策略，而不是临时删文件"

        # 把每个分区的容量明细作为一条信息项，方便事后复盘
        local mnt2 size avail2 fs2
        while IFS='|' read -r mnt2 size avail2 fs2; do
            [ -n "$mnt2" ] || continue
            ob_ok "disk.detail.$(ob_slug "$mnt2")" "分区容量 ${mnt2}" \
                "已用 $(printf '%s' "$size") · 可用 $(printf '%s' "$avail2") · ${fs2}" "—" "-"
        done <<<"$detail_lines"
    fi

    # ---------------------------------------------------------- inode ----
    local inodes
    inodes="$(ob_collect_df_inode 2>/dev/null || true)"
    if [ -n "$inodes" ]; then
        local inode_lines=""
        local ipct iused ifree imnt
        while IFS=' ' read -r ipct iused ifree imnt; do
            [ -n "$imnt" ] || continue
            # 只保留容量检查里认可的挂载点，避免虚拟文件系统产生噪音
            case "$imnt" in
                /dev|/proc|/sys|/run|/sys/*|/proc/*|/dev/*|/run/*|/snap*) continue ;;
            esac
            inode_lines="${inode_lines}$(ob_slug "$imnt") $ipct ${imnt}
"
        done <<<"$inodes"

        if [ -n "$inode_lines" ]; then
            ob_check_series "disk.inode" "inode 使用率" "$inode_lines" \
                "$OB_CFG_INODE_WARN" "$OB_CFG_INODE_CRIT" "%" \
                "inode 耗尽时 df -h 显示还有空间但无法创建新文件（No space left on device）。定位：df -i 找分区，再 find <挂载点> -xdev -printf '%h\n' | sort | uniq -c | sort -rn | head 找海量小文件目录"
        fi
    fi

    # ---------------------------------------------------------- 只读挂载 ----
    # 注意：必须区分「读不到 /proc/mounts」和「确实没有只读挂载」。
    # 把采集失败当成 OK 是这类巡检工具最危险的错误——它会给出虚假的安心。
    local ro ro_rc=0
    ro="$(ob_readonly_mounts 2>/dev/null)" || ro_rc=$?
    if [ "$ro_rc" -ne 0 ]; then
        ob_unknown "disk.readonly" "只读挂载的文件系统" "无法读取 mounts" "无" \
            "确认 OB_CFG_PROC_ROOT 下存在 mounts 文件；容器内需要挂载宿主的 /proc 才能看到真实挂载表"
    elif [ -n "$ro" ]; then
        ob_crit "disk.readonly" "只读挂载的文件系统" "$(ob_flatten "$ro")" "除只读介质外不应出现 ro" \
            "真实文件系统被挂成只读，通常是文件系统检测到错误后的自我保护，或云盘/硬件故障。请立刻 dmesg -T | tail -50 查看 IO 报错，并做好数据备份后再尝试 remount,rw。若这是刻意配置的只读挂载，把它加进 OB_CFG_DISK_EXCLUDE_MNT 或 OB_CFG_DISK_READONLY_EXCLUDE_FS 以消除误报"
    else
        ob_ok "disk.readonly" "只读挂载的文件系统" "无可疑只读挂载" "无" "-"
    fi

    # ---------------------------------------------------------- IO 延迟 ----
    local snap1 snap2
    snap1="$(ob_diskstats_snapshot 2>/dev/null || true)"
    if [ -n "$snap1" ]; then
        local iv="${OB_CFG_SAMPLE_INTERVAL:-1}"
        ob_is_num "$iv" && [ "$iv" != "0" ] && sleep "$iv"
        snap2="$(ob_diskstats_snapshot 2>/dev/null || true)"

        if [ -n "$snap2" ]; then
            local s1 m1 o1 s2 m2 o2
            set -- $snap1; s1="$1"; m1="$2"; o1="$3"
            set -- $snap2; s2="$1"; m2="$2"; o2="$3"

            local latency throughput_mbs
            latency="$(LC_ALL=C awk -v m1="$m1" -v o1="$o1" -v m2="$m2" -v o2="$o2" 'BEGIN {
                do_ = o2 - o1; dm = m2 - m1
                if (do_ <= 0) { printf ""; exit }
                printf "%.2f", dm / do_
            }')"
            throughput_mbs="$(LC_ALL=C awk -v s1="$s1" -v s2="$s2" -v iv="${OB_CFG_SAMPLE_INTERVAL:-1}" 'BEGIN {
                ds = s2 - s1
                if (iv <= 0) { printf "0.00"; exit }
                printf "%.2f", ds * 512 / 1048576 / iv
            }')"

            if [ -n "$latency" ]; then
                ob_check_threshold "disk.io_latency" "磁盘平均 IO 延迟" "$latency" \
                    "${OB_CFG_DISK_LAT_WARN:-20}" "${OB_CFG_DISK_LAT_CRIT:-100}" high " ms" \
                    "平均每次 IO 耗时 ${latency}ms（吞吐约 ${throughput_mbs} MB/s）。云盘环境常见原因是 IOPS/带宽突发额度耗尽或配额被打满，可用 fio 做基准对比，并检查是否有进程在做全表扫描/大文件拷贝"
                ob_ok "disk.io_throughput" "磁盘吞吐（采样 ${OB_CFG_SAMPLE_INTERVAL:-1}s）" "${throughput_mbs} MB/s" "—" "-"
            else
                ob_ok "disk.io_latency" "磁盘平均 IO 延迟" "窗口内无 IO 活动" "低于 ${OB_CFG_DISK_LAT_WARN:-20}ms" "-"
            fi
        fi
    else
        ob_unknown "disk.io_latency" "磁盘平均 IO 延迟" "无法读取 /proc/diskstats" "低于 ${OB_CFG_DISK_LAT_WARN:-20}ms" \
            "确认 /proc/diskstats 可读；容器内通常看不到宿主磁盘统计"
    fi

    # ---------------------------------------------------------- 大日志 ----
    local biglogs biggest biggest_mb biggest_path
    biglogs="$(ob_big_log_files 1 2>/dev/null || true)"
    if [ -n "$biglogs" ]; then
        set -- $biglogs
        biggest="${1:-0}"
        biggest_path="$(printf '%s' "$biglogs" | LC_ALL=C awk '{ print $2 }')"
        biggest_mb=$((biggest / 1024))
        ob_check_threshold "disk.big_log" "最大日志文件体积" "$biggest_mb" \
            "${OB_CFG_LOG_BIG_MB_WARN:-512}" "${OB_CFG_LOG_BIG_MB_CRIT:-2048}" high " MB" \
            "${biggest_path} 已达 ${biggest_mb}MB。单个日志文件过大既占空间又让排查变慢，请检查 logrotate 配置是否存在、路径是否被覆盖、以及进程是否没收到 reopen 信号"
    else
        ob_unknown "disk.big_log" "最大日志文件体积" "未找到日志文件" "低于 ${OB_CFG_LOG_BIG_MB_WARN:-512}MB" \
            "确认 OB_CFG_VAR_ROOT 指向的日志目录存在，或忽略此项"
    fi

    return 0
}
