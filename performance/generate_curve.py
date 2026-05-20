#!/usr/bin/env python3
"""
Genera la curva de rendimiento UNAgent a partir de los datos de InfluxDB.

Uso:
    python3 performance/generate_curve.py            # última tanda
    python3 performance/generate_curve.py --run 2    # tanda específica

Requiere:
    pip install requests matplotlib numpy
"""

import sys
import argparse
from datetime import datetime, timezone

try:
    import requests
    import matplotlib.pyplot as plt
    import matplotlib.ticker as ticker
    import numpy as np
except ImportError:
    print("Instala dependencias: pip install requests matplotlib numpy")
    sys.exit(1)

INFLUX_URL = "http://localhost:8086"
DB         = "k6"

# Rangos de cada tanda detectados en InfluxDB
# (start_ns, end_ns, label)
RUNS = {
    1: (1779208569000000000, 1779209170000000000, "Tanda 1 — 10 min, max 500 VUs"),
    2: (1779209420000000000, 1779210141000000000, "Tanda 2 — 12 min, max 750 VUs"),
    3: (1779218999000000000, 1779219396000000000, "Tanda 3 — 6 min, max 100 VUs"),
    4: (1779220294000000000, 1779221015000000000, "Tanda 4 — 12 min, max 750 VUs"),
    5: (1779221760000000000, 1779221996000000000, "Tanda 5 — 4 min"),
    6: (1779222531000000000, 1779223252000000000, "Tanda 6 — 12 min, max 750 VUs"),
    7: (1779224665000000000, 1779225393000000000, "Tanda 7 — 12 min, max 750 VUs"),
    8: (1779239460000000000, 1779240450000000000, "Tanda 8 — max 2000 VUs"),
}

# Límites fijos de eje Y por tanda (y_min, y_max). None = auto-proporcional.
YLIM = {
    2: (800, 860),
}


def query(q: str) -> list[dict]:
    r = requests.get(
        f"{INFLUX_URL}/query",
        params={"db": DB, "q": q},
        timeout=15,
    )
    r.raise_for_status()
    data = r.json()
    results = data.get("results", [{}])
    series = results[0].get("series", [])
    if not series:
        return []
    cols   = series[0]["columns"]
    values = series[0]["values"]
    return [dict(zip(cols, row)) for row in values]


def idx(rows: list[dict], key: str) -> dict:
    return {r["time"]: r[key] for r in rows if r.get(key) is not None}


def build_curve(run_id: int):
    start_ns, end_ns, run_label = RUNS[run_id]

    print(f"Consultando InfluxDB — {run_label} …")

    # Ventanas de 30 s dentro del rango de la tanda
    window = "30s"
    time_filter = f"time >= {start_ns} AND time <= {end_ns}"

    avg_rows = query(
        f'SELECT MEAN("value") AS avg_ms '
        f'FROM "http_req_duration" '
        f'WHERE {time_filter} '
        f'GROUP BY time({window}) fill(none)'
    )
    p95_rows = query(
        f'SELECT PERCENTILE("value", 95) AS p95_ms '
        f'FROM "http_req_duration" '
        f'WHERE {time_filter} '
        f'GROUP BY time({window}) fill(none)'
    )
    vus_rows = query(
        f'SELECT MAX("value") AS vus '
        f'FROM "vus" '
        f'WHERE {time_filter} '
        f'GROUP BY time({window}) fill(none)'
    )
    err_rows = query(
        f'SELECT MEAN("value")*100 AS err_pct '
        f'FROM "http_req_failed" '
        f'WHERE {time_filter} '
        f'GROUP BY time({window}) fill(none)'
    )

    if not avg_rows:
        print("Sin datos en InfluxDB para ese rango.")
        sys.exit(1)

    avg  = idx(avg_rows, "avg_ms")
    p95  = idx(p95_rows, "p95_ms")
    vus  = idx(vus_rows, "vus")
    err  = idx(err_rows, "err_pct")

    # Alinear por timestamps comunes
    times = sorted(set(avg.keys()) & set(vus.keys()))
    if not times:
        print("No hay solapamiento temporal entre métricas.")
        sys.exit(1)

    xs_vus  = np.array([vus[t]          for t in times])
    ys_avg  = np.array([avg[t]          for t in times])
    ys_p95  = np.array([p95.get(t, np.nan) for t in times])
    ys_err  = np.array([err.get(t, 0.0) for t in times])

    # Eliminar puntos anómalos: avg < 50% de la mediana (artefacto de errores rápidos al final)
    median_avg = np.nanmedian(ys_avg)
    valid = ys_avg >= median_avg * 0.5
    xs_vus, ys_avg, ys_p95, ys_err = xs_vus[valid], ys_avg[valid], ys_p95[valid], ys_err[valid]

    # Promediar puntos con el mismo número de VUs (ramp + hold caen en el mismo x)
    unique_vus = np.unique(xs_vus)
    ys_avg = np.array([np.nanmean(ys_avg[xs_vus == v]) for v in unique_vus])
    ys_p95 = np.array([np.nanmean(ys_p95[xs_vus == v]) for v in unique_vus])
    ys_err = np.array([np.nanmean(ys_err[xs_vus == v]) for v in unique_vus])
    xs_vus = unique_vus

    # ── Figura ──────────────────────────────────────────────────────────────────
    fig, (ax_lat, ax_err) = plt.subplots(
        2, 1, figsize=(11, 8), sharex=True,
        gridspec_kw={"height_ratios": [3, 1]}
    )
    fig.suptitle(
        f"UNAgent — Curva de Rendimiento\n{run_label}",
        fontsize=13, fontweight="bold", y=0.98
    )

    # ── Panel principal: latencia vs carga ───────────────────────────────────
    ax_lat.set_ylabel("Average Response Time (ms)", fontsize=11)
    ax_lat.grid(True, alpha=0.25, linestyle="--")
    ax_lat.set_facecolor("#f9f9f9")

    ax_lat.plot(
        xs_vus, ys_avg,
        "o-", color="#1976D2", linewidth=2.5, markersize=5,
        label="Avg Response Time",
        zorder=3,
    )
    ax_lat.fill_between(xs_vus, ys_avg, alpha=0.10, color="#1976D2")

    ax_lat.legend(loc="upper left", fontsize=9)
    ax_lat.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:,.0f} ms"))
    if run_id in YLIM:
        ax_lat.set_ylim(*YLIM[run_id])
    else:
        y_top = max(np.nanmax(ys_avg) * 1.25, 100)
        y_top = int(np.ceil(y_top / 100) * 100)
        ax_lat.set_ylim(0, y_top)

    # Anotación del máximo
    max_idx = np.argmax(ys_avg)
    ax_lat.annotate(
        f"  max {ys_avg[max_idx]:,.0f} ms\n  @ {xs_vus[max_idx]:.0f} VUs",
        xy=(xs_vus[max_idx], ys_avg[max_idx]),
        fontsize=8, color="#1976D2",
        va="bottom",
    )

    # ── Panel inferior: error rate ───────────────────────────────────────────
    ax_err.set_xlabel("System Workload (Virtual Users)", fontsize=11)
    ax_err.set_ylabel("Error Rate (%)", fontsize=10)
    ax_err.grid(True, alpha=0.25, linestyle="--")
    ax_err.set_facecolor("#fff8f8")

    ax_err.fill_between(xs_vus, ys_err, alpha=0.4, color="#E53935", step="mid")
    ax_err.step(xs_vus, ys_err, color="#E53935", linewidth=1.5, where="mid",
                label="Error rate")
    ax_err.axhline(5, color="#B71C1C", linestyle=":", linewidth=1.2,
                   alpha=0.7, label="5 % threshold")
    ax_err.set_ylim(bottom=0)
    ax_err.yaxis.set_major_formatter(ticker.FuncFormatter(lambda x, _: f"{x:.1f}%"))
    ax_err.legend(loc="upper left", fontsize=9)

    plt.tight_layout(rect=[0, 0, 1, 0.96])

    out = f"performance/results/curva_rendimiento_run{run_id}.png"
    plt.savefig(out, dpi=150, bbox_inches="tight")
    print(f"Curva guardada en: {out}")
    plt.show()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Genera curva de rendimiento desde InfluxDB")
    parser.add_argument(
        "--run", type=int, choices=list(RUNS.keys()), default=8,
        help="Número de tanda (1, 2, o 3). Default: 2"
    )
    args = parser.parse_args()
    build_curve(args.run)
