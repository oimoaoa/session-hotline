import json, os, re, sys, glob
idx, sessions, query = os.path.expanduser(sys.argv[1]), os.path.expanduser(sys.argv[2]), sys.argv[3].strip()
for a, b in [('"','"'), ("'","'"), ('「','」'), ('『','』'), ('“','”'), ('‘','’')]:
    if len(query) >= 2 and query.startswith(a) and query.endswith(b):
        query = query[1:-1].strip(); break
# 공백만 있는 쿼리는 strip 후 빈 문자열이 되어 모든 제목에 substring 매칭(F3) — 전체 세션 노출 차단
if not query:
    print(json.dumps({'match_type': 'none', 'candidates': [], 'suggestions': [],
                      'error': '빈 이름(공백만) — 대화방 이름이나 id를 정확히 줘'}, ensure_ascii=False))
    sys.exit(1)
best = {}  # id → (thread_name, updated_at) : updated_at 최신만 남김(리네임 로그 중복 접기)
skipped = 0  # F9: 파싱 실패한 인덱스 줄 수(조용한 누락 방지 — 출력에 노출)
if os.path.exists(idx):
    with open(idx, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line: continue
            try: v = json.loads(line)
            except Exception: skipped += 1; continue
            i, u = v.get('id'), v.get('updated_at') or ''
            if i and (i not in best or u > best[i][1]):
                best[i] = (v.get('thread_name'), u)
def rollout(i):
    g = glob.glob(os.path.join(sessions, '*', '*', '*', f'rollout-*-{glob.escape(i)}.jsonl'))  # F5: glob 메타문자 방어
    return g[0] if g else None
def entry(i, n, u):
    r = rollout(i)
    return {'id': i, 'title': n, 'updated_at': u, 'rollout': r,
            'resumable': bool(r),  # F8: rollout 없으면 이름만 남은 stale 인덱스 — 이어받기 불가
            'mtime': int(os.path.getmtime(r)) if r else None}
uuid_re = re.compile(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$', re.I)
mt, cands = 'none', []
if uuid_re.match(query):  # id 직접지정 = primary path (인덱스 미등록 세션도 rollout 존재하면 OK)
    query = query.lower()  # F12: rollout 파일명·인덱스 키는 소문자 hex — 대문자 UUID도 매칭되게 정규화
    if rollout(query):
        n, u = best.get(query, (None, ''))
        mt, cands = 'uuid', [entry(query, n, u)]
else:
    named = [(i, n, u) for i, (n, u) in best.items() if n]
    exact = [x for x in named if x[1].strip() == query]
    sub = [x for x in named if query.lower() in x[1].lower()]
    toks = [t.lower() for t in query.split()]
    tok = [x for x in named if toks and all(t in x[1].lower() for t in toks)]
    for m, group in [('exact', exact), ('substring', sub), ('token', tok)]:
        if group:
            mt, cands = m, [entry(i, n, u) for i, n, u in group]; break
suggestions = []
if mt == 'exact':  # 유사 제목 경고 (오지목 방지)
    near = [x for x in sub if x[1].strip() != query]
    suggestions = [{'title': n, 'id': i[:8], 'updated_at': u} for i, n, u in near[:3]]
if not cands and not uuid_re.match(query):
    toks = [t.lower() for t in query.split()]
    scored = [(sum(1 for t in toks if t in n.lower()), i, n, u) for i, (n, u) in best.items() if n]
    scored = [x for x in scored if x[0] > 0]
    scored.sort(key=lambda x: (x[0], x[3]), reverse=True)  # 겹침 많은 순 → 동점이면 최신 순 (resolve_claude와 동일)
    suggestions = [{'title': n, 'id': i[:8], 'updated_at': u} for _, i, n, u in scored[:5]]
cands.sort(key=lambda c: c['updated_at'] or '', reverse=True)
print(json.dumps({'match_type': mt, 'candidates': cands, 'suggestions': suggestions,
                  'skipped_index_lines': skipped}, ensure_ascii=False, indent=1))
sys.exit(0 if len(cands) == 1 else (1 if not cands else 2))
