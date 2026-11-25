#!/usr/bin/env python3
"""并行分片下载大文件（HF 单连接被限速时用）。

单连接实测只有 1.5~1.7 MB/s，8 连接能到 11~20 MB/s；7 GB 权重从 70 分钟压到 10 分钟。

特点：
  * 分片用 curl 子进程下载（自动跟随 HF 的 302 跳转、自带 --retry）；
  * 断点续传：每片是独立文件 <out>.partNN，中断后重跑会从各片已有大小继续；
  * 全部下完后按顺序拼接，校验总大小，成功才 rename 成目标文件；
  * 失败保留 .partNN，方便重跑。

用法：
    ./scripts/dl-parallel.py <URL> <OUT> <TOTAL_BYTES> [CONNS=8]
"""
import os
import subprocess
import sys
import threading
import time

MIN_PART = 8 * 1024 * 1024      # 单片不小于 8 MiB
PARTS_PER_CONN = 4              # 每连接排 4 片，避免慢连接拖尾


def human(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.1f} {unit}" if unit != "B" else f"{int(n)} B"
        n /= 1024
    return f"{n:.1f} GiB"


def part_size_of(path: str) -> int:
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def plan(total: int, conns: int):
    """把 [0,total) 切成 8 MiB 对齐的若干片，返回 [(start, end_inclusive), ...]。"""
    nparts = max(1, min(conns * PARTS_PER_CONN, total // MIN_PART))
    step = (total + nparts - 1) // nparts
    step -= step % MIN_PART or 0          # 对齐到 8 MiB（不影响正确性，只为整齐）
    step = max(step, MIN_PART)
    out, start = [], 0
    while start < total:
        end = min(start + step, total) - 1
        out.append((start, end))
        start = end + 1
    return out


def fetch_part(url: str, part: str, start: int, end: int) -> bool:
    need = end - start + 1
    have = part_size_of(part)
    if have == need:
        return True
    if have > need:                        # 片文件比预期大：坏了，重来
        os.truncate(part, 0)
        have = 0
    pos = start + have
    for attempt in range(1, 9):
        with open(part, "ab") as fh:
            rc = subprocess.call(
                [
                    "curl", "-fL", "--retry", "3", "--retry-delay", "2",
                    "--connect-timeout", "20",
                    # 30 秒内低于 1 KiB/s 视为卡死，主动断开重连
                    "--speed-limit", "1024", "--speed-time", "30",
                    "-r", f"{pos}-{end}", "-o", "-", url,
                ],
                stdout=fh,
                stderr=subprocess.DEVNULL,
            )
        now = part_size_of(part)
        if now == need:
            return True
        if now > need:                     # 服务端无视 Range 返回了整文件
            os.truncate(part, 0)
            now = 0
        if now == pos and rc == 0:         # 没有任何进展却成功结束，别死循环
            time.sleep(1)
        pos = start + now
        if attempt == 1 or now - have > 0:
            print(f"    ↻ 片 {start}-{end}: {human(now - start)}/{human(need)}，第 {attempt} 次重试",
                  flush=True)
        time.sleep(min(2 ** attempt, 10) / 2)
    return False


def main() -> int:
    if len(sys.argv) < 4:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    url, out, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
    conns = int(sys.argv[4]) if len(sys.argv) > 4 else 8

    if part_size_of(out) == total:
        print(f"  已完整，跳过：{out}（{human(total)}）")
        return 0
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)

    parts = plan(total, conns)
    files = [f"{out}.part{i:03d}" for i in range(len(parts))]
    print(f"  并行下载 {os.path.basename(out)}（{human(total)}，{len(parts)} 片 / {conns} 线程）",
          flush=True)

    # 进度：每 2 秒汇总一次各片大小
    done = threading.Event()

    def report():
        last, last_t = 0, time.time()
        while not done.wait(2):
            cur = sum(part_size_of(p) for p in files)
            now = time.time()
            speed = (cur - last) / max(now - last_t, 1e-6)
            last, last_t = cur, now
            pct = cur * 100 / total
            print(f"\r    {pct:5.1f}%  {human(cur)} / {human(total)}  {human(speed)}/s",
                  end="", flush=True)

    th = threading.Thread(target=report, daemon=True)
    th.start()

    # 片按轮转分给各线程，让每个线程拿到分散在文件各处的片
    buckets = [parts[i::conns] for i in range(conns)]

    def run_bucket(pidx):
        for j, (s, e) in enumerate(buckets[pidx]):
            idx = parts.index((s, e))
            if not fetch_part(url, files[idx], s, e):
                raise RuntimeError(f"片 {s}-{e} 下载失败")

    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=conns) as pool:
        futures = [pool.submit(run_bucket, i) for i in range(conns)]
        for f in futures:
            f.result()

    done.set()
    th.join(timeout=3)
    print()

    if sum(part_size_of(p) for p in files) != total:
        print("  ✗ 分片总大小不符，保留 .partNN 供续传", file=sys.stderr)
        return 1

    tmp = out + ".join"
    with open(tmp, "wb") as w:
        for p in files:
            with open(p, "rb") as r:
                while True:
                    buf = r.read(8 * 1024 * 1024)
                    if not buf:
                        break
                    w.write(buf)
    os.replace(tmp, out)
    for p in files:
        os.unlink(p)
    if part_size_of(out) != total:
        print(f"  ✗ 拼接后大小不符：{part_size_of(out)} != {total}", file=sys.stderr)
        return 1
    print(f"  ✓ 完成 {out}（{human(total)}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
