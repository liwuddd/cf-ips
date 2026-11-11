#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# cfst-ph.sh v2 - 安卓 Termux 版: 自动优选菲律宾 (MNL) IP
#
# 为什么改成 v2 (2026-11-11 在用户家宽实测后重构):
#   cfst 的 HTTPing 和自带下载测速在用户家宽网络下整体不通
#   (已知好 IP 也是可用 0 / 速度 0.00), 但 cfst 的 TCP 延迟
#   测速正常, 且 curl 直连 CF IP 查 cdn-cgi/trace 正常。
#   所以分工改为:
#     1) cfst 只做 TCP 延迟扫描 (全量 IP 段)
#     2) curl 逐个 IP 查 trace 得到落点 colo, 只留 MNL
#     3) curl 拉官方测速文件测下载速度, 排序取 Top 10
# 名单 ph-best-ips.txt 为纯节点行 (IP:443#PH 优选), 无注释行;
# 明细在 ph-best-ips-full.txt。某一轮筛不到 MNL 时不覆盖旧名单。
# ============================================================
DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/cfst"
LOGDIR="$DIR/logs"
RESDIR="$DIR/results"
BEST="$DIR/ph-best-ips.txt"
FULL="$DIR/ph-best-ips-full.txt"
LOCK="$DIR/.running"
TARGET_COLO="MNL"
COLO_CHECK_N=300        # 对延迟最低的前 N 个 IP 查落点
MNL_POOL=25             # 最多对多少个 MNL 候选测下载速度
DL_BYTES=10485760       # 下载测速文件大小 (10MB)
mkdir -p "$LOGDIR" "$RESDIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGDIR/run.log"; echo "$1"; }
if [ -e "$LOCK" ]; then log "上一次测速还在运行, 本次跳过。"; exit 0; fi
touch "$LOCK"; trap 'rm -f "$LOCK"' EXIT
if [ ! -x "$BIN" ]; then log "错误: $BIN 不存在或不可执行。"; exit 1; fi
STAMP=$(date '+%Y%m%d_%H%M%S')
RUNDIR="$RESDIR/$STAMP"; mkdir -p "$RUNDIR"
cd "$DIR" || exit 1

# ---------- 1. cfst TCP 延迟扫描 ----------
LATCSV="$RUNDIR/latency.csv"
log "开始 TCP 延迟扫描 (全量 IP 段) ..."
"$BIN" -dd -p 9999 -o "$LATCSV" >> "$LOGDIR/run.log" 2>&1
if [ ! -s "$LATCSV" ]; then log "延迟扫描无结果 (网络异常?), 本次跳过, 名单保持不变。"; exit 1; fi
# CSV 列: 1=IP 2=已发送 3=已接收 4=丢包率 5=平均延迟 6=下载速度 7=地区码(N/A)
CAND="$RUNDIR/candidates.txt"
tr -d '\r' < "$LATCSV" | awk -F',' '
    NR==1 { next }
    NF>=5 && $3+0>0 { printf "%s %s %s\n", $1, $5, $4 }' > "$CAND"
CAND_N=$(wc -l < "$CAND" | tr -d ' ')
if [ "$CAND_N" = "0" ]; then log "延迟扫描没有可用 IP, 本次跳过, 名单保持不变。"; exit 1; fi
log "延迟扫描完成: $CAND_N 个 IP 可用, 对延迟最低的前 $COLO_CHECK_N 个查落点。"

# ---------- 2. curl 逐个查落点 (colo) ----------
CHECK="$RUNDIR/check.txt"
head -n "$COLO_CHECK_N" "$CAND" > "$CHECK"
HELPER="$RUNDIR/colo_one.sh"
cat > "$HELPER" <<'HELPER_EOF'
#!/data/data/com.termux/files/usr/bin/bash
ip="$1"
colo=$(curl -s --max-time 8 --resolve "www.cloudflare.com:443:$ip" \
    "https://www.cloudflare.com/cdn-cgi/trace" 2>/dev/null \
    | tr -d '\r' | sed -n 's/^colo=//p')
[ -n "$colo" ] && printf '%s %s\n' "$ip" "$colo"
HELPER_EOF
chmod +x "$HELPER"
COLO="$RUNDIR/colo.txt"
cut -d' ' -f1 "$CHECK" | xargs -P 10 -n 1 "$HELPER" > "$COLO" 2>/dev/null
DIST=$(awk '{print $2}' "$COLO" | sort | uniq -c | sort -rn | awk '{printf "%s×%s ", $2, $1}')
log "落点分布 (前 $COLO_CHECK_N 个低延迟 IP): $DIST"
# 把 MNL 的 IP 连同延迟挑出来 (保持延迟升序), 取前 MNL_POOL 个
MNLF="$RUNDIR/mnl.txt"
awk 'NR==FNR { lat[$1]=$2; next } $2=="MNL" { print $1, lat[$1] }' \
    "$CAND" "$COLO" | sort -k2,2n | head -n "$MNL_POOL" > "$MNLF"
MNL_N=$(wc -l < "$MNLF" | tr -d ' ')
if [ "$MNL_N" = "0" ]; then
    log "本轮没有筛到 MNL 落点 (运营商当前路由不去马尼拉), 名单保持不变。"
    exit 0
fi
log "筛到 $MNL_N 个 MNL 候选, 开始逐个测下载速度 ..."

# ---------- 3. curl 逐个测下载速度 (串行, 避免互相抢带宽) ----------
DL="$RUNDIR/download.txt"
: > "$DL"
while read -r ip lat; do
    spd=$(curl -s --max-time 25 --resolve "speed.cloudflare.com:443:$ip" \
        -o /dev/null -w '%{speed_download}' \
        "https://speed.cloudflare.com/__down?bytes=$DL_BYTES" 2>/dev/null)
    case "$spd" in ''|*[!0-9.]*) spd=0 ;; esac
    mbps=$(awk -v b="$spd" 'BEGIN { printf "%.2f", b/1048576 }')
    echo "$ip $lat $mbps" >> "$DL"
done < "$MNLF"
SORTED="$RUNDIR/sorted.txt"
if awk '$3+0>0' "$DL" | grep -q .; then
    awk '$3+0>0' "$DL" | sort -k3,3nr -k2,2n > "$SORTED"
else
    sort -k2,2n "$DL" > "$SORTED"
    log "本轮 MNL 候选下载测速全为 0, 改用延迟排序兜底。"
fi

# ---------- 4. 写名单 ----------
head -n 10 "$SORTED" | awk '{ printf "%s:443#PH 优选\n", $1 }' > "$BEST.tmp"
mv "$BEST.tmp" "$BEST"
{
    echo "# 菲律宾 MNL 优选明细 - 安卓机自动生成于 $(date '+%Y-%m-%d %H:%M:%S') (v2: TCP延迟+curl落点+curl测速)"
    head -n 10 "$SORTED" | awk '{ printf "%s:443 落点 MNL 延迟 %sms 速度 %sMB/s\n", $1, $2, $3 }'
} > "$FULL.tmp"
mv "$FULL.tmp" "$FULL"

# ---------- 5. 可选: GitHub 自动推送 (存在 push.env 时才启用, 默认关闭) ----------
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
log "完成: 本轮 Top 名单已更新 (MNL 候选 $MNL_N 个), 原始结果存档 results/$STAMP"
