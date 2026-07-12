#!/usr/bin/env bash
# 핫라인(session-hotline) — 다른 AI 세션(Claude Code·Codex)에 직통 질문하는 전송 스크립트
# SKILL.md(오케스트레이터)가 호출한다. 이 스크립트는 "정확한 대상 찾기 + 안전 가드 + 전송 + 답 회수"만 담당.
# 검증 기반: 2026-07-05 실측 검증 (README의 검증 버전 참고).
#
# 서브커맨드:
#   doctor                              환경·CLI·필수 플래그·내부 포맷 점검 (fail-loud)
#   resolve claude <제목|UUID>          Claude 세션 해석 → 후보 JSON (uuid·title·cwd(첫 필드)·폴더대조·mtime)
#   resolve codex  <이름|ID>            Codex 세션 해석 → 후보 JSON (id·최신 thread_name·updated_at·rollout·mtime)
#   scan <질문파일>                     시크릿 패턴 스캔 (발견 시 rc=1 — 오케스트레이터가 사용자 확인)
#   ask codex  <ID> <질문파일>          codex exec resume, read-only 샌드박스 자문 → 답 stdout
#   ask claude <UUID> <CWD> <질문파일>  claude resume, fork + read-only(allowlist+MCP차단) 자문 → 답 stdout
#
# 안전 원칙: 배열 실행·eval 금지 / JSON은 python 파서(grep 금지) / 실패는 그대로 터뜨림(No Silent Fallback).
set -u

# ── 재귀 차단 (Y1): 자문받은 세션이 또 핫라인을 부르면 여기서 하드 차단.
#    주의: 이 sentinel은 CLI 경로에서만 유효(자식 프로세스가 env 상속). send_message 경로엔 env가
#    안 넘어가므로 그쪽은 자문 프롬프트 문구("재호출 금지")가 유일한 방어다 — SKILL.md에 정직 표기.
if [ "${SESSIONBRIDGE_DEPTH:-0}" -ge 1 ]; then
  echo "HOTLINE-BLOCKED: 이 프로세스는 이미 핫라인 자문 체인 안이다(SESSIONBRIDGE_DEPTH=${SESSIONBRIDGE_DEPTH}). 재귀 호출 금지." >&2
  exit 3
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
TIMEOUT="${HOTLINE_TIMEOUT:-300}"
CLAUDE_PROJECTS="${HOTLINE_CLAUDE_PROJECTS:-$HOME/.claude/projects}"
CODEX_INDEX="${HOTLINE_CODEX_INDEX:-$HOME/.codex/session_index.jsonl}"
CODEX_SESSIONS="${HOTLINE_CODEX_SESSIONS:-$HOME/.codex/sessions}"
RECENT_SEC=600   # "대상 세션이 열려있을 수 있음" 경고 기준(휴리스틱)

die() { echo "HOTLINE-ERROR: $*" >&2; exit 1; }

# F4: macOS 전용(내부 세션 포맷·stat -f·앱 경로 의존) — 다른 OS에선 조용히 오작동하지 않고 명확히 실패
[ "$(uname -s)" = "Darwin" ] || die "핫라인은 macOS 전용이다(uname=$(uname -s)). 내부 세션 포맷·stat -f·앱 경로가 macOS에 묶여 있어 지원 안 함."

# F5: 세션 id는 16진수+하이픈만 허용 — glob·경로 인젝션 차단(ask 진입에서 강제)
assert_session_id() {
  case "${1:-}" in
    "" | *[!0-9A-Fa-f-]* ) die "세션 id 형식 오류(16진수·하이픈만 허용): '${1:-}'" ;;
  esac
}

# codex 바이너리 탐색(공통) — PATH 우선, 없으면 앱 번들 후보 순회.
# 2026-07-11 실측: 바이너리가 Codex.app → ChatGPT.app/Contents/Resources 로 이사(신규 우선·옛 경로도 유지=구버전 호환).
# 성공 시 CODEX_BIN 설정하고 rc=0, 못 찾으면 rc=1 — die/warn 결정은 호출측 몫(doctor는 warn, ask는 die).
resolve_codex_bin() {
  CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
  if [ -z "$CODEX_BIN" ]; then
    for cand in "/Applications/ChatGPT.app/Contents/Resources/codex" "/Applications/Codex.app/Contents/Resources/codex"; do
      [ -x "$cand" ] && { CODEX_BIN="$cand"; break; }
    done
  fi
  [ -x "${CODEX_BIN:-}" ]
}

find_codex() {
  resolve_codex_bin || die "codex를 못 찾음 — Codex 설치 확인 또는 CODEX_BIN=경로 지정"
}

find_claude() {
  CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
  [ -n "$CLAUDE_BIN" ] || CLAUDE_BIN="$HOME/.local/bin/claude"
  [ -x "$CLAUDE_BIN" ] || die "claude를 못 찾음 — Claude Code 설치 확인 또는 CLAUDE_BIN=경로 지정"
}

warn_if_recent() { # $1=파일 $2=대상설명 $3=대상별 추가 안내
  [ -f "$1" ] || return 0
  local age=$(( $(date +%s) - $(stat -f %m "$1") ))
  if [ "$age" -lt "$RECENT_SEC" ]; then
    echo "HOTLINE-WARN(비치명 — 실행은 계속됨): $2 이(가) ${age}초 전에 수정됨 — 그 세션이 지금 열려있을 수 있다(휴리스틱, 오탐 가능). $3" >&2
  fi
}

# ═══ doctor ═══════════════════════════════════════════════════════════
cmd_doctor() {
  local fail=0
  ok()   { echo "✅ $*"; }
  warn() { echo "⚠️  $*"; }
  bad()  { echo "❌ $*"; fail=1; }

  command -v python3 >/dev/null && ok "python3 $(python3 --version 2>&1 | cut -d' ' -f2)" || bad "python3 없음 — 이름해석 불가"
  command -v perl    >/dev/null && ok "perl (타임아웃용)" || bad "perl 없음 — 타임아웃 불가(macOS엔 timeout 명령이 없어 perl alarm 사용)"

  if CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo "$HOME/.local/bin/claude")}"; [ -x "$CLAUDE_BIN" ]; then
    ok "claude $($CLAUDE_BIN --version 2>&1 | head -1)"
    local h; h="$($CLAUDE_BIN --help 2>&1)"
    for f in --resume --fork-session --tools --strict-mcp-config --print; do
      echo "$h" | grep -q -- "$f" && ok "claude 플래그 $f" || bad "claude 플래그 $f 소실 — Claude Code 업데이트로 깨졌을 수 있음"
    done
  else
    warn "claude CLI 없음 — 대상=Claude 경로(CLI) 사용 불가"
  fi

  if resolve_codex_bin; then
    # 버전 줄만 추출 — 코덱스 앱 터미널에선 --version 앞에 PATH alias 경고가 붙어 head -1이 그걸 잡는다
    # (실측 2026-07-12 리허설: 코덱스 3세션 다 "codex WARNING: ...PATH aliases..."로 표시됨). codex-cli 줄 우선, 못 찾으면 head -1 폴백.
    local cver; cver="$($CODEX_BIN --version 2>&1 | grep -iE 'codex-cli|codex [0-9]' | head -1)"
    [ -n "$cver" ] || cver="$($CODEX_BIN --version 2>&1 | head -1)"
    # 앱 번들 폴백 경로에서 찾았으면 표시(다음에 또 이사하면 어느 경로인지 즉시 파악)
    local cpath=""; case "$CODEX_BIN" in /Applications/*) cpath=" — $CODEX_BIN (앱 번들 폴백)";; esac
    ok "codex $cver$cpath"
    local eh; eh="$($CODEX_BIN exec resume --help 2>&1)"
    echo "$eh" | grep -q -- --skip-git-repo-check && ok "codex exec resume --skip-git-repo-check" || bad "codex resume 플래그 소실 — Codex 업데이트로 깨졌을 수 있음"
    echo "$eh" | grep -qE -- '-c, --config|--config' && ok "codex -c(sandbox_mode 오버라이드)" || bad "codex -c 플래그 소실"
    echo "$eh" | grep -q -- --output-last-message && ok "codex -o(답변 회수)" || bad "codex -o(--output-last-message) 플래그 소실"
  else
    warn "codex CLI 없음 — 대상=Codex 경로 사용 불가"
  fi

  [ -d "$CLAUDE_PROJECTS" ] && ok "Claude 세션 저장소 $CLAUDE_PROJECTS" || warn "Claude 세션 저장소 없음($CLAUDE_PROJECTS) — 대상=Claude 이름해석 불가"
  local dstore="${HOTLINE_CLAUDE_DESKTOP_STORE:-$HOME/Library/Application Support/Claude/claude-code-sessions}"
  [ -d "$dstore" ] && ok "Claude 데스크탑 세션 저장소(자동 제목 검색원)" || warn "Claude 데스크탑 세션 저장소 없음 — 자동 생성 제목은 이름검색 불가(커스텀 제목·id는 가능)"
  [ -f "$CODEX_INDEX" ] && ok "Codex 이름 인덱스 $CODEX_INDEX" || warn "Codex 이름 인덱스 없음 — Codex 세션은 id 직접지정만 가능"

  if [ "$fail" -ne 0 ]; then
    echo "" >&2
    echo "HOTLINE-ERROR: 필수 점검 실패. Claude Code/Codex 업데이트로 내부 포맷·플래그가 바뀌어 깨졌을 수 있다(네 잘못 아님). 검증 기준: 2026-07-11, claude 2.1.206 / codex 0.144.0-alpha.4, macOS 전용." >&2
    exit 1
  fi
}

# ═══ resolve ══════════════════════════════════════════════════════════
cmd_resolve_claude() { # $1=제목 또는 UUID → {match_type, candidates, suggestions}. 0건 rc=1, 1건 rc=0, 복수 rc=2
  # python은 별도 파일로(heredoc 금지 — heredoc은 임시파일이 필요해 read-only 샌드박스(codex)에서 실패, 실측 2026-07-06)
  python3 "$SCRIPT_DIR/resolve_claude.py" "$CLAUDE_PROJECTS" "$1"
}

cmd_resolve_codex() { # $1=thread_name 또는 ID → {match_type, candidates, suggestions}. rc 규약 동일
  python3 "$SCRIPT_DIR/resolve_codex.py" "$CODEX_INDEX" "$CODEX_SESSIONS" "$1"
}
# ═══ scan (Y2) ════════════════════════════════════════════════════════
cmd_scan() { # $1=질문파일. 시크릿 의심 발견 시 rc=1 (질문은 대상 세션 로그에 영구 기록되므로)
  [ -f "$1" ] || die "scan: 질문 파일 없음: $1"
  # F1: 읽기 실패를 침묵 통과시키지 않는다 — 못 읽으면 스캔이 무의미하므로 크게 실패(No Silent Fallback)
  [ -r "$1" ] || die "scan: 질문 파일을 읽을 수 없음(권한): $1 — 시크릿 검사 없이 전송하면 안 되므로 진행 중단"
  # 형식 고유 프리픽스(즉시 차단) + 키=값 일반 패턴. gitleaks류 외부 의존 없이 순수 grep.
  # (2026-07-06 스캐너 배터리 검증: 미탐 8종 추가 해소, 오탐 0. 잔여 한계는 SKILL.md '한계'에 정직 표기)
  local pat_prefix='sk-[A-Za-z0-9_-]{16,}|sk_(live|test)_[A-Za-z0-9]{16,}|rk_live_[A-Za-z0-9]{16,}|gh[oprsu]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|AKIA[0-9A-Z]{12,}|AIza[A-Za-z0-9_-]{35}|xox[bpsr]-[A-Za-z0-9-]{10,}|npm_[A-Za-z0-9]{20,}|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+|(postgres|postgresql|mysql|mongodb(\+srv)?)://[^:[:space:]]+:[^@[:space:]]+@|-----BEGIN [A-Z ]*PRIVATE KEY'
  local pat_kv='(api[_-]?key|secret|password|passwd|bearer|authorization|token|session|cookie)[[:space:]]*[:=][[:space:]]*[^[:space:]]{6,}|(^|[^A-Za-z0-9_.])\.env([^A-Za-z0-9]|$)'
  # F1: grep rc를 분리 확인 — 0=발견 / 1=없음(정상) / ≥2=읽기·정규식 오류 → 침묵 통과 대신 die
  local hits1 hits2 rc1 rc2
  hits1="$(grep -nE "$pat_prefix" "$1")"; rc1=$?
  hits2="$(grep -inE "$pat_kv" "$1")"; rc2=$?
  if [ "$rc1" -ge 2 ] || [ "$rc2" -ge 2 ]; then
    die "scan: grep 실행 오류(rc1=$rc1 rc2=$rc2) — 스캔 신뢰 불가라 진행 중단"
  fi
  local hits; hits="$(printf '%s\n%s\n' "$hits1" "$hits2" | grep -v '^[[:space:]]*$' || true)"
  if [ -n "$hits" ]; then
    echo "HOTLINE-SECRET-SUSPECT: 질문에 시크릿 의심 패턴 발견 — 대상 세션 로그에 영구 기록된다. 제거하거나 사용자 확인 후 진행:" >&2
    # F11: 매칭 값을 그대로 출력하면 발신측 로그에도 시크릿이 남는다 — 12자+ 토큰은 앞 4자만 남기고 마스킹
    printf '%s\n' "$hits" | sed -E 's/([A-Za-z0-9_+/-]{4})[A-Za-z0-9_+/.=-]{8,}/\1…(마스킹)/g' >&2
    exit 1
  fi
  echo "scan: 이상 없음"
}

# ═══ ask ══════════════════════════════════════════════════════════════
cmd_ask_codex() { # $1=세션ID $2=질문파일 → 답 stdout
  # 구조적 가드(리허설 3-1): codex 자문은 대상 원본 rollout에 append되는 비가역 동작.
  # 오케스트레이터가 echo-back 확인(사용자 확인)을 건너뛰어도 스크립트가 조용히 append하지 않게 명시 플래그 요구.
  if [ "${HOTLINE_CONFIRM:-0}" != "1" ]; then
    die "ask codex는 대상 세션 원본 기록에 append된다(비가역). echo-back 확인(대상 세션 되읽어 확인)을 받은 뒤 HOTLINE_CONFIRM=1 을 붙여 실행할 것"
  fi
  assert_session_id "$1"   # F5: glob·경로 인젝션 차단
  find_codex
  [ -f "$2" ] || die "질문 파일 없음: $2"
  local roll; roll="$(python3 -c 'import sys,os,glob; g=glob.glob(os.path.join(os.path.expanduser(sys.argv[1]),"*","*","*",f"rollout-*-{glob.escape(sys.argv[2])}.jsonl")); print(g[0] if g else "")' "$CODEX_SESSIONS" "$1")"
  [ -n "$roll" ] || die "Codex 세션 rollout을 못 찾음: $1 (삭제됐거나 id 오타)"
  warn_if_recent "$roll" "대상 Codex 세션 기록" "Codex 대상은 원본에 append되므로 열린 세션이면 기록 충돌 위험 — 사용자 확인 권장."
  # 주의: codex exec resume은 원본 rollout에 append한다(fork 불가 — 2026-07-05 실측)
  local ans err rc
  ans="$(mktemp -t hotline.XXXXXX)"; err="$(mktemp -t hotline.XXXXXX)"
  # F7: sandbox_mode=read-only는 파일 쓰기를 막는다(실측 확인). approval_policy=never로 승인 탈출까지 차단.
  #     단 MCP 커넥터·네트워크는 read-only가 완전히 닫지 못함 — SKILL.md '한계'에 정직 표기(과장 금지).
  SESSIONBRIDGE_DEPTH=1 perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    "$CODEX_BIN" exec resume "$1" --skip-git-repo-check -c sandbox_mode="read-only" -c approval_policy="never" \
    -o "$ans" - < "$2" >/dev/null 2>"$err"
  rc=$?
  if [ "$rc" -eq 142 ]; then rm -f "$ans" "$err"; die "타임아웃(${TIMEOUT}초) — 대상 세션이 너무 크거나 응답이 늦음. HOTLINE_TIMEOUT로 조정 가능"; fi
  if [ "$rc" -ne 0 ] || [ ! -s "$ans" ]; then
    # 비어있음 여부는 파일을 지우기 "전에" 판정 (지운 뒤 검사하면 항상 비어있음으로 오진)
    local empty_note=""; [ -s "$ans" ] || empty_note=" — 답변 비어있음"
    echo "--- codex stderr 꼬리 ---" >&2; tail -15 "$err" >&2; rm -f "$ans" "$err"
    die "codex 자문 실패(rc=$rc)${empty_note}. 힌트: 발신측이 Codex sandbox면 실행 권한 문제일 수 있음 — sandbox 밖 실행(approval)으로 재시도"
  fi
  cat "$ans"; rm -f "$ans" "$err"
}

cmd_ask_claude() { # $1=UUID $2=원래cwd $3=질문파일 → 답 stdout
  assert_session_id "$1"   # F5: glob·경로 인젝션 차단
  find_claude
  [ -f "$3" ] || die "질문 파일 없음: $3"
  [ -d "$2" ] || die "세션의 원래 작업 폴더가 없음: $2 (폴더가 이동·삭제되면 resume 불가 — 한계)"
  local jsonl; jsonl="$CLAUDE_PROJECTS/$(python3 -c "import re,sys; print(re.sub(r'[^A-Za-z0-9-]','-',sys.argv[1]))" "$2")/$1.jsonl"
  [ -f "$jsonl" ] || die "세션 파일이 없음: $jsonl (cwd-폴더 대조 실패 — id나 cwd가 틀렸을 수 있음)"
  warn_if_recent "$jsonl" "대상 Claude 세션 기록" "참고: Claude 대상은 fork(분신) 자문이라 원본 충돌 위험은 낮다. 대신 이 질문·답은 원본 세션 화면에 표시되지 않는다(전달 아님)."
  local rc out err
  err="$(mktemp -t hotline.XXXXXX)"
  # 검증된 read-only 조합(2026-07-05 실측): fork(원본 미변경) + 도구 allowlist + MCP 차단.
  # --tools만으론 MCP 쓰기도구(Notion·Drive)가 살아있어 --strict-mcp-config 필수.
  # F6: 질문을 argv(-p "$q")가 아니라 stdin으로 — ps 노출·ARG_MAX 회피(claude -p는 stdin 프롬프트를 읽음, 실측)
  out="$(cd "$2" && SESSIONBRIDGE_DEPTH=1 perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" \
    "$CLAUDE_BIN" --resume "$1" --fork-session --tools "Read,Grep,Glob" --strict-mcp-config \
    -p < "$3" 2>"$err")"
  rc=$?
  if [ "$rc" -eq 142 ]; then rm -f "$err"; die "타임아웃(${TIMEOUT}초) — 큰 세션은 12MB/15초 실측이 기준이지만 상황 따라 늦을 수 있음. HOTLINE_TIMEOUT로 조정"; fi
  if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
    echo "--- claude stderr 꼬리 ---" >&2; tail -15 "$err" >&2; rm -f "$err"
    die "claude 자문 실패(rc=$rc)$([ -n "$out" ] || echo ' — 답변 비어있음'). 힌트: Codex 발신에서 rc=1이면 발신측 sandbox가 홈 디렉토리(~/.claude) 접근을 막았을 가능성부터 의심 — sandbox 밖 실행(approval)으로 재시도(실측 2026-07-05)"
  fi
  printf '%s\n' "$out"; rm -f "$err"
}

# ═══ dispatch ═════════════════════════════════════════════════════════
case "${1:-}" in
  doctor)  cmd_doctor ;;
  resolve)
    case "${2:-}" in
      claude) [ -n "${3:-}" ] || die "사용법: resolve claude <제목|UUID>"; cmd_resolve_claude "$3" ;;
      codex)  [ -n "${3:-}" ] || die "사용법: resolve codex <이름|ID>";  cmd_resolve_codex "$3" ;;
      *) die "resolve 대상은 claude|codex" ;;
    esac ;;
  scan) [ -n "${2:-}" ] || die "사용법: scan <질문파일>"; cmd_scan "$2" ;;
  ask)
    case "${2:-}" in
      codex)  [ -n "${3:-}" ] && [ -n "${4:-}" ] || die "사용법: ask codex <ID> <질문파일>"; cmd_ask_codex "$3" "$4" ;;
      claude) [ -n "${3:-}" ] && [ -n "${4:-}" ] && [ -n "${5:-}" ] || die "사용법: ask claude <UUID> <CWD> <질문파일>"; cmd_ask_claude "$3" "$4" "$5" ;;
      *) die "ask 대상은 claude|codex" ;;
    esac ;;
  *) die "사용법: hotline.sh doctor | resolve claude|codex <이름|id> | scan <파일> | ask codex <ID> <파일> | ask claude <UUID> <CWD> <파일>" ;;
esac
