#!/data/data/com.termux/files/usr/bin/bash
# ============================================================
# cfst-ph.sh v3 - 安卓 Termux 版: 三国优选 (新加坡/日本/英国)
#
# 2026-11-11 用户新规格 (取代 v2 的菲律宾 MNL 单目标):
#   - 目标落点: SIN 新加坡 / NRT 日本 / LHR 英国, 每国只要 2-3 个
#   - 延迟门槛 (cfst TCP 延迟): SIN <200ms, NRT <200ms, LHR <400ms
#   - 达标候选再用 curl 测下载速度排序, 每国取前 3
#   - 名单 best-ips.txt 为纯节点行 (IP:443#SG 优选 等), 无注释行
#   - 跑完自动把名单/明细/日志尾巴传 GitHub 仓库 phone/ 目录
#     (令牌读 ~/cfst-android/gh-token, 只存手机本地; 无令牌则跳过)
# 背景: 用户家宽路由不去菲律宾 (2672 个 IP 全量普查 MNL 为 0),
# 且 cfst 的 HTTPing/自带测速在其家宽不通, 故沿用 v2 分工:
# cfst 只做 TCP 延迟, 落点与下载都由 curl 完成。
# 某国达标为 0 时该国不出现 (不放宽门槛凑数); 三国全 0 不覆盖旧名单。
# ============================================================
DIR=$(cd "$(dirname "$0")" && pwd)
BIN="$DIR/cfst"
LOGDIR="$DIR/logs"
RESDIR="$DIR/results"
BEST="$DIR/best-ips.txt"
FULL="$DIR/best-ips-full.txt"
LOCK="$DIR/.running"
REPO="liwuddd/cf-ips"
DL_BYTES=10485760       # 下载测速文件大小 (10MB)
DL_POOL=8               # 每国最多对多少个达标候选测下载
PICK_N=3                # 每国入选个数
COLO_MAX=3000           # 查落点的 IP 数上限 (按延迟升序截断)
mkdir -p "$LOGDIR" "$RESDIR"
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOGDIR/run.log"; echo "$1"; }
if [ -e "$LOCK" ]; then log "上一次测速还在运行, 本次跳过。"; exit 0; fi
touch "$LOCK"; trap 'rm -f "$LOCK"' EXIT
if [ ! -x "$BIN" ]; then log "错误: $BIN 不存在或不可执行。"; exit 1; fi
STAMP=$(date '+%Y%m%d_%H%M%S')
RUNDIR="$RESDIR/$STAMP"; mkdir -p "$RUNDIR"
cd "$DIR" || exit 1

# 目标表: 落点 延迟门槛ms 名单标签 (一行一个)
TARGETS="SIN 200 SG
NRT 200 JP
LHR 400 UK"

# ---------- 1. cfst TCP 延迟扫描 ----------
LATCSV="$RUNDIR/latency.csv"
log "开始 TCP 延迟扫描 (全量 IP 段) ..."
"$BIN" -dd -p 9999 -o "$LATCSV" >> "$LOGDIR/run.log" 2>&1
if [ ! -s "$LATCSV" ]; then log "延迟扫描无结果 (网络异常?), 本次跳过, 名单保持不变。"; exit 1; fi
# CSV 列: 1=IP 2=已发送 3=已接收 4=丢包率 5=平均延迟 6=下载速度 7=地区码(N/A)
CAND="$RUNDIR/candidates.txt"
tr -d '\r' < "$LATCSV" | awk -F',' '
    NR==1 { next }
    NF>=5 && $3+0>0 { printf "%s %s %s\n", $1, $5, $4 }' | sort -k2,2n > "$CAND"
CAND_N=$(wc -l < "$CAND" | tr -d ' ')
if [ "$CAND_N" = "0" ]; then log "延迟扫描没有可用 IP, 本次跳过, 名单保持不变。"; exit 1; fi
log "延迟扫描完成: $CAND_N 个 IP 可用。"

# ---------- 2. curl 查落点 (只查延迟 <400ms 的, 覆盖三国最宽门槛) ----------
CHECK="$RUNDIR/check.txt"
awk '$2+0<400' "$CAND" | head -n "$COLO_MAX" > "$CHECK"
CHECK_N=$(wc -l < "$CHECK" | tr -d ' ')
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
log "落点分布 (延迟<400ms 的 $CHECK_N 个): $DIST"

# ---------- 3. 逐国筛选 + 下载测速 + 写名单 ----------
BESTTMP="$RUNDIR/best.tmp"; : > "$BESTTMP"
FULLTMP="$RUNDIR/full.tmp"
echo "# 三国优选明细 - 安卓机自动生成于 $(date '+%Y-%m-%d %H:%M:%S') (v3: SIN<200ms / NRT<200ms / LHR<400ms, 每国前 $PICK_N)" > "$FULLTMP"
TOTAL_PICKS=0
while read -r colo cap label; do
    [ -n "$colo" ] || continue
    POOL="$RUNDIR/pool-$colo.txt"
    awk -v c="$colo" 'NR==FNR { lat[$1]=$2; next } $2==c { print $1, lat[$1] }' \
        "$CAND" "$COLO" | sort -k2,2n > "$POOL"
    POOL_N=$(wc -l < "$POOL" | tr -d ' ')
    UNDER="$RUNDIR/under-$colo.txt"
    awk -v cap="$cap" '$2+0<cap' "$POOL" > "$UNDER"
    UNDER_N=$(wc -l < "$UNDER" | tr -d ' ')
    TESTF="$RUNDIR/test-$colo.txt"
    head -n "$DL_POOL" "$UNDER" > "$TESTF"
    DL="$RUNDIR/download-$colo.txt"; : > "$DL"
    while read -r ip lat; do
        spd=$(curl -s --max-time 25 --resolve "speed.cloudflare.com:443:$ip" \
            -o /dev/null -w '%{speed_download}' \
            "https://speed.cloudflare.com/__down?bytes=$DL_BYTES" 2>/dev/null)
        case "$spd" in ''|*[!0-9.]*) spd=0 ;; esac
        mbps=$(awk -v b="$spd" 'BEGIN { printf "%.2f", b/1048576 }')
        echo "$ip $lat $mbps" >> "$DL"
    done < "$TESTF"
    SORTED="$RUNDIR/sorted-$colo.txt"
    if awk '$3+0>0' "$DL" | grep -q .; then
        awk '$3+0>0' "$DL" | sort -k3,3nr -k2,2n > "$SORTED"
    else
        sort -k2,2n "$DL" > "$SORTED"
        [ -s "$DL" ] && log "$label($colo): 下载测速全为 0, 改用延迟排序兜底。"
    fi
    PICKS="$RUNDIR/picks-$colo.txt"
    head -n "$PICK_N" "$SORTED" > "$PICKS"
    PICKN=$(wc -l < "$PICKS" | tr -d ' ')
    TOTAL_PICKS=$((TOTAL_PICKS + PICKN))
    awk -v lab="$label" '{ printf "%s:443#%s 优选\n", $1, lab }' "$PICKS" >> "$BESTTMP"
    {
        echo "== $label ($colo) 门槛 <${cap}ms: 落点候选 $POOL_N 个, 达标 $UNDER_N 个, 入选 $PICKN 个"
        awk -v c="$colo" '{ printf "%s:443 落点 %s 延迟 %sms 速度 %sMB/s\n", $1, c, $2, $3 }' "$PICKS"
    } >> "$FULLTMP"
    log "$label($colo): 候选 $POOL_N, 达标(延迟<${cap}ms) $UNDER_N, 入选 $PICKN。"
done <<EOF
$TARGETS
EOF

if [ "$TOTAL_PICKS" = "0" ]; then
    log "本轮三国均无达标 IP, 名单保持不变。"
    exit 0
fi
mv "$BESTTMP" "$BEST"
mv "$FULLTMP" "$FULL"

# ---------- 4. GitHub 自动上传 (存在 gh-token 时; 失败只记日志) ----------
if [ -f "$DIR/gh-token" ]; then
    TK=$(tr -d '[:space:]' < "$DIR/gh-token")
    if [ -n "$TK" ]; then
        gh_put() {
            lpath="$1"; rpath="$2"
            sha=$(curl -s --retry 3 --retry-all-errors \
                -H "Authorization: Bearer $TK" -H "Accept: application/vnd.github+json" \
                "https://api.github.com/repos/$REPO/contents/$rpath" \
                | sed -n 's/.*"sha": *"\([a-f0-9]\{40\}\)".*/\1/p' | head -n 1)
            b64=$(base64 "$lpath" | tr -d '\n')
            payload="$RUNDIR/payload-$3.json"
            if [ -n "$sha" ]; then
                printf '{"message":"android cfst v3 %s","content":"%s","sha":"%s"}' \
                    "$(date '+%F %T')" "$b64" "$sha" > "$payload"
            else
                printf '{"message":"android cfst v3 %s","content":"%s"}' \
                    "$(date '+%F %T')" "$b64" > "$payload"
            fi
            resp=$(curl -s -o /dev/null -w '%{http_code}' --retry 3 --retry-all-errors \
                -X PUT -H "Authorization: Bearer $TK" -H "Accept: application/vnd.github+json" \
                --data @"$payload" \
                "https://api.github.com/repos/$REPO/contents/$rpath")
            [ "$resp" = "200" ] || [ "$resp" = "201" ]
        }
        tail -n 80 "$LOGDIR/run.log" > "$RUNDIR/runlog-tail.txt"
        ok=1
        gh_put "$BEST" "phone/best-ips.txt" 1 || ok=0
        gh_put "$FULL" "phone/best-ips-full.txt" 2 || ok=0
        gh_put "$RUNDIR/runlog-tail.txt" "phone/run-log-latest.txt" 3 || ok=0
        if [ "$ok" = "1" ]; then log "GitHub 上传完成 (phone/ 目录)。"; else log "GitHub 上传有失败项 (名单已在本地更新, 不影响)。"; fi
    fi
fi
log "完成: 本轮三国共入选 $TOTAL_PICKS 个, 原始结果存档 results/$STAMP"
