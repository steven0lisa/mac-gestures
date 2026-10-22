#!/bin/bash
# check-sensitive.sh — 推送前敏感信息扫描（全局 AGENTS.md 规则 18 的项目落地）
# FAIL（凭据 / 公司信息 / webhook）命中退出 1，禁止提交推送；WARN（邮箱 / 路径 / 姓名）仅提示人工确认。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EXCLUDES=(
    --exclude-dir=.git --exclude-dir=build --exclude-dir=dist
    --exclude-dir=DerivedData --exclude-dir=.build --exclude-dir=.v2c
    --exclude-dir=.findings --exclude=check-sensitive.sh --exclude=Package.resolved
)

fail=0
warn=0

scan() {
    local label="$1" pattern="$2" level="$3" hits
    # 统一过滤两类误报：HiDPI 图片后缀（icon@2x.png）造成的邮箱命中；
    # GitHub noreply 邮箱（为公开署名设计的隐私地址，文档中合法出现）
    hits=$(grep -rniE "$pattern" "${EXCLUDES[@]}" . 2>/dev/null | grep -viE '@[0-9]x\.png|users\.noreply\.github\.com' || true)
    if [ -n "$hits" ]; then
        if [ "$level" = "FAIL" ]; then fail=1; else warn=1; fi
        echo "[$level] $label:"
        echo "$hits" | head -20
        echo ""
    fi
}

echo "== 敏感信息扫描: $ROOT =="

# ---- FAIL：凭据与公司信息 ----
scan "API/Token 凭据" \
    'sk-[a-zA-Z0-9]{12,}|ghp_[A-Za-z0-9]{16,}|gho_[A-Za-z0-9]{16,}|hf_[A-Za-z0-9]{16,}|AKIA[0-9A-Z]{12,}|xox[baprs]-[A-Za-z0-9-]{10,}' FAIL
scan "私钥文件标记" 'BEGIN [A-Z ]*PRIVATE KEY' FAIL
# 公司/雇主专属敏感词绝不硬编码在本脚本里——脚本会进公开仓库，等于自己暴露雇主。
# 从本地清单加载（一行一个 ERE，# 为注释）：env SENSITIVE_LOCAL_PATTERNS
# → ~/.zcode/secrets/sensitive-local-patterns.txt → scripts/sensitive-local.txt（已 gitignore）。
# 清单只在本地存在，CI 拿不到：公司名泄露的防线是本地推送前扫描，不是 CI。
LOCAL_PATTERNS="${SENSITIVE_LOCAL_PATTERNS:-$HOME/.zcode/secrets/sensitive-local-patterns.txt}"
[ -f "$LOCAL_PATTERNS" ] || LOCAL_PATTERNS="$ROOT/scripts/sensitive-local.txt"
if [ -f "$LOCAL_PATTERNS" ]; then
    joined=$(grep -vE '^[[:space:]]*(#|$)' "$LOCAL_PATTERNS" | paste -sd '|' -)
    [ -n "$joined" ] && scan "本地敏感词清单" "$joined" FAIL
fi
scan "IM / 协作平台 webhook" \
    'open\.feishu\.cn/open-apis/bot|qyapi\.weixin\.qq\.com/cgi-bin/webhook|hooks\.slack\.com/services|discord\.com/api/webhooks' FAIL
scan "带密码的数据库连接串" \
    '(mysql|postgres|postgresql|mongodb(\+srv)?|redis)://[^[:space:]"'"'"']+:[^[:space:]"'"'"']+@' FAIL

# ---- WARN：需人工确认 ----
scan "邮箱地址" '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' WARN
scan "本机绝对路径" '/Users/[a-zA-Z0-9_.-]+' WARN
scan "疑似真实姓名" 'zhangzichao|zichao\.zhang' WARN
scan "手机号" '\b1[3-9][0-9]{9}\b' WARN

if [ "$fail" -ne 0 ]; then
    echo "结果：FAIL — 存在必须处理的敏感信息，禁止提交 / 推送。请删除或替换为占位符后重试。"
    exit 1
fi
if [ "$warn" -ne 0 ]; then
    echo "结果：WARN — 以上命中需人工确认是否可公开。"
    exit 0
fi
echo "结果：CLEAN — 未发现敏感信息。"
exit 0
