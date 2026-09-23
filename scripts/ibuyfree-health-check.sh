#!/usr/bin/env bash
# ibuyfree.com 健康三件套（项目宪法 原则 3）
# 用法: ops/health-check.sh [origin]
#   origin 默认 https://www.ibuyfree.com ，可传 Vercel Preview URL
# 退出码: 0 全部 PASS，非 0 = FAIL 数量

set -uo pipefail
ORIGIN="${1:-https://www.ibuyfree.com}"
UA="ibuyfree-healthcheck/1.0"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Notion 数据源（001 体检确认）
COLLECTION_ID="c911a6f0-c31c-4b32-bb73-dcf8e4efa488"
SPACE_ID="16ba0854-78fd-45b0-9d5d-4a60375028dc"
VIEW_ID="732f5297-27f2-4660-9465-b92e2379d998"

# ISR 缓存 age 上限（秒）。C-5 已确认 NEXT_REVALIDATE_SECOND=3600（1小时），
# 阈值给 2 倍缓冲（2小时）。2026-09-09
MAX_AGE="${MAX_AGE:-7200}"

FAILS=0
pass(){ printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail(){ printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILS=$((FAILS+1)); }

echo "== ibuyfree health check =="
echo "origin: $ORIGIN"
echo

# --- 参照值：Notion 中已发布的 Post 数 ---
curl -s -m 30 -X POST "https://www.notion.so/api/v3/queryCollection?src=initial_load" \
  -H "Content-Type: application/json" -A "$UA" \
  -d "{\"source\":{\"type\":\"collection\",\"id\":\"$COLLECTION_ID\",\"spaceId\":\"$SPACE_ID\"},\"collectionView\":{\"id\":\"$VIEW_ID\",\"spaceId\":\"$SPACE_ID\"},\"loader\":{\"reducers\":{\"collection_group_results\":{\"type\":\"results\",\"limit\":200}},\"sortQuery\":[],\"searchQuery\":\"\",\"userTimeZone\":\"Asia/Shanghai\"}}" \
  -o "$TMP/notion.json" 2>/dev/null

EXPECTED=$(python3 - "$TMP/notion.json" <<'PY'
import json,sys
try: d=json.load(open(sys.argv[1]))
except Exception: print(-1); raise SystemExit
rm=d.get("recordMap",{}); sch={}
for c in rm.get("collection",{}).values():
    v=c.get("value",{}); v=v.get("value",v); sch=v.get("schema") or {}
inv={v.get("name"):k for k,v in sch.items()}
n=0
for bv in rm.get("block",{}).values():
    v=bv.get("value") or {}; v=v.get("value",v)
    if v.get("type")!="page": continue
    pr=v.get("properties") or {}
    def g(name):
        k=inv.get(name)
        try: return pr[k][0][0]
        except Exception: return None
    if g("status")=="Published" and g("type")=="Post": n+=1
print(n)
PY
)
echo "Notion 参照: status=Published && type=Post 共 ${EXPECTED} 篇"
echo

# --- [1] postCount ---
curl -sL -m 30 -A "$UA" "$ORIGIN/?hc=$RANDOM" -o "$TMP/home.html" -D "$TMP/home.hdr" 2>/dev/null
POSTCOUNT=$(python3 - "$TMP/home.html" <<'PY'
import re,json,sys
h=open(sys.argv[1],encoding='utf-8',errors='replace').read()
m=re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>',h,re.S)
if not m: print(-1); raise SystemExit
try: print(json.loads(m.group(1))["props"]["pageProps"].get("postCount",-1))
except Exception: print(-1)
PY
)
echo "[1] 首页 postCount"
if [ "$POSTCOUNT" -gt 0 ] 2>/dev/null; then
  pass "postCount=$POSTCOUNT (期望 >0)"
else
  fail "postCount=$POSTCOUNT (期望 >0) —— 站点读不到 Notion 内容"
fi

# --- [2] sitemap 文章 URL 数 ---
curl -sL -m 30 -A "$UA" "$ORIGIN/sitemap.xml" -o "$TMP/sitemap.xml" 2>/dev/null
SYS_RE='/(archive|category|search|tag|feed|rss)(/|$)'
TOTAL=$(grep -oE "<loc>[^<]+</loc>" "$TMP/sitemap.xml" 2>/dev/null | wc -l | tr -d ' ')
ARTICLES=$(grep -oE "<loc>[^<]+</loc>" "$TMP/sitemap.xml" 2>/dev/null | sed 's/<[^>]*>//g' \
  | grep -vE "$SYS_RE" | grep -vE "^https?://[^/]+/?$" | wc -l | tr -d ' ')
echo "[2] sitemap 文章 URL"
if [ "$ARTICLES" -gt 0 ] && [ "$EXPECTED" -gt 0 ] && [ "$ARTICLES" -ge "$EXPECTED" ]; then
  pass "文章 URL=$ARTICLES / 总 URL=$TOTAL (期望 >=$EXPECTED)"
else
  fail "文章 URL=$ARTICLES / 总 URL=$TOTAL (期望 >=$EXPECTED)"
fi

# --- [3] 边缘缓存新鲜度 ---
VCACHE=$(grep -i '^x-vercel-cache:' "$TMP/home.hdr" | tr -d '\r' | awk '{print $2}')
AGE=$(grep -i '^age:' "$TMP/home.hdr" | tr -d '\r' | awk '{print $2}')
AGE=${AGE:-0}
echo "[3] 边缘缓存新鲜度"
if [ "$AGE" -le "$MAX_AGE" ] 2>/dev/null; then
  pass "x-vercel-cache=${VCACHE:-n/a} age=${AGE}s (上限 ${MAX_AGE}s)"
else
  DAYS=$((AGE/86400))
  fail "x-vercel-cache=${VCACHE:-n/a} age=${AGE}s (≈${DAYS} 天，上限 ${MAX_AGE}s) —— 构建长期未成功"
fi

echo
if [ "$FAILS" -eq 0 ]; then
  printf '\033[32m全部通过\033[0m\n'
else
  printf '\033[31m%d 项失败\033[0m\n' "$FAILS"
fi
exit "$FAILS"
