#!/usr/bin/env python3
"""zbench-agg.py v2 -- aggregate the Zero-vs-NextUI benchmark into head-to-head tables. Stdlib only.

Reads everything zbench-*.sh + fpslog.so + auto.sh produce, from one or more directories:
  <fw>_<wl>_<stamp>.csv  sensor log (original 10-col or v2 20/21-col; header-driven, both pool)
  <fw>_<wl>_<stamp>.fps  fpslog.so: "first_present uptime=U ..." then per-second
                         "<t> render=R swap=S maxgap_ms=G late=L"
  <fw>_<wl>_<stamp>.log  the game's own log (Zero: MEASURE lines; NextUI: "total startup time")
  boot-times.log         auto.sh boot receipts: "... hook_up=X menu_up=Y menu=<binary>"
Usage: python3 zbench-agg.py <dir> [<dir> ...]
Conventions: steady state = last 40% of samples; drain from Discharging rows only (any other status
flags the run); shim fps = the firmware's own present call (Zero render, NextUI swap), first 5 s
skipped as warm-up; runs tagged *preflight* are excluded from tables.
"""
import csv, glob, os, sys, re, statistics as st
from collections import Counter, defaultdict

def num(v):
    try: return float(v)
    except (TypeError, ValueError): return None

def mean(vals):
    vals = [v for v in vals if v is not None]
    return st.mean(vals) if vals else None

def parse_csv(path):
    meta = {}; rows = []
    with open(path) as f:
        for line in f:
            if line.startswith('#'):
                for tok in line[1:].split():
                    if '=' in tok:
                        k, v = tok.split('=', 1); meta[k] = v
                continue
            if line.startswith('elapsed_s'):
                rows = list(csv.DictReader(f, fieldnames=line.strip().split(',')))
                break
    return meta, rows

def parse_fps(path, launch_up):
    if not os.path.exists(path): return {}
    firsts = {}; pts = []
    with open(path) as f:
        for line in f:
            if line.startswith('first_present'):
                # "first_present <render|swap> uptime=U ..." (per hook; older shim: no kind -> 'any')
                toks = line.split()
                kind = toks[1] if len(toks) > 2 and toks[1] in ('render', 'swap') else 'any'
                m = re.search(r'uptime=([0-9.]+)', line)
                if m: firsts[kind] = float(m.group(1))
                continue
            parts = line.split()
            if not parts: continue
            d = {'t': num(parts[0])}
            for p in parts[1:]:
                if '=' in p:
                    k, v = p.split('=', 1); d[k] = num(v)
            if d['t'] is not None: pts.append(d)
    if not pts and not firsts: return {}
    t0 = pts[0]['t'] if pts else None
    body = [p for p in pts if t0 is None or p['t'] - t0 >= 5.0] or pts
    render = mean(p.get('render') for p in body); swap = mean(p.get('swap') for p in body)
    late = sum(int(p.get('late') or 0) for p in body); secs = len(body)
    worst = max((p.get('maxgap_ms') or 0) for p in body) if body else None
    fps = which = None
    if render is not None or swap is not None:
        r = render or 0; s = swap or 0
        fps, which = (r, 'render') if r >= s else (s, 'swap')
    # launch latency = first present of the GAME's own hook (NextUI draws a loading screen via the
    # other hook first), falling back to whatever the shim logged.
    first = firsts.get(which) if which else None
    if first is None and firsts: first = firsts.get('any', next(iter(firsts.values())))
    lat = (first - launch_up) if (first is not None and launch_up is not None) else None
    return dict(fps=fps, which=which, late=late, late_pm=(late / (secs / 60.0) if secs else None),
                worst_gap=worst, first_present=first, launch_lat=lat, secs=secs)

def parse_log(path):
    if not os.path.exists(path): return {}
    fps = []; dup = []; und = []; use = []; ceil = Counter(); tgt = None; startup = None; crop = False
    with open(path, errors='replace') as f:
        for line in f:
            if 'MEASURE' in line:
                for tok in line.split():
                    if tok.startswith('fps='):
                        a, _, b = tok[4:].partition('/'); v = num(a); t = num(b)
                        if v is not None: fps.append(v)
                        if t is not None: tgt = t
                    elif tok.startswith('dup/s='): dup.append(num(tok[6:]) or 0)
                    elif tok.startswith('under/s='): und.append(num(tok[8:]) or 0)
                    elif tok.startswith('ceil='): ceil[tok[5:]] += 1
                    elif tok.startswith('use='): use.append(num(tok[4:]) or 0)
            elif 'total startup time' in line:
                m = re.search(r'(\d+)\s*ms', line)
                if m: startup = int(m.group(1))
            if 'clamped dst_h' in line and '-> 720' in line: crop = True
    d = {'startup_ms': startup, 'crop': crop}
    if fps:
        k = max(1, len(fps) // 10)   # warm-up
        d.update(m_fps=mean(fps[k:]), m_tgt=tgt, m_dup=mean(dup[k:]), m_under=mean(und[k:]),
                 m_use=mean(use[k:]), m_ceil=(ceil.most_common(1)[0][0] if ceil else None), m_n=len(fps))
    return d

def summarize(path):
    meta, rows = parse_csv(path)
    fw = meta.get('fw'); wl = meta.get('workload')
    if not fw or not wl or 'preflight' in fw: return None
    rows = [r for r in rows if num(r.get('cpu_mc')) is not None]
    if len(rows) < 5: return None
    n = len(rows); tail = rows[int(n * 0.6):]
    def zc(rs, k): return mean(num(r.get(k)) for r in rs)
    def zone(rs, k):
        v = zc(rs, k); return v / 1000.0 if v is not None else None
    disch = [r for r in rows if r.get('status') == 'Discharging']
    charging = any((r.get('status') or 'Discharging') != 'Discharging' for r in rows)
    pph = mvph = None
    if len(disch) >= 2:
        t0, t1 = num(disch[0]['elapsed_s']), num(disch[-1]['elapsed_s']); hrs = (t1 - t0) / 3600.0
        if hrs > 0.02:
            p0, p1 = num(disch[0]['batt_pct']), num(disch[-1]['batt_pct'])
            v0, v1 = num(disch[0]['batt_uv']), num(disch[-1]['batt_uv'])
            if p0 is not None and p1 is not None: pph = (p0 - p1) / hrs
            if v0 is not None and v1 is not None: mvph = (v0 - v1) / 1000.0 / hrs
    clocks = Counter(int(num(r['cur_khz']) // 1000) for r in rows if num(r.get('cur_khz')))
    busy = zc(tail, 'cpu_busy')
    if busy is None: busy = zc(tail, 'cpu_pct')
    bl = [num(r.get('backlight')) for r in rows if num(r.get('backlight')) is not None]
    fbb = [num(r.get('fb_blank')) for r in rows if num(r.get('fb_blank')) is not None]
    gpm = Counter((r.get('gpu_pm') or '').strip() for r in rows if (r.get('gpu_pm') or '').strip())
    base = path[:-4]
    d = dict(fw=fw, wl=wl, file=os.path.basename(path), n=n, gov=meta.get('gov'), max0=meta.get('max0'),
             prelaunch=meta.get('prelaunch'), devfreq=meta.get('devfreq'),
             cpu=zone(tail, 'cpu_mc'), gpu=zone(tail, 'gpu_mc'), ddr=zone(tail, 'ddr_mc'), bat=zone(tail, 'bat_mc'),
             cpu_peak=max(num(r['cpu_mc']) for r in rows) / 1000.0,
             clk=mean(int(num(r['cur_khz']) // 1000) for r in rows if num(r.get('cur_khz'))), clocks=clocks,
             busy=busy, cores=[zc(tail, f'c{i}_busy') for i in range(4)],
             irq=zc(tail, 'irq_s'), ctxt=zc(tail, 'ctxt_s'), df0=zc(tail, 'df0_hz'), df1=zc(tail, 'df1_hz'),
             bl_min=(min(bl) if bl else None), bl_max=(max(bl) if bl else None),
             fb_blank=(max(fbb) if fbb else None), gpu_pm=gpm, pph=pph, mvph=mvph, charging=charging)
    d.update(parse_fps(base + '.fps', num(meta.get('launch_up'))))
    d.update(parse_log(base + '.log'))
    # Firmware with loop telemetry (Zero): frame-hold comes from MEASURE (loop fps; under/s = frames
    # that missed budget). Its shim present count is UNIQUE frames only, because present-skip
    # (ZERO_DUP_SKIP) does not re-present identical frames, so shim late/gap there = skipped dupes,
    # not stutter. Keep it as uniq_ps; NextUI (no skip) keeps the shim as fps/late.
    if d.get('m_fps') is not None:
        d['uniq_ps'] = d.get('fps')
        d['fps'] = d['m_fps']; d['late_pm'] = (d.get('m_under') or 0) * 60.0; d['worst_gap'] = None
    else:
        d['uniq_ps'] = None
    return d

def msd(vals, w=7, p=1):
    vals = [v for v in vals if v is not None]
    if not vals: return 'n/a'.rjust(w)
    if len(vals) == 1: return f"{vals[0]:{w}.{p}f}"
    return f"{st.mean(vals):{w}.{p}f}±{st.pstdev(vals):.{p}f}"

def govstr(r):
    m = r.get('max0')
    if m and str(m).isdigit(): m = str(int(m) // 1000)
    return f"{r.get('gov')}/{m}"

def main():
    dirs = [a for a in sys.argv[1:] if not a.startswith('--')]
    if not dirs: print(__doc__); sys.exit(1)
    runs = []; boots = []
    for d in dirs:
        for p in sorted(glob.glob(os.path.join(d, '*.csv'))):
            s = summarize(p)
            if s: runs.append(s)
        bt = os.path.join(d, 'boot-times.log')
        if os.path.exists(bt):
            for line in open(bt):
                m = dict(t.split('=', 1) for t in line.split() if '=' in t)
                if num(m.get('menu_up')) is not None: boots.append(m)
    if not runs: print('no usable CSVs'); return
    game = [r for r in runs if r['wl'] != 'menuidle']; idle = [r for r in runs if r['wl'] == 'menuidle']
    G = defaultdict(list)
    for r in game: G[(r['wl'], r['fw'])].append(r)

    if G:
        print("\nGAMEPLAY  (steady = last 40%. fps/miss: Zero = MEASURE loop fps + under-budget frames/min; NextUI = shim presents/s + presents >25 ms late/min)")
        print(f"{'workload / fw':30}{'runs':>4} {'cpuC':>9} {'gpuC':>9} {'clkMHz':>9} {'busy%':>8} {'fps':>7} {'miss/min':>9} {'gap ms':>7} {'%/hr':>7} {'mV/hr':>8}  gov/maxMHz")
        print('-' * 132)
        for (wl, fw), rs in sorted(G.items()):
            flags = ''
            if any(r['charging'] for r in rs): flags += ' [CHARGING]'
            if any(r.get('crop') for r in rs): flags += ' [720p-CROP]'
            if any(r.get('bl_min') is not None and r['bl_min'] != r['bl_max'] for r in rs): flags += ' [backlight-changed]'
            if all(r.get('fps') is None for r in rs): flags += ' [no-shim]'
            print(f"{wl + ' / ' + fw:30}{len(rs):>4} {msd([r['cpu'] for r in rs], 9):>9} {msd([r['gpu'] for r in rs], 9):>9} "
                  f"{msd([r['clk'] for r in rs], 9, 0):>9} {msd([r['busy'] for r in rs], 8):>8} {msd([r.get('fps') for r in rs], 7):>7} "
                  f"{msd([r.get('late_pm') for r in rs], 9, 2):>9} {msd([r.get('worst_gap') for r in rs], 7, 0):>7} "
                  f"{msd([r['pph'] for r in rs], 7):>7} {msd([r['mvph'] for r in rs], 8):>8}  {govstr(rs[0])}{flags}")

        print("\nHEAD-TO-HEAD vs zero (clock saved = how much less CPU clock Zero used for the same game)")
        wls = sorted({wl for wl, _ in G})
        for wl in wls:
            z = G.get((wl, 'zero'))
            if not z: continue
            zclk = mean(r['clk'] for r in z); zfps = mean(r.get('fps') for r in z); zm = mean(r.get('m_fps') for r in z)
            line = f"  {wl:12} zero {zclk:5.0f} MHz"
            if zm is not None: line += f" MEASURE {zm:.1f} fps"
            if zfps is not None: line += f" shim {zfps:.1f}"
            print(line)
            for (w2, fw), rs in sorted(G.items()):
                if w2 != wl or fw == 'zero': continue
                oclk = mean(r['clk'] for r in rs); ofps = mean(r.get('fps') for r in rs)
                saved = 100 * (oclk - zclk) / oclk if oclk else None
                s = f"{' ':15}{fw:20} {oclk:5.0f} MHz"
                if ofps is not None: s += f" shim {ofps:.1f} fps"
                if saved is not None: s += f"   -> Zero used {saved:.0f}% less clock"
                lp = mean(r.get('late_pm') for r in rs); zl = mean(r.get('late_pm') for r in z)
                if lp is not None and zl is not None: s += f"; late/min {lp:.2f} vs zero {zl:.2f}"
                print(s)

        print("\nOPP residency (% of samples at each MHz):")
        for (wl, fw), rs in sorted(G.items()):
            agg = Counter()
            for r in rs: agg.update(r['clocks'])
            tot = sum(agg.values()) or 1
            print(f"  {wl}/{fw}: " + "  ".join(f"{mhz}:{100 * c // tot}%" for mhz, c in sorted(agg.items())))

        if any(r.get('m_fps') is not None for r in game):
            print("\nZERO MEASURE detail (its own loop telemetry):  fps/target  dup/s(starved)  under/s  ceil  use%   | shim unique presents/s (present-skip drops identical frames)")
            for (wl, fw), rs in sorted(G.items()):
                if all(r.get('m_fps') is None for r in rs): continue
                print(f"  {wl}/{fw}: {msd([r.get('m_fps') for r in rs])}/{rs[0].get('m_tgt')}  dup {msd([r.get('m_dup') for r in rs], 5, 2)}  "
                      f"under {msd([r.get('m_under') for r in rs], 5, 2)}  ceil {Counter(r.get('m_ceil') for r in rs).most_common(1)[0][0]}  use {msd([r.get('m_use') for r in rs], 5)}"
                      f"   | uniq {msd([r.get('uniq_ps') for r in rs], 5)}/s")

        if any(any(c is not None for c in r['cores']) for r in game):
            print("\nPER-CORE busy% (steady):  c0  c1  c2  c3   irq/s  ctxt/s")
            for (wl, fw), rs in sorted(G.items()):
                if all(all(c is None for c in r['cores']) for r in rs): continue
                cs = "  ".join(msd([r['cores'][i] for r in rs], 5) for i in range(4))
                print(f"  {wl}/{fw}: {cs}   {msd([r['irq'] for r in rs], 6, 0)}  {msd([r['ctxt'] for r in rs], 7, 0)}")

        if any(r.get('launch_lat') is not None or r.get('startup_ms') for r in game):
            print("\nLAUNCH -> FIRST FRAME (shim first present minus launch, s)  [NextUI self-reported startup ms]")
            for (wl, fw), rs in sorted(G.items()):
                if all(r.get('launch_lat') is None and not r.get('startup_ms') for r in rs): continue
                sr = [r['startup_ms'] for r in rs if r.get('startup_ms')]
                print(f"  {wl}/{fw}: {msd([r.get('launch_lat') for r in rs], 6, 2)} s" + (f"   [self: {msd(sr, 6, 0)} ms]" if sr else ''))

    if idle:
        I = defaultdict(list)
        for r in idle: I[r['fw']].append(r)
        print("\nMENU IDLE  (cpu% = aggregate busy; gpu_pm = GPU runtime-PM status, the GPU-dark proof)")
        print(f"{'fw':20}{'runs':>4} {'cpuC':>9} {'gpuC':>9} {'clkMHz':>9} {'cpu%':>8} {'irq/s':>7} {'%/hr':>7}  gpu_pm  backlight  fb_blank")
        for fw, rs in sorted(I.items()):
            gp = Counter()
            for r in rs: gp.update(r['gpu_pm'])
            gps = gp.most_common(1)[0][0] if gp else 'n/a'
            bl = [r['bl_min'] for r in rs if r.get('bl_min') is not None]
            print(f"{fw:20}{len(rs):>4} {msd([r['cpu'] for r in rs], 9):>9} {msd([r['gpu'] for r in rs], 9):>9} {msd([r['clk'] for r in rs], 9, 0):>9} "
                  f"{msd([r['busy'] for r in rs], 8):>8} {msd([r['irq'] for r in rs], 7, 0):>7} {msd([r['pph'] for r in rs], 7):>7}  {gps:7} {msd(bl, 9, 0)}  {msd([r.get('fb_blank') for r in rs], 8, 0)}")

    if boots:
        Bt = defaultdict(list)
        for b in boots: Bt['zero' if 'minui' in b.get('menu', '') else 'nextui' if 'nextui' in b.get('menu', '') else b.get('menu', '?')].append(b)
        print("\nBOOT (kernel uptime, s; bootloader+kernel are shared stock firmware and excluded on both)")
        for fw, bs in sorted(Bt.items()):
            print(f"  {fw:8} boots {len(bs):>2}  hook {msd([num(b['hook_up']) for b in bs], 6, 2)}  menu-process {msd([num(b['menu_up']) for b in bs], 6, 2)}")

if __name__ == '__main__':
    main()
