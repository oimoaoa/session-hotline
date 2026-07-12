import json, os, re, sys, glob

# Claude 대화방 해석기 — 검색원 2개 병합:
#  1) 데스크탑 앱 저장소(~/Library/Application Support/Claude/claude-code-sessions/*/*/local_*.json)
#     → 자동 생성 제목 포함 + local_ id(send_message 주소) ↔ 파일 UUID 매핑 (실측 발견 2026-07-06)
#  2) ~/.claude/projects/*/*.jsonl (customTitle — 사용자가 수정한 제목만 있음)
# 데스크탑 저장소가 없거나 깨져도 2)만으로 동작(자동 제목만 못 찾게 됨 — 조용히 죽지 않음).
projects, query = os.path.expanduser(sys.argv[1]), sys.argv[2].strip()
store = os.path.expanduser(os.environ.get('HOTLINE_CLAUDE_DESKTOP_STORE',
        '~/Library/Application Support/Claude/claude-code-sessions'))
# 따옴표로 감싼 이름은 벗긴다 (모델이 따옴표째 넘겨도 안전하게)
for a, b in [('"','"'), ("'","'"), ('「','」'), ('『','』'), ('“','”'), ('‘','’')]:
    if len(query) >= 2 and query.startswith(a) and query.endswith(b):
        query = query[1:-1].strip(); break
# 공백만 있는 쿼리는 strip 후 빈 문자열이 되어 모든 제목에 substring 매칭(F3) — 전체 세션 노출 차단
if not query:
    print(json.dumps({'match_type': 'none', 'candidates': [], 'suggestions': [],
                      'error': '빈 이름(공백만) — 대화방 이름이나 id를 정확히 줘'}, ensure_ascii=False))
    sys.exit(1)
# 실측 규칙(2026-07-05): 폴더명 = launch cwd에서 [A-Za-z0-9-] 외 전부 '-' 치환
enc = lambda p: re.sub(r'[^A-Za-z0-9-]', '-', p)

def first_user_text(msg):
    # user 메시지 content에서 텍스트를 뽑아 한 줄 60자로 (이름없는 세션 preview 표시용)
    c = msg.get('content') if isinstance(msg, dict) else None
    txt = ''
    if isinstance(c, str):
        txt = c
    elif isinstance(c, list):
        for it in c:
            if isinstance(it, str): txt = it; break
            if isinstance(it, dict) and it.get('type') == 'text': txt = it.get('text', ''); break
    txt = ' '.join(txt[:200].split())  # 개행·연속공백 정리(앞 200자만 처리 — 긴 메시지 방어)
    # 시스템 주입(슬래시커맨드 caveat·command 래퍼)은 식별력 없으니 스킵 → 루프가 다음 user 메시지를 preview로 시도
    # (2026-07-12 리허설: 첫 user가 "<local-command-caveat>Caveat:..."로 잡혀 preview가 무의미한 세션 발견)
    if txt.startswith(('<local-command', '<command-', 'Caveat:', '<system-')):
        return None
    return txt[:60] or None
uuid_re = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)
local_re = re.compile(r'^local_[0-9a-f-]{36}$', re.I)
by_uuid, by_local = bool(uuid_re.match(query)), bool(local_re.match(query))

sessions = {}  # 파일 UUID → entry
skipped_jsonl = skipped_desktop = 0  # F9: 조용한 누락 방지 — 파싱 실패 수를 출력에 노출

# ── 검색원 1: jsonl (cwd는 반드시 "첫" 필드 = launch cwd — 마지막 필드는 세션 중 이동을 따라감)
for f in glob.glob(os.path.join(projects, '*', '*.jsonl')):
    sid = os.path.splitext(os.path.basename(f))[0]
    if by_uuid and sid.lower() != query.lower():
        continue
    first_cwd, title, preview = None, None, None
    try:
        with open(f, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                if first_cwd is None and '"cwd"' in line:
                    try: first_cwd = json.loads(line).get('cwd') or first_cwd
                    except Exception: pass
                # preview = 첫 user 메시지 앞 60자(이름없는 세션 식별용 — 전체 Read 안 함, 첫 user에서 멈춤)
                if preview is None and ('"type":"user"' in line or '"type": "user"' in line):
                    try:
                        o = json.loads(line)
                        if o.get('type') == 'user': preview = first_user_text(o.get('message'))
                    except Exception: pass
                if '"customTitle"' in line:  # 마지막 customTitle = 현재 커스텀 제목
                    try: title = json.loads(line).get('customTitle') or title
                    except Exception: pass
    except OSError:
        skipped_jsonl += 1; continue
    folder = os.path.basename(os.path.dirname(f))
    sessions[sid] = {
        'uuid': sid, 'title': title, 'custom_title': title, 'cwd': first_cwd, 'folder': folder,
        'preview': preview,
        'cwd_folder_match': bool(first_cwd) and enc(first_cwd) == folder,
        'mtime': int(os.path.getmtime(f)), 'file': f,
        'size_mb': round(os.path.getsize(f) / 1048576, 1),
        'local_id': None, 'title_source': 'custom' if title else None, 'resumable': True,
    }

# ── 검색원 2: 데스크탑 앱 저장소 병합 (제목은 이쪽이 "현재 UI 제목" — 표시·매칭에 우선)
for f in glob.glob(os.path.join(store, '*', '*', 'local_*.json')):
    try:
        v = json.load(open(f, encoding='utf-8'))
    except Exception:
        skipped_desktop += 1; continue
    u = v.get('cliSessionId')
    if not u:
        continue
    if by_uuid and u.lower() != query.lower():
        continue
    e = sessions.get(u)
    if e is None:
        # jsonl을 못 찾은 세션 — 이름·매핑 정보는 주되 CLI resume 가능성은 미확인으로 표시
        sessions[u] = e = {
            'uuid': u, 'title': None, 'custom_title': None, 'cwd': v.get('cwd'),
            'folder': None, 'preview': None, 'cwd_folder_match': False, 'mtime': 0, 'file': None,
            'size_mb': None, 'local_id': None, 'title_source': None, 'resumable': False,
        }
    dtitle = v.get('title')
    if dtitle:
        e['title'] = dtitle
        e['title_source'] = v.get('titleSource') or e['title_source']
    e['local_id'] = v.get('sessionId')
    e['archived'] = bool(v.get('isArchived'))
    la = v.get('lastActivityAt')
    if isinstance(la, (int, float)) and la > 0:
        e['mtime'] = max(e['mtime'], int(la / 1000))

allsess = list(sessions.values())

# ── 매칭: uuid/local_ 직접 > 완전일치 > substring(대소문자 무시) > token-AND
def pick():
    if by_uuid:
        return 'uuid', [s for s in allsess if s['uuid'].lower() == query.lower()]
    if by_local:
        return 'local_id', [s for s in allsess if (s.get('local_id') or '').lower() == query.lower()]
    titled = [s for s in allsess if s['title']]
    exact = [s for s in titled if s['title'].strip() == query]
    if exact: return 'exact', exact
    sub = [s for s in titled if query.lower() in s['title'].lower()]
    if sub: return 'substring', sub
    toks = [t.lower() for t in query.split()]
    tok = [s for s in titled if toks and all(t in s['title'].lower() for t in toks)]
    if tok: return 'token', tok
    # 이름(title) 매칭 0건 → 이름없는 CLI 세션(title-0) cwd 폴백.
    # 안전장치: archived 제외 + 쿼리가 폴더명(cwd basename)에 들어갈 때만(전체 title-0 쏟아냄 방지).
    qn = query.lower()
    cwd_hit = [s for s in allsess
               if not s['title'] and not s.get('archived') and s.get('cwd')
               and qn in os.path.basename(s['cwd']).lower()]
    if cwd_hit: return 'cwd', cwd_hit
    return 'none', []

mt, cands = pick()
cands.sort(key=lambda c: -c['mtime'])
# cwd 폴백은 같은 폴더에 세션이 대량일 수 있어 최근순 상한(preview로도 다 못 가림) — 넘치면 개수만 알림
cwd_truncated = 0
if mt == 'cwd' and len(cands) > 8:
    cwd_truncated = len(cands); cands = cands[:8]
# 이름없는 세션 후보엔 표시이름(폴더명)을 실어보낸다(사람이 CLI 피커처럼 알아보게)
for c in cands:
    if not c['title'] and c.get('cwd'):
        c['display_name'] = os.path.basename(c['cwd'])
suggestions = []
if mt == 'exact':  # 유사 제목 경고: "X"와 "X 2" 오지목 방지 (제목 중복 제거)
    near, seen = [], set()
    for s in allsess:
        t = (s['title'] or '').strip()
        if t and query.lower() in t.lower() and t != query and t not in seen:
            seen.add(t); near.append(s)
    suggestions = [{'title': s['title'], 'uuid': s['uuid'][:8], 'mtime': s['mtime']} for s in near[:3]]
if not cands:  # did-you-mean: 토큰 겹침 많은 순 상위 5
    toks = [t.lower() for t in query.split()]
    scored = [(sum(1 for t in toks if t in (s['title'] or '').lower()), s) for s in allsess if s['title']]
    scored = [x for x in scored if x[0] > 0]
    scored.sort(key=lambda x: (-x[0], -x[1]['mtime']))
    suggestions = [{'title': s['title'], 'uuid': s['uuid'][:8], 'mtime': s['mtime']} for _, s in scored[:5]]
print(json.dumps({'match_type': mt, 'desktop_store': os.path.isdir(store),
                  'candidates': cands, 'suggestions': suggestions,
                  'cwd_truncated': cwd_truncated,
                  'skipped_jsonl': skipped_jsonl, 'skipped_desktop': skipped_desktop},
                 ensure_ascii=False, indent=1))
sys.exit(0 if len(cands) == 1 else (1 if not cands else 2))
