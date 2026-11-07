"""Summarises a `carrot-eval sim --docs Eval/corpus.json --log run.jsonl` run.

    python3 Eval/analyze.py Eval/corpus.json run.jsonl [samples.txt]

Prints savings and accuracy per kind of writing, how well the model's confidence predicts a right
suggestion, and word-by-word accuracy; with a third argument, writes a fixed random sample of wrong
and partly right suggestions for reading by hand.
"""
import json, sys, random, re
from collections import defaultdict

corpus = {d["id"]: d for d in json.load(open(sys.argv[1]))}
events = [json.loads(l) for l in open(sys.argv[2])]

def presses(e):
    if e["accepted"] == 0: return 0
    if e["accepted"] >= len(e["suggestion"]): return 1
    return max(1, len(e["suggestion"][:e["accepted"]].split()))

def words(s): return len(s.split())

genre_of = {i: d["genre"] for i, d in corpus.items()}
group = lambda g: {"email-work": "email", "email-personal": "email", "chinese": "other-lang", "spanish": "other-lang", "french": "other-lang"}.get(g, g)

stats = defaultdict(lambda: defaultdict(float))
for i, d in corpus.items():
    stats[group(d["genre"])]["chars"] += len(d["text"])
    stats["ALL"]["chars"] += len(d["text"])
for e in events:
    for g in (group(e["genre"]), "ALL"):
        s = stats[g]
        s["shown"] += 1
        s["accepted"] += e["accepted"]
        s["presses"] += presses(e)
        s["right"] += e["accepted"] > 0
        s["full"] += e["full"]
        s["words"] += words(e["suggestion"])

print(f"{'genre':14} {'saved':>6} {'1st right':>9} {'to end':>7} {'shown/100k':>10} {'words':>6} {'n':>5}")
for g in sorted(stats, key=lambda g: (g == "ALL", g)):
    s = stats[g]
    keys = s["chars"] - s["accepted"] + s["presses"]
    print(f"{g:14} {100*(s['chars']-keys)/s['chars']:5.1f}% {100*s['right']/max(1,s['shown']):8.1f}% {100*s['full']/max(1,s['shown']):6.1f}% "
          f"{100*s['shown']/keys:9.1f} {s['words']/max(1,s['shown']):6.1f} {int(s['shown']):5}")

# Calibration: is the model's confidence a good guide?
print("\nfirst-word probability vs. first word right:")
for lo, hi in [(0, .5), (.5, .6), (.6, .7), (.7, .8), (.8, .9), (.9, .97), (.97, 1.01)]:
    b = [e for e in events if lo <= e["first"] < hi]
    if b: print(f"  {lo:.2f}-{min(hi,1):.2f}: {100*sum(e['accepted']>0 for e in b)/len(b):5.1f}% of {len(b)}")
print("whole-suggestion probability vs. right to the end:")
for lo, hi in [(0, .02), (.02, .05), (.05, .1), (.1, .2), (.2, .4), (.4, .7), (.7, 1.01)]:
    b = [e for e in events if lo <= e["p"] < hi]
    if b: print(f"  {lo:.2f}-{min(hi,1):.2f}: {100*sum(e['full'] for e in b)/len(b):5.1f}% of {len(b)}  (avg {sum(words(e['suggestion']) for e in b)/len(b):.1f} words)")

# Mid-word completions vs. new words.
for name, sel in [("mid-word", lambda e: e["midWord"]), ("new word", lambda e: not e["midWord"])]:
    b = [e for e in events if sel(e)]
    if b: print(f"{name}: {len(b)} shown, first right {100*sum(e['accepted']>0 for e in b)/len(b):.1f}%, to end {100*sum(e['full'] for e in b)/len(b):.1f}%")

# Word by word: given the first k words were right, how often is word k+1 right?
print("\nword-by-word survival (suggestions with at least k+1 words):")
for k in range(0, 5):
    b = [e for e in events if words(e["suggestion"]) > k]
    ok = 0; base = 0
    for e in b:
        sw = re.findall(r"\S+\s*", e["suggestion"])
        upto = "".join(sw[:k]); nxt = "".join(sw[:k+1])
        truth = e["truth"]
        if truth.startswith(upto.rstrip()) or k == 0:
            base += 1
            if truth.startswith(nxt.rstrip()): ok += 1
    if base: print(f"  word {k+1}: right {100*ok/base:5.1f}% of {base}")

# Samples to judge by hand (fixed seed).
random.seed(7)
wrong = [e for e in events if e["accepted"] == 0]
partial = [e for e in events if e["accepted"] > 0 and not e["full"]]
def show(e):
    tail = e["prefix"][-70:].replace("\n", "⏎")
    return f"[{e['genre']}] …{tail}⟨{e['suggestion'].replace(chr(10), '⏎')}⟩  truth: {e['truth'][:40].replace(chr(10), '⏎')}"
if len(sys.argv) > 3:
    with open(sys.argv[3], "w") as f:
        for n, e in enumerate(random.sample(wrong, min(150, len(wrong)))): f.write(f"W{n+1}: {show(e)}\n")
        for n, e in enumerate(random.sample(partial, min(60, len(partial)))): f.write(f"P{n+1}: {show(e)}\n")
    print(f"\nwrote samples: {min(150,len(wrong))} wrong of {len(wrong)}, {min(60,len(partial))} partial of {len(partial)}")
