#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# install-android.sh - 安卓 Termux 一键安装 (菲律宾 MNL 优选自动化)
# 做什么:
#   1) 装依赖 (cronie 定时器 / git / curl / tar)
#   2) 按手机架构自动下载官方 cfst v2.3.5 对应包并解压到 ~/cfst-android
#   3) 写入测速脚本 cfst-ph.sh (与路由器版同一套已验证逻辑)
#   4) 注册每天 4 次的定时任务 (01:30 / 07:30 / 13:30 / 19:30, 手机本地时间)
#   5) 启动 crond, 写好 Termux:Boot 开机自启脚本 (装了 Boot 才生效)
#   6) 最后立即手动跑一轮, 现场验证能出名单
# 用法: 在 Termux 里执行  bash install-android.sh
# 不需要 root。全程只动 Termux 自己的目录。
# ============================================================
set -u

WORK="$HOME/cfst-android"
say() { echo "[安装] $1"; }

# ---------- 0. 环境检查 ----------
if [ -z "${PREFIX:-}" ] || [ ! -d "$PREFIX/bin" ]; then
    echo "警告: 好像不在 Termux 里运行 (找不到 \$PREFIX)。请在 Termux App 里执行本脚本。"
fi
mkdir -p "$WORK/logs" "$WORK/results"

# 唤醒锁 (装了 Termux:API 才有这条命令, 没有就跳过)
if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock
    say "已申请唤醒锁 (termux-wake-lock)。"
fi

# ---------- 1. 依赖 ----------
say "先把系统包整体升级到一致版本 (只升一半会让 curl 的库对不上、直接崩溃), 再安装依赖 (cronie / git / curl / tar), 可能要等几分钟..."
pkg update -y >/dev/null 2>&1
pkg upgrade -y || { echo "系统包整体升级失败, 检查网络后重跑本脚本。"; exit 1; }
pkg install -y cronie git curl tar || { echo "依赖安装失败, 检查网络后重跑本脚本。"; exit 1; }

# ---------- 2. 按架构下载 cfst ----------
ARCH=$(uname -m)
case "$ARCH" in
    aarch64|arm64)   PKG=arm64 ;;
    armv7l|armv8l)   PKG=armv7 ;;
    armv6l)          PKG=armv6 ;;
    armv5l)          PKG=armv5 ;;
    *) echo "暂不支持的架构: $ARCH (把这一行发给李元芳看)"; exit 1 ;;
esac
URL="https://github.com/XIU2/CloudflareSpeedTest/releases/download/v2.3.5/cfst_linux_${PKG}.tar.gz"
say "手机架构 $ARCH -> 下载 cfst_linux_${PKG}.tar.gz ..."
cd "$WORK" || exit 1
if [ ! -x "$WORK/cfst" ]; then
    curl -L --retry 3 --connect-timeout 20 -o cfst.tar.gz "$URL" || { echo "下载失败: 多半是家里网络到 GitHub 慢或不稳, 换个时间或开代理后重跑; 若重跑还失败, 把报错原样拍照发给李元芳。"; exit 1; }
    tar -xzf cfst.tar.gz
    rm -f cfst.tar.gz
    chmod +x cfst
fi
[ -x "$WORK/cfst" ] || { echo "cfst 解压后不可执行, 安装中止。"; exit 1; }
say "cfst 就绪: $WORK/cfst"

# ---------- 3. 写入测速脚本 ----------
cat > "$WORK/cfst-ph.sh" <<'RUNNER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
# cfst-ph.sh - 安卓 Termux 版: 自动优选菲律宾 (MNL) IP
# 逻辑与路由器版一致 (已验证): HTTPing + -cfcolo MNL, 只留 MNL 且速度>0,
# 速度优先/延迟次之取 Top 10。名单文件 ph-best-ips.txt 为纯节点行
# (IP:443#PH 优选), 不带注释行; 带速度延迟的明细在 ph-best-ips-full.txt。
DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/cfst"
LOGDIR="$DIR/logs"
RESDIR="$DIR/results"
BEST="$DIR/ph-best-ips.txt"
FULL="$DIR/ph-best-ips-full.txt"
LOCK="$DIR/.running"
mkdir -p "$LOGDIR" "$RESDIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGDIR/run.log"; echo "$1"; }
if [ -e "$LOCK" ]; then log "上一次测速还在运行, 本次跳过。"; exit 0; fi
touch "$LOCK"; trap 'rm -f "$LOCK"' EXIT
if [ ! -x "$BIN" ]; then log "错误: $BIN 不存在或不可执行。"; exit 1; fi
STAMP=$(date '+%Y%m%d_%H%M%S')
RUNDIR="$RESDIR/$STAMP"; mkdir -p "$RUNDIR"
CSV="$RUNDIR/result.csv"
log "开始测速 (colo=MNL) ..."
cd "$DIR" || exit 1
"$BIN" -httping -cfcolo MNL -dn 20 -p 20 -o "$CSV" >> "$LOGDIR/run.log" 2>&1
if [ ! -s "$CSV" ]; then log "result.csv 为空, 本次跳过 (名单保持不变)。"; exit 1; fi
# CSV 列: 1=IP 2=已发送 3=已接收 4=丢包率 5=平均延迟 6=下载速度(MB/s) 7=地区码
TMP="$RUNDIR/parsed.txt"
tr -d '\r' < "$CSV" | awk -F',' '
    NR==1 { next }
    NF>=7 { gsub(/ /,"",$7); if ($7=="MNL") printf "%s %s %s\n", $1, $5, $6 }' > "$TMP"
SORTED="$RUNDIR/sorted.txt"
awk '$3+0>0' "$TMP" | sort -k3,3nr -k2,2n > "$SORTED"
if [ ! -s "$SORTED" ]; then
    sort -k2,2n "$TMP" > "$SORTED"
    log "本轮没有速度>0 的 MNL IP, 改用延迟排序兜底。"
fi
COUNT=$(wc -l < "$TMP" | tr -d ' ')
if [ "$COUNT" = "0" ] || [ ! -s "$SORTED" ]; then
    log "本轮没有筛到任何 MNL IP (运营商当前可能没有到马尼拉的路由), 名单保持不变。"
    exit 0
fi
head -n 10 "$SORTED" | awk '{ printf "%s:443#PH 优选\n", $1 }' > "$BEST.tmp"
mv "$BEST.tmp" "$BEST"
{
    echo "# 菲律宾 MNL 优选明细 - 安卓机自动生成于 $(date '+%Y-%m-%d %H:%M:%S')"
    head -n 10 "$SORTED" | awk '{ printf "%s:443 延迟 %sms 速度 %sMB/s\n", $1, $2, $3 }'
} > "$FULL.tmp"
mv "$FULL.tmp" "$FULL"
# 可选: GitHub 自动推送 (存在 push.env 且仓库目录有效时才启用, 默认关闭)
if [ -f "$DIR/push.env" ]; then
    . "$DIR/push.env"
    if [ -n "${REPO_DIR:-}" ] && [ -d "$REPO_DIR/.git" ]; then
        cp "$BEST" "$REPO_DIR/${TARGET_FILE:-ph-best-ips.txt}"
        if ( cd "$REPO_DIR" && git add -A && git commit -m "cfst android $(date '+%F %T')" >/dev/null 2>&1 && git push >/dev/null 2>&1 ); then
            log "GitHub 推送完成。"
        else
            log "GitHub 推送失败 (名单已在本地更新, 不影响)。"
        fi
    fi
fi
log "完成: 本轮筛到 $COUNT 个 MNL IP, Top 名单已更新, 原始结果存档 results/$STAMP"
RUNNER_EOF
chmod +x "$WORK/cfst-ph.sh"
say "测速脚本已写入: $WORK/cfst-ph.sh"

# ---------- 4. 定时任务 ----------
LINE="30 1,7,13,19 * * * $WORK/cfst-ph.sh"
( crontab -l 2>/dev/null | grep -v 'cfst-ph.sh' ; echo "$LINE" ) | crontab -
say "定时任务已注册: 每天 01:30 / 07:30 / 13:30 / 19:30 (手机本地时间)"
if ! pgrep crond >/dev/null 2>&1; then
    crond
    say "crond 已启动。"
else
    say "crond 已在运行。"
fi

# ---------- 5. 开机自启 (Termux:Boot) ----------
BOOTDIR="$HOME/.termux/boot"
mkdir -p "$BOOTDIR"
cat > "$BOOTDIR/start-cfst-cron.sh" <<BOOT_EOF
#!/data/data/com.termux/files/usr/bin/bash
# 开机后自动拉起唤醒锁与 crond (需已安装 Termux:Boot 才会被执行)
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
pgrep crond >/dev/null 2>&1 || crond
BOOT_EOF
chmod +x "$BOOTDIR/start-cfst-cron.sh"
say "开机自启脚本已放好 (安装 Termux:Boot 后生效)。"

# ---------- 6. 立即跑一轮验证 ----------
say "现在立即跑一轮测速验证 (一两分钟, 请稍等)..."
"$WORK/cfst-ph.sh"
echo "============================================================"
if [ -s "$WORK/ph-best-ips.txt" ]; then
    say "验证成功! 当前名单 (~/cfst-android/ph-best-ips.txt):"
    cat "$WORK/ph-best-ips.txt"
else
    say "本轮没生成名单 (可能当前没有到马尼拉的路由), 定时任务会继续按点重试, 日志在 ~/cfst-android/logs/run.log"
fi
echo "============================================================"
say "安装完成。后续每天自动跑 4 次, 你不用管。"
say "保活提醒: 请到系统设置里给 Termux 开自启动、电池策略设为无限制, 并在最近任务里锁定 Termux (详见使用说明)。"
