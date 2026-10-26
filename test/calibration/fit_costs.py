"""Fits measured GPU times (CAL lines of calibrate_costs.gd, at 1024 and 4096)
to the cost model of automatic buffers"""
import sys
import numpy as np
P1, P2 = 1024.0 ** 2, 4096.0 ** 2
lines = [l.strip().split(',') for l in open(sys.argv[1]) if l.startswith('CAL,')]
rows = [r for r in lines if r[1] == 'node']
cost = np.array([float(r[3]) for r in rows])
t1 = np.array([float(r[4]) for r in rows])
t2 = np.array([float(r[5]) for r in rows])
# Per pixel GPU time (ns) and fixed time per pass (us)
per_pixel = (t2 - t1) / (P2 - P1) * 1000.0
fixed = t1 - per_pixel * P1 / 1000.0
print('%d nodes; fixed time per pass: median %.0f us' % (len(rows), np.median(fixed)))
rank = lambda x: np.argsort(np.argsort(x))
print('per pixel vs cost: correlation %.2f, rank correlation %.2f' % (np.corrcoef(cost, per_pixel)[0, 1], np.corrcoef(rank(cost), rank(per_pixel))[0, 1]))
# Per pixel time of a "free" node, and the slope per cost unit
base = np.median(per_pixel[cost <= 5])
m = cost > 50
slope = np.median((per_pixel[m] - base) / cost[m])
print('per pixel: %.4f ns base, %.5f ns per cost unit' % (base, slope))
for lo, hi in [(0, 10), (10, 100), (100, 1000), (1000, 1e9)]:
    k = (cost >= lo) & (cost < hi)
    if k.any():
        print('  cost %g-%g: n=%d, median %.4f ns per pixel, model %.4f' % (lo, hi, k.sum(), np.median(per_pixel[k]), base + slope * np.median(cost[k])))
# Fetches of nearby texels (more fetches are spread over the image)
fetch = [r for r in lines if r[1] == 'fetch' and float(r[2]) <= 16]
if len(fetch) >= 2:
    fk = np.array([float(r[2]) for r in fetch])
    fp = np.array([(float(r[4]) - float(r[3])) / (P2 - P1) * 1000.0 for r in fetch])
    fs = np.polyfit(fk, fp, 1)[0]
    print('fetch: %.5f ns per pixel per fetch => COST_TEXTURE_FETCH = %.2f cost units' % (fs, fs / slope))
# The fixed time of a buffer pass, in cost units per pixel of a buffer of the
# default automatic buffer size (1024)
overhead = np.median(fixed) * 1000.0 / P1 / slope
print('fixed time per pass at 1024: %.0f cost units per pixel => COST_BUFFER_OVERHEAD' % overhead)
print('time of one cost unit at 1024: %.3f us' % (slope * P1 / 1000.0))
idx = np.argsort(-per_pixel)[:6]
for i in idx:
    print('  slowest per pixel:', rows[i][2], 'cost', cost[i], '%.3f ns' % per_pixel[i])
