#!/usr/bin/env bash
# 핫라인(session-hotline) 설치 스크립트 — macOS 전용
# 하는 일: ①스크립트·스킬을 심볼릭 링크(symlink)로 연결 ②Claude Code·Codex 양쪽에 등록 ③자가진단
# 심링크라 이 폴더에서 `git pull`만 받으면 재설치 없이 최신이 반영됩니다(복사 아님).
set -eu
# F4: macOS 전용 — 다른 OS에선 나중에 stat -f 등에서 깨지므로 처음부터 명확히 실패
[ "$(uname -s)" = "Darwin" ] || { echo "❌ 핫라인은 macOS 전용입니다(uname=$(uname -s)). 내부 세션 포맷·stat -f·앱 경로가 macOS 전용이라 지원하지 않습니다." >&2; exit 1; }
SRC="$(cd "$(dirname "$0")" && pwd)"

echo "📞 핫라인 설치 시작 (심볼릭 링크 방식)"
echo "  원본 폴더: ${SRC/#$HOME/~}"

# 원본 파일 → 지정 위치에 심볼릭 링크. F10: 기존에 '복사'로 깔린 실제 파일(옛 방식·직접 커스텀)이 다르면
# 링크로 바꾸기 전에 백업 — 손댄 내용이 조용히 사라지지 않게.
link_file() { # $1=원본 절대경로, $2=링크 놓을 절대경로
  src="$1"; dest="$2"
  if [ -e "$dest" ] && [ ! -L "$dest" ] && ! cmp -s "$src" "$dest"; then
    bak="$dest.backup-$(date +%Y%m%d-%H%M%S)"
    cp "$dest" "$bak"
    echo "  ⚠ 기존 복사본이 달라 백업함: ${bak/#$HOME/~}"
  fi
  ln -sfn "$src" "$dest"
}

mkdir -p "$HOME/.session-hotline"
# hotline.sh 는 resolve_claude.py·resolve_codex.py 와 같은 폴더에 있어야 대화방 이름을 찾음 → 셋 다 같은 곳에 링크
for f in hotline.sh resolve_claude.py resolve_codex.py; do
  link_file "$SRC/$f" "$HOME/.session-hotline/$f"
done
chmod +x "$SRC/hotline.sh"
echo "  ✓ 스크립트 링크: ~/.session-hotline/ → 원본 3개 파일"

for host in .claude .codex; do
  if [ -d "$HOME/$host" ]; then
    mkdir -p "$HOME/$host/skills/session-hotline"
    link_file "$SRC/skills/SKILL.md" "$HOME/$host/skills/session-hotline/SKILL.md"
    echo "  ✓ 스킬 링크: ~/$host/skills/session-hotline/"
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
echo "✅ 설치 완료! (심볼릭 링크)"
echo "   • 원본 폴더 ${SRC/#$HOME/~} 는 지우거나 옮기지 마세요 — 앱이 이 폴더를 가리킵니다."
echo "   • 업데이트는 이 폴더에서:  cd ${SRC/#$HOME/~} && git pull   (재설치 불필요)"
echo ""
echo "   이제 AI한테 이렇게 말해보세요:"
echo '   핫라인 코덱스 "세션 제목"에 물어봐: 궁금한 것'
