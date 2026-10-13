#!/usr/bin/env bash
# ==============================================================================
# opsbox :: tests/fixtures/build.sh
# 生成用于测试的「假操作系统」。
#
# 为什么需要它：
#   opsbox 的采集层全部通过 $OB_CFG_*_ROOT 变量定位 /proc、/etc 等路径，
#   因此可以用一个普通目录模拟出一台服务器的全部关键文件。这样一来：
#     1. 在 macOS / Windows(Git Bash) / CI 容器里都能完整测试 Linux 逻辑；
#     2. 可以精确构造「内存只剩 200MB」「根分区 92%」这类极端场景，
#        这在真实机器上很难复现，更不可能在 CI 里复现。
#
# 用法： build.sh <目标目录> [healthy|troubled]
# ==============================================================================

set -u

FIX_ROOT="${1:-}"
SCENARIO="${2:-healthy}"

if [ -z "$FIX_ROOT" ]; then
    printf '用法：%s <目标目录> [healthy|troubled]\n' "$0" >&2
    exit 2
fi

case "$SCENARIO" in
    healthy|troubled) ;;
    *) printf '未知场景：%s（可用：healthy troubled）\n' "$SCENARIO" >&2; exit 2 ;;
esac

rm -rf "$FIX_ROOT"
mkdir -p "$FIX_ROOT"/proc/net \
         "$FIX_ROOT"/proc/sys/fs \
         "$FIX_ROOT"/proc/sys/kernel \
         "$FIX_ROOT"/proc/sys/vm \
         "$FIX_ROOT"/proc/sys/net/ipv4 \
         "$FIX_ROOT"/proc/sys/net/netfilter \
         "$FIX_ROOT"/sys/block/sda \
         "$FIX_ROOT"/sys/block/sdb \
         "$FIX_ROOT"/sys/kernel/security/apparmor \
         "$FIX_ROOT"/etc/ssh \
         "$FIX_ROOT"/var/log \
         "$FIX_ROOT"/run \
         "$FIX_ROOT"/bin

# 写一个两行文件的便捷函数
w() { # w <path> <content>
    printf '%s\n' "$2" > "$1"
}

# 进程 status/stat 文件的生成器
proc_status() { # proc_status <pid> <name> <rss_kb> <state>
    local pid="$1" name="$2" rss="$3" state="$4"
    mkdir -p "$FIX_ROOT/proc/$pid"
    cat > "$FIX_ROOT/proc/$pid/status" <<EOF
Name:	$name
Umask:	0022
State:	$state (running)
Tgid:	$pid
Pid:	$pid
PPid:	1
VmPeak:	  512000 kB
VmSize:	  480000 kB
VmRSS:	  $rss kB
Threads:	4
EOF
    printf '%s (%s) %s 1 1 0 -1 4194304 100 0 0 0 10 5 0 0 20 0 4 0 100 200 0\n' \
        "$pid" "$name" "$state" > "$FIX_ROOT/proc/$pid/stat"
}

# ---------------------------------------------------------------- 场景差异 ----
if [ "$SCENARIO" = "healthy" ]; then
    LOADAVG="0.42 0.51 0.55 1/212 8842"
    MEM_TOTAL=16384000
    MEM_AVAIL=11264000
    MEM_FREE=6144000
    SWAP_TOTAL=4194304
    SWAP_FREE=4194304
    DISK_ROOT_PCT=46
    DISK_ROOT_AVAIL=26948403
    INODE_PCT=12
    DISK_LAT_MS="1.80"
    NET_RX_ERRS=0
    NET_RX_DROPS=0
    TCP_ROWS_NORMAL=1
    CONNTRACK_COUNT=410
    FILE_NR_USED=1600
    FD_MAX=9223372036854775807
else
    LOADAVG="9.87 8.55 7.12 14/412 31022"
    MEM_TOTAL=16384000
    MEM_AVAIL=614400          # 只剩 600MB，使用率约 96%
    MEM_FREE=102400
    SWAP_TOTAL=4194304
    SWAP_FREE=419430          # swap 用了 90%
    DISK_ROOT_PCT=92
    DISK_ROOT_AVAIL=2097152
    INODE_PCT=95
    DISK_LAT_MS="142.50"
    NET_RX_ERRS=8123
    NET_RX_DROPS=44120
    TCP_ROWS_NORMAL=1
    CONNTRACK_COUNT=249000
    FILE_NR_USED=820000
    FD_MAX=1000000
fi

# ---------------------------------------------------------------- /proc/stat ----
# 采样两次会得到不同的值，因此这里写入一个「会变化」的快照有点麻烦；
# 做法是让第一次采样读到 A、第二次读到 B。测试时通过两次 build 不现实，
# 因此这里让 /proc/stat 由脚本动态生成（见下方 mock）。
cat > "$FIX_ROOT/proc/stat" <<EOF
cpu  120000 3400 45000 9000000 12000 0 700 300 0 0
cpu0 30000 850 11250 2250000 3000 0 175 75 0 0
cpu1 30000 850 11250 2250000 3000 0 175 75 0 0
cpu2 30000 850 11250 2250000 3000 0 175 75 0 0
cpu3 30000 850 11250 2250000 3000 0 175 75 0 0
intr 88421304 12 0 0 0 0 0 0 0 0 0 0 0 0 0
ctxt 214884213
btime 1700000000
processes 884213
procs_running 3
procs_blocked 1
EOF

w "$FIX_ROOT/proc/loadavg" "$LOADAVG"
w "$FIX_ROOT/proc/uptime" "3628800.42 14400000.00"

cat > "$FIX_ROOT/proc/cpuinfo" <<'EOF'
processor	: 0
vendor_id	: GenuineIntel
cpu family	: 6
model		: 85
model name	: Intel(R) Xeon(R) Platinum 8269CY CPU @ 2.50GHz
physical id	: 0
siblings	: 4
cpu cores	: 4
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep

processor	: 1
vendor_id	: GenuineIntel
cpu family	: 6
model		: 85
model name	: Intel(R) Xeon(R) Platinum 8269CY CPU @ 2.50GHz
physical id	: 0
siblings	: 4
cpu cores	: 4
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep

processor	: 2
vendor_id	: GenuineIntel
cpu family	: 6
model		: 85
model name	: Intel(R) Xeon(R) Platinum 8269CY CPU @ 2.50GHz
physical id	: 0
siblings	: 4
cpu cores	: 4
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep

processor	: 3
vendor_id	: GenuineIntel
cpu family	: 6
model		: 85
model name	: Intel(R) Xeon(R) Platinum 8269CY CPU @ 2.50GHz
physical id	: 0
siblings	: 4
cpu cores	: 4
flags		: fpu vme de pse tsc msr pae mce cx8 apic sep
EOF

w "$FIX_ROOT/proc/meminfo" "$(cat <<EOF
MemTotal:       $MEM_TOTAL kB
MemFree:        $MEM_FREE kB
MemAvailable:   $MEM_AVAIL kB
Buffers:          380000 kB
Cached:          3200000 kB
SwapCached:            0 kB
Dirty:             $([ "$SCENARIO" = "troubled" ] && printf '1843200' || printf '2048') kB
Writeback:         $([ "$SCENARIO" = "troubled" ] && printf '25600' || printf '0') kB
SwapTotal:      $SWAP_TOTAL kB
SwapFree:       $SWAP_FREE kB
CommitLimit:    12378112 kB
Committed_AS:   $([ "$SCENARIO" = "troubled" ] && printf '11800000' || printf '3200000') kB
EOF
)"

# /proc/mounts
if [ "$SCENARIO" = "healthy" ]; then
cat > "$FIX_ROOT/proc/mounts" <<'EOF'
/dev/sda1 / ext4 rw,relatime,errors=remount-ro 0 0
/dev/sdb1 /data xfs rw,relatime,attr2,inode64,noquota 0 0
tmpfs /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1638400k 0 0
/dev/sda15 /boot/efi vfat rw,relatime,fmask=0077,dmask=0077 0 0
EOF
else
cat > "$FIX_ROOT/proc/mounts" <<'EOF'
/dev/sda1 / ext4 ro,relatime,errors=remount-ro 0 0
/dev/sdb1 /data xfs rw,relatime,attr2,inode64,noquota 0 0
tmpfs /run tmpfs rw,nosuid,nodev,noexec,relatime,size=1638400k 0 0
/dev/sda15 /boot/efi vfat rw,relatime,fmask=0077,dmask=0077 0 0
EOF
fi

# /proc/diskstats
# 字段：major minor name reads_completed reads_merged sectors_read ms_reading
#       writes_completed writes_merged sectors_written ms_writing ios_in_progress ms_io weighted_ms_io
cat > "$FIX_ROOT/proc/diskstats" <<EOF
   8       0 sda 1200000 40000 84000000 900000 900000 30000 46000000 700000 0 1400000 1600000
   8       1 sda1 1100000 38000 82000000 880000 880000 29000 44000000 680000 0 1360000 1560000
   8      16 sdb 400000 12000 26000000 200000 300000 8000 15000000 180000 0 340000 380000
   7       0 loop0 100 0 800 20 0 0 0 0 0 20 20
EOF

# /proc/net/dev
cat > "$FIX_ROOT/proc/net/dev" <<EOF
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 88213400  412000    0    0    0     0          0         0 88213400  412000    0    0    0     0       0          0
  eth0: 9182736450 18400000 $NET_RX_ERRS $NET_RX_DROPS 0 0 0 0 4182736450 16400000 12 0 0 0 0 0
EOF

# /proc/net/tcp
# 十六进制 state：01=ESTABLISHED 06=TIME_WAIT 08=CLOSE_WAIT 0A=LISTEN
if [ "$SCENARIO" = "healthy" ]; then
cat > "$FIX_ROOT/proc/net/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 21000 1 0000000000000000 100 0 0 10 0
   1: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 21001 1 0000000000000000 100 0 0 10 0
   2: 0A00010A:9C40 0A00020A:1F90 01 00000000:00000000 00:00000000 00000000     0        0 21002 1 0000000000000000 20 4 30 10 -1
   3: 0A00010A:B1A2 0A00030A:0050 06 00000000:00000000 00:00000000 00000000     0        0 21003 1 0000000000000000 20 4 30 10 -1
EOF
else
{
printf '  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n'
printf '   0: 00000000:0016 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 21000 1 0000000000000000 100 0 0 10 0\n'
# 300 条 TIME_WAIT
i=1
while [ "$i" -le 300 ]; do
    printf '  %3d: 0A00010A:%04X 0A00020A:1F90 06 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 20 4 30 10 -1\n' \
        "$i" $((40000 + i)) $((30000 + i))
    i=$((i + 1))
done
# 120 条 CLOSE_WAIT
i=1
while [ "$i" -le 120 ]; do
    printf '  %3d: 0A00010A:%04X 0A00030A:0050 08 00000000:00000000 00:00000000 00000000     0        0 %d 1 0000000000000000 20 4 30 10 -1\n' \
        "$((300 + i))" $((50000 + i)) $((40000 + i))
    i=$((i + 1))
done
} > "$FIX_ROOT/proc/net/tcp"
fi

printf '  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n' \
    > "$FIX_ROOT/proc/net/tcp6"

cat > "$FIX_ROOT/proc/net/sockstat" <<EOF
sockets: used 812
TCP: inuse 412 orphan 3 tw 302 alloc 512 mem 18
UDP: inuse 12 mem 3
UDPLITE: inuse 0
RAW: inuse 0
FRAG: inuse 0 memory 0
EOF

# /proc/sys
w "$FIX_ROOT/proc/sys/fs/file-nr" "$FILE_NR_USED	0	$FD_MAX"
w "$FIX_ROOT/proc/sys/kernel/pid_max" "4194304"
w "$FIX_ROOT/proc/sys/vm/swappiness" "$([ "$SCENARIO" = "troubled" ] && printf '60' || printf '10')"
w "$FIX_ROOT/proc/sys/vm/overcommit_memory" "0"
w "$FIX_ROOT/proc/sys/net/ipv4/ip_forward" "$([ "$SCENARIO" = "troubled" ] && printf '1' || printf '0')"
w "$FIX_ROOT/proc/sys/net/netfilter/nf_conntrack_count" "$CONNTRACK_COUNT"
w "$FIX_ROOT/proc/sys/net/netfilter/nf_conntrack_max" "262144"

# ---------------------------------------------------------------- 进程 ----
proc_status 1 "systemd" 18432 "S"
proc_status 812 "sshd" 9216 "S"
proc_status 913 "nginx" 262144 "S"
proc_status 914 "mysqld" 4194304 "S"
proc_status 915 "redis-server" 1048576 "S"
proc_status 990 "node" 2097152 "S"
if [ "$SCENARIO" = "troubled" ]; then
    proc_status 991 "java" 6291456 "S"
    proc_status 992 "defunct-worker" 0 "Z"
    proc_status 993 "defunct-worker2" 0 "Z"
fi

# ---------------------------------------------------------------- /etc ----
cat > "$FIX_ROOT/etc/os-release" <<'EOF'
NAME="Ubuntu"
VERSION="22.04.3 LTS (Jammy Jellyfish)"
ID=ubuntu
ID_LIKE=debian
PRETTY_NAME="Ubuntu 22.04.3 LTS"
VERSION_ID="22.04"
EOF

if [ "$SCENARIO" = "healthy" ]; then
cat > "$FIX_ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
deploy:x:1000:1000:deploy:/home/deploy:/bin/bash
EOF
cat > "$FIX_ROOT/etc/shadow" <<'EOF'
root:$6$abcdefgh$0123456789abcdefghijklmnopqrstuvwxyz.:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
deploy:$6$zyxwvuts$abcdefghijklmnopqrstuvwxyz0123456789.:19100:0:99999:7:::
EOF
cat > "$FIX_ROOT/etc/ssh/sshd_config" <<'EOF'
Port 22
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
X11Forwarding no
EOF
else
cat > "$FIX_ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/sbin/nologin
bin:x:2:2:bin:/bin:/usr/sbin/nologin
sys:x:3:3:sys:/dev:/usr/sbin/nologin
backup:x:0:0:backup:/var/backups:/bin/bash
www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin
deploy:x:1000:1000:deploy:/home/deploy:/bin/bash
EOF
cat > "$FIX_ROOT/etc/shadow" <<'EOF'
root:$6$abcdefgh$0123456789abcdefghijklmnopqrstuvwxyz.:19000:0:99999:7:::
daemon:*:19000:0:99999:7:::
legacy::19100:0:99999:7:::
deploy:$6$zyxwvuts$abcdefghijklmnopqrstuvwxyz0123456789.:19100:0:99999:7:::
EOF
cat > "$FIX_ROOT/etc/ssh/sshd_config" <<'EOF'
Port 22
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
X11Forwarding yes
EOF
fi

# ---------------------------------------------------------------- 日志 ----
if [ "$SCENARIO" = "healthy" ]; then
cat > "$FIX_ROOT/var/log/syslog" <<'EOF'
Jan  1 10:00:01 web-01 systemd[1]: Started Daily apt download activities.
Jan  1 10:00:05 web-01 kernel: [12345.678] eth0: link up
Jan  1 10:01:00 web-01 CRON[1234]: (root) CMD (/usr/local/bin/opsbox check -q)
EOF
else
{
    i=1
    while [ "$i" -le 40 ]; do
        printf 'Jan  1 10:%02d:00 web-01 kernel: [12345.678] EXT4-fs error (device sda1): ext4_find_entry:1455: inode #2: comm nginx: reading directory lblock 0\n' "$((i % 60))"
        i=$((i + 1))
    done
    i=1
    while [ "$i" -le 15 ]; do
        printf 'Jan  1 11:%02d:00 web-01 mysqld[914]: [ERROR] Connection refused to 10.1.2.%d:5432 (attempt %d)\n' "$((i % 60))" "$i" "$i"
        i=$((i + 1))
    done
    printf 'Jan  1 12:00:00 web-01 kernel: Out of memory: Killed process 991 (java) total-vm:8192000kB\n'
    printf 'Jan  1 12:00:01 web-01 kernel: oom-killer: gfp_mask=0x100cca(GFP_HIGHUSER_MOVABLE)\n'
} > "$FIX_ROOT/var/log/syslog"
fi

printf 'this is a big application log\n' > "$FIX_ROOT/var/log/app.log"

# ---------------------------------------------------------------- Mock 命令 ----
# mock df：模拟 df -P -k 与 df -P -k -i 的输出
# 注意内层 heredoc 故意不加引号：外层 heredoc 在生成时就把 ${...} 展开成具体的
# 百分比数字，写进文件后内层只剩下纯文本，不会再有变量需要展开。
cat > "$FIX_ROOT/bin/df" <<EOF
#!/usr/bin/env bash
for arg in "\$@"; do
    if [ "\$arg" = "-i" ]; then
        cat <<INODES
Filesystem      Inodes  IUsed   IFree IUse% Mounted on
/dev/sda1      6553600 786432 5767168    ${INODE_PCT}% /
/dev/sdb1     26214400 524288 25690112    2% /data
INODES
        exit 0
    fi
done
cat <<BLOCKS
Filesystem     1024-blocks      Used Available Capacity Mounted on
/dev/sda1         41020672  17672269  $DISK_ROOT_AVAIL   ${DISK_ROOT_PCT}% /
/dev/sdb1        209715200  41943040 167772160      20% /data
BLOCKS
exit 0
EOF
chmod +x "$FIX_ROOT/bin/df"

# mock systemctl：healthy 无失败单元，troubled 有两个
cat > "$FIX_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash

# opsbox 的调用形式是 `systemctl --no-legend --no-pager --plain list-units --state=failed`，
# 子命令不一定落在 $1，因此必须遍历全部参数来识别。
for a in "$@"; do
    if [ "$a" = "list-units" ]; then
        if [ -f "$OPSBOX_FIXTURE_MARKER" ]; then
            printf 'nginx.service  loaded failed failed A high performance web server and a reverse proxy server\n'
            printf 'backup.service loaded failed failed Daily backup job\n'
        fi
        exit 0
    fi
done

cmd="${1:-}"
case "$cmd" in
    is-active)
        unit="${2:-}"
        case "$unit" in
            sshd.service|ssh.service|cron.service|crond.service) printf 'active\n'; exit 0 ;;
            nginx.service) printf 'active\n'; exit 0 ;;
            docker.service) printf 'inactive\n'; exit 3 ;;
            *) printf 'unknown\n'; exit 4 ;;
        esac
        ;;
    is-enabled)
        printf 'enabled\n'; exit 0 ;;
    show)
        printf 'NTP=yes\nNTPSynchronized=yes\n'
        exit 0
        ;;
    --version)
        printf 'systemd 249 (249.11-0ubuntu3.12)\n'
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$FIX_ROOT/bin/systemctl"

# mock journalctl：troubled 场景下返回 61 条错误日志（触发 WARN），healthy 返回空
cat > "$FIX_ROOT/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
if [ -f "$OPSBOX_FIXTURE_MARKER" ]; then
    i=1
    while [ "$i" -le 40 ]; do
        printf 'EXT4-fs error (device sda1): ext4_find_entry:1455: inode #2: comm nginx\n'
        i=$((i + 1))
    done
    i=1
    while [ "$i" -le 20 ]; do
        printf 'Connection refused to 10.1.2.%d:5432 (attempt %d)\n' "$i" "$i"
        i=$((i + 1))
    done
    printf 'Out of memory: Killed process 991 (java) total-vm:8192000kB\n'
fi
exit 0
EOF
chmod +x "$FIX_ROOT/bin/journalctl"

# mock timedatectl：时间同步正常
cat > "$FIX_ROOT/bin/timedatectl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "show" ]; then
    printf 'NTP=yes\nNTPSynchronized=yes\n'
fi
exit 0
EOF
chmod +x "$FIX_ROOT/bin/timedatectl"

# mock ufw：healthy 已启用，troubled 未启用
cat > "$FIX_ROOT/bin/ufw" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "status" ]; then
    if [ -f "$OPSBOX_FIXTURE_MARKER" ]; then
        printf 'Status: inactive\n'
    else
        printf 'Status: active\n'
    fi
fi
exit 0
EOF
chmod +x "$FIX_ROOT/bin/ufw"

# 用 marker 文件切换 mock 行为（比重新生成脚本简单）
if [ "$SCENARIO" = "troubled" ]; then
    : > "$FIX_ROOT/run/troubled.marker"
fi

printf '夹具已生成：%s（场景：%s）\n' "$FIX_ROOT" "$SCENARIO"
