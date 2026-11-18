# python3 tally.py FILE... — pick accuracy per variant, split by where the gold sits.
import json, sys, collections
for path in sys.argv[1:]:
    rows = [json.loads(l) for l in open(path)]
    by = collections.defaultdict(list)
    for r in rows: by[r['variant']].append(r)
    print(f"== {path}  ({len(rows)} picks)")
    print(f"{'variant':9}{'n':>5}{'right':>7}{'gold #1':>9}{'right':>7}{'gold >#1':>10}{'right':>7}{'no gold':>9}{'said 0':>8}{'no reply':>10}")
    for v in ['none', 'cosine', 'labels', 'union10', 'vfirst']:
        rs = by.get(v, [])
        if not rs: continue
        g1 = [r for r in rs if r['gold_hits'] and min(r['gold_hits']) == 1]
        gl = [r for r in rs if r['gold_hits'] and min(r['gold_hits']) > 1]
        ng = [r for r in rs if not r['gold_hits']]
        print(f"{v:9}{len(rs):5}{sum(r['correct'] for r in rs):7}{len(g1):9}{sum(r['correct'] for r in g1):7}"
              f"{len(gl):10}{sum(r['correct'] for r in gl):7}{len(ng):9}{sum(r['pick'] == 0 for r in ng):8}"
              f"{sum(r['pick'] is None for r in rs):10}")
    print()
