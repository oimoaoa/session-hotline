#!/usr/bin/env bash
# 핫라인(session-hotline) 설치 스크립트 — macOS 전용
# 하는 일: ①스크립트를 ~/.session-hotline/에 복사 ②스킬을 Claude Code·Codex 양쪽에 등록 ③자가진단
set -eu
# F4: macOS 전용 — 다른 OS에선 나중에 stat -f 등에서 깨지므로 처음부터 명확히 실패
[ "$(uname -s)" = "Darwin" ] || { echo "❌ 핫라인은 macOS 전용입니다(uname=$(uname -s)). 내부 세션 포맷·stat -f·앱 경로가 macOS 전용이라 지원하지 않습니다." >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "📞 핫라인 설치 시작"
mkdir -p "$HOME/.session-hotline"
# F10: 기존 파일이 다르면 백업 후 덮어씀 — 커스텀한 내용이 조용히 날아가지 않게 (스크립트도 스킬과 동일 보호)
for f in hotline.sh resolve_claude.py resolve_codex.py; do
  dest="$HOME/.session-hotline/$f"
  if [ -f "$dest" ] && ! cmp -s "$SRC/$f" "$dest"; then
    bak="$dest.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$dest" "$bak"
    echo "  ⚠ 기존 $f 이(가) 달라 백업함: ${bak#$HOME/}"
  fi
  cp "$SRC/$f" "$dest"
done
chmod +x "$HOME/.session-hotline/hotline.sh"
echo "  ✓ 스크립트: ~/.session-hotline/hotline.sh"

for host in .claude .codex; do
  if [ -d "$HOME/$host" ]; then
    mkdir -p "$HOME/$host/skills/session-hotline"
    dest="$HOME/$host/skills/session-hotline/SKILL.md"
    # F10: 기존 SKILL이 다르면 백업 후 덮어씀 — 커스텀한 내용이 조용히 날아가지 않게
    if [ -f "$dest" ] && ! cmp -s "$SRC/skills/SKILL.md" "$dest"; then
      bak="$dest.backup-$(date +%Y%m%d-%H%M%S)"
      cp "$dest" "$bak"
      echo "  ⚠ 기존 SKILL.md가 달라 백업함: ${bak#$HOME/}"
    fi
    cp "$SRC/skills/SKILL.md" "$dest"
    echo "  ✓ 스킬 등록: ~/$host/skills/session-hotline/"
  else
    echo "  - ~/$host 없음 → 건너뜀 (해당 앱 미설치)"
  fi
done

echo ""
echo "🩺 자가진단(doctor) 실행:"
bash "$HOME/.session-hotline/hotline.sh" doctor || {
  echo ""
  echo "위 ❌ 항목이 있으면 README의 '문제 해결'을 확인하세요."
  exit 1
}
echo ""
echo "✅ 설치 완료! 이제 AI한테 이렇게 말해보세요:"
echo '   핫라인 코덱스 "세션 제목"에 물어봐: 궁금한 것'
