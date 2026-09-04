"""Measure sustained throughput and latency against a running API.

Reports single-prediction and batch modes separately, on purpose. The single
number is the honest one to quote for "real-time predictions per second" --
each request is one transaction, end to end over HTTP. Batch throughput is much
larger because ONNX Runtime amortises per-call overhead across the batch, so it
is reported as its own figure rather than folded into the headline.

Closed-loop load: a fixed number of concurrent workers each issue a request,
wait for the response, and immediately issue the next. Latency percentiles are
therefore per-request service times under that concurrency level.

Load is spread over several client PROCESSES, not just asyncio tasks in one.
That is not incidental: a single Python client saturates its own core on JSON
encoding and asyncio bookkeeping long before the server runs out of capacity,
and then reports the *client's* limit as though it were the server's. Measured
here, one process peaked around 1,960 RPS and got slower as concurrency rose,
while four processes sustained over 4,100 against the same server. Total
concurrency is --processes x --concurrency.

Usage:
    uvicorn app.main:app --host 127.0.0.1 --port 8000 --workers 2
    python scripts/benchmark.py --duration 15 --processes 4 --concurrency 4
"""

from __future__ import annotations

import argparse
import asyncio
import json
import statistics
import sys
import time
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import httpx

ROOT = Path(__file__).resolve().parent.parent
FIXTURE_PATH = ROOT / "models" / "parity_fixture.json"


def load_payloads() -> tuple[list[dict], list[str]]:
    if not FIXTURE_PATH.exists():
        sys.exit(f"Missing {FIXTURE_PATH}. Run: python src/train.py")
    fixture = json.loads(FIXTURE_PATH.read_text())
    names = fixture["feature_names"]
    return [dict(zip(names, row)) for row in fixture["rows"]], names


def percentile(values: list[float], pct: float) -> float:
    """Nearest-rank percentile. Avoids interpolating between samples, which
    would invent latencies that were never observed."""
    if not values:
        return float("nan")
    ordered = sorted(values)
    rank = max(1, int(round(pct / 100.0 * len(ordered))))
    return ordered[min(rank, len(ordered)) - 1]


async def _worker(
    client: httpx.AsyncClient,
    url: str,
    body_for: callable,
    deadline: float,
    latencies: list[float],
    errors: list[int],
) -> None:
    while time.perf_counter() < deadline:
        started = time.perf_counter()
        try:
            r = await client.post(url, json=body_for())
            elapsed = time.perf_counter() - started
            if r.status_code == 200:
                latencies.append(elapsed)
            else:
                errors.append(r.status_code)
        except httpx.HTTPError:
            errors.append(-1)


def _run_client_process(args: tuple) -> tuple[list[float], list[int], float]:
    """Entry point for one client process. Returns raw samples for aggregation.

    Percentiles must be computed over the pooled samples from every process --
    averaging each process's own p99 would be a statistic with no meaning.
    """
    (base_url, payloads, mode, duration, concurrency, batch_size, warmup) = args
    return asyncio.run(
        _load(base_url, payloads, mode, duration, concurrency, batch_size, warmup)
    )


async def _load(
    base_url: str,
    payloads: list[dict],
    mode: str,
    duration: float,
    concurrency: int,
    batch_size: int,
    warmup: float,
) -> tuple[list[float], list[int], float]:
    counter = {"i": 0}

    def next_single() -> dict:
        counter["i"] += 1
        return payloads[counter["i"] % len(payloads)]

    def next_batch() -> dict:
        counter["i"] += 1
        start = counter["i"] % len(payloads)
        rows = [payloads[(start + j) % len(payloads)] for j in range(batch_size)]
        return {"transactions": rows}

    if mode == "single":
        url, body_for, per_request = f"{base_url}/predict", next_single, 1
    else:
        url, body_for, per_request = f"{base_url}/predict/batch", next_batch, batch_size

    limits = httpx.Limits(
        max_connections=concurrency, max_keepalive_connections=concurrency
    )
    async with httpx.AsyncClient(limits=limits, timeout=30.0) as client:
        if warmup > 0:
            # Excluded from the numbers: the first calls pay ORT's lazy
            # allocation and connection setup, which is not steady state.
            wl, we = [], []
            await asyncio.gather(*[
                _worker(client, url, body_for, time.perf_counter() + warmup, wl, we)
                for _ in range(concurrency)
            ])

        latencies: list[float] = []
        errors: list[int] = []
        started = time.perf_counter()
        deadline = started + duration
        await asyncio.gather(*[
            _worker(client, url, body_for, deadline, latencies, errors)
            for _ in range(concurrency)
        ])
        wall = time.perf_counter() - started

    return latencies, errors, wall


def run_mode(
    base_url: str,
    payloads: list[dict],
    mode: str,
    duration: float,
    concurrency: int,
    batch_size: int,
    warmup: float,
    processes: int,
) -> dict:
    """Drive load from `processes` client processes and pool the results."""
    per_request = 1 if mode == "single" else batch_size
    job = (base_url, payloads, mode, duration, concurrency, batch_size, warmup)

    if processes == 1:
        results = [_run_client_process(job)]
    else:
        with ProcessPoolExecutor(max_workers=processes) as pool:
            results = list(pool.map(_run_client_process, [job] * processes))

    latencies = [x for r in results for x in r[0]]
    errors = [x for r in results for x in r[1]]
    # Processes run concurrently, so wall time is the longest, not the sum.
    wall = max(r[2] for r in results)

    n = len(latencies)
    return {
        "mode": mode,
        "batch_size": per_request,
        "processes": processes,
        "concurrency_per_process": concurrency,
        "total_concurrency": processes * concurrency,
        "duration_sec": round(wall, 2),
        "requests": n,
        "errors": len(errors),
        "requests_per_sec": round(n / wall, 1) if wall else 0.0,
        "predictions_per_sec": round(n * per_request / wall, 1) if wall else 0.0,
        "latency_ms": {
            "mean": round(statistics.fmean(latencies) * 1000, 2) if n else None,
            "p50": round(percentile(latencies, 50) * 1000, 2) if n else None,
            "p95": round(percentile(latencies, 95) * 1000, 2) if n else None,
            "p99": round(percentile(latencies, 99) * 1000, 2) if n else None,
            "max": round(max(latencies) * 1000, 2) if n else None,
        },
    }


def print_report(results: list[dict]) -> None:
    print("\n" + "=" * 78)
    print("BENCHMARK RESULTS")
    print("=" * 78)
    for r in results:
        lat = r["latency_ms"]
        label = (
            "single prediction per request"
            if r["mode"] == "single"
            else f"batch of {r['batch_size']} per request"
        )
        print(f"\n{r['mode'].upper()}  ({label})")
        print(f"  load generators    {r['processes']} processes x "
              f"{r['concurrency_per_process']} concurrent = "
              f"{r['total_concurrency']} in flight")
        print(f"  duration           {r['duration_sec']} s")
        print(f"  requests           {r['requests']:,}   errors: {r['errors']}")
        print(f"  requests/sec       {r['requests_per_sec']:,}")
        print(f"  predictions/sec    {r['predictions_per_sec']:,}")
        print(f"  latency ms         p50={lat['p50']}  p95={lat['p95']}  "
              f"p99={lat['p99']}  max={lat['max']}")

    single = next((r for r in results if r["mode"] == "single"), None)
    batch = next((r for r in results if r["mode"] == "batch"), None)
    print("\n" + "-" * 78)
    if single:
        print(f"HEADLINE (quote this): {single['predictions_per_sec']:,.0f} "
              "real-time predictions/sec")
        print(f"  one transaction per HTTP request, p99 "
              f"{single['latency_ms']['p99']} ms")
    if batch:
        print(f"BATCH throughput:      {batch['predictions_per_sec']:,.0f} "
              f"predictions/sec at batch size {batch['batch_size']}")
    print("-" * 78 + "\n")


async def main_async(args) -> None:
    payloads, _ = load_payloads()
    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            r = await client.get(f"{args.url}/ready")
        except httpx.HTTPError as exc:
            sys.exit(f"Cannot reach {args.url}: {exc}\nIs uvicorn running?")
        if r.status_code != 200:
            sys.exit(f"{args.url}/ready returned {r.status_code}; model not loaded.")

    modes = ["single", "batch"] if args.mode == "both" else [args.mode]
    results = []
    for mode in modes:
        print(f"Running {mode} mode for {args.duration}s: {args.processes} "
              f"client process(es) x {args.concurrency} concurrent...", flush=True)
        results.append(
            run_mode(
                args.url, payloads, mode, args.duration, args.concurrency,
                args.batch_size, args.warmup, args.processes,
            )
        )

    print_report(results)
    if args.json_out:
        Path(args.json_out).write_text(json.dumps(results, indent=2) + "\n")
        print(f"Wrote {args.json_out}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--url", default="http://127.0.0.1:8000")
    ap.add_argument("--duration", type=float, default=15.0)
    ap.add_argument("--concurrency", type=int, default=4,
                    help="concurrent requests per client process")
    ap.add_argument("--processes", type=int, default=4,
                    help="client processes; 1 under-measures the server")
    ap.add_argument("--batch-size", type=int, default=500)
    ap.add_argument("--warmup", type=float, default=3.0)
    ap.add_argument("--mode", choices=["single", "batch", "both"], default="both")
    ap.add_argument("--json-out", default=None)
    asyncio.run(main_async(ap.parse_args()))


if __name__ == "__main__":
    main()
