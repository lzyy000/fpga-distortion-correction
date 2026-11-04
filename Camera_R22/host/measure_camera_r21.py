"""Read-only R21/R22 1080p30 UART validation. Never transmits or changes mode."""
from pathlib import Path
import sys, argparse, re, json, time, datetime
P = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(P / "tools/python_packages"))
PATTERN = re.compile(r"CAM dt_ms=(\d+) sensor=(\d+) cap=(\d+) display_new=(\d+) skipped=(\d+) flags=([0-9A-Fa-f]+) fifo_peak=(\d+)")
DVP_PATTERN = re.compile(r"DVP dt_ms=(\d+) pclk_khz=(\d+).*last_line_bytes=(\d+) rows_at_vs=(\d+) pixels_at_vs=(\d+)")
BANNER = "DVP R12 RAW74 BYPASS DIVPROBE DRIVE2 VFLIP"
EXPECTED_CFG = {0x3034:0x1a, 0x3035:0x11, 0x3036:0x5d, 0x3037:0x13, 0x3108:1,
                0x3808:7, 0x3809:0x80, 0x380a:4, 0x380b:0x38,
                0x380c:8, 0x380d:0xc0, 0x380e:4, 0x380f:0x54,
                0x4300:0, 0x501f:3, 0x4740:0, 0x460b:0x37, 0x460c:0x22,
                0x3824:2, 0x3612:0x2b, 0x3820:0x46, 0x3821:0}
def parse(line):
    m = PATTERN.search(line)
    if not m:
        return None
    keys = ["dt_ms", "sensor", "cap", "display_new", "skipped", "flags", "fifo_peak"]
    return {k:int(v, 16 if k == "flags" else 10) for k,v in zip(keys, m.groups())}
def summarize(rows):
    seconds = sum(r["dt_ms"] for r in rows) / 1000
    if not rows or seconds <= 0:
        return {"counter_gate_pass":False, "reason":"no complete camera records"}
    rates = {k:sum(r[k] for r in rows) / seconds for k in ("sensor", "cap", "display_new")}
    healthy = all(500 <= r["dt_ms"] <= 2000 and (r["flags"] & 0xfb) == 0x3b and r["skipped"] == 0 for r in rows)
    return {"sample_seconds":seconds, "rates_fps":rates, "peak_fifo":max(r["fifo_peak"] for r in rows),
            "skipped":sum(r["skipped"] for r in rows),
            "counter_gate_pass":healthy and all(29.5 <= v <= 30.5 for v in rates.values()),
            "visual_acceptance":"pending: moving camera scene, orientation, Bayer colour order, four borders and tearing",
            "scope":"Geometry-qualified camera/capture/new-display UART counters; HDMI60Hz repeats are not camera60fps"}
def summarize_diagnostics(lines, expected_records=None):
    dvp, sources, sync, recovery, raw, hard = [], [], [], [], [], []
    for line in lines:
        m = DVP_PATTERN.search(line)
        if m:
            dvp.append(tuple(map(int, m.groups())))
        m = re.search(r"CLK hard_pclk_khz=(\d+) divided_by=2 clock_delay=BYPASS", line)
        if m:
            hard.append(int(m[1]))
        m = re.search(r"display_source=(CAMERA|BARS)", line)
        if m:
            sources.append(m[1])
        m = re.search(r"SYNC rejected_vs=(\d+) rejected_href=(\d+).*first_fault_rows=(\d+) first_fault_line_pixels=(\d+)", line)
        if m:
            sync.append(tuple(map(int, m.groups())))
        m = re.search(r"RAW good_new=(\d+) bad_new=(\d+) good_total=(\d+) bad_total=(\d+) rows=(\d+) tail_bytes=(\d+) first_reason=(\d+) first_row=(\d+) first_bytes=(\d+)", line)
        if m:
            raw.append(tuple(map(int, m.groups())))
        m = re.search(r"RECOVER total=(\d+) aborted=(\d+) status=([0-9A-Fa-f]+)", line)
        if m:
            recovery.append((int(m[1]), int(m[2]), int(m[3], 16)))
    counts = {"DVP":len(dvp), "source":len(sources), "SYNC":len(sync), "RECOVER":len(recovery), "RAW":len(raw), "CLK":len(hard)}
    n = expected_records if expected_records is not None else len(dvp)
    checks = {
        "all_records_have_diagnostics":n > 0 and all(c == n for c in counts.values()),
        "geometry_and_clock":bool(dvp) and all(500 <= dt <= 2000 and 73656 <= clock <= 75144 and width == 1920 and rows == 1080 and pixels == 0 for dt,clock,width,rows,pixels in dvp),
        "camera_not_bars":bool(sources) and all(s == "CAMERA" for s in sources),
        "no_capture_first_fault":bool(sync) and all(entry[2] == 0 and entry[3] == 0 for entry in sync),
        "complete_raw_frames":bool(raw) and all(29 <= r[0] <= 31 and r[1] == 0 and r[4] == 1080 and all(v == 0 for v in r[5:]) for r in raw),
        "no_recovery_or_abort":bool(recovery) and all(all(x == 0 for x in entry) for entry in recovery),
        "hard_divided_reference":bool(hard) and all(73656 <= value <= 75144 for value in hard),
    }
    difference = [abs(d[1]-h) for d,h in zip(dvp,hard)]
    return {"diagnostic_gate_pass":all(checks.values()), "clock_branch_max_difference_khz":max(difference,default=None), "filtered_sync_pulses":sum(v+h for v,h,_,_ in sync), "signal_clean_window":bool(sync) and all(v==h==0 for v,h,_,_ in sync), "checks":checks, "diagnostic_counts":counts,
            "expected":"R12: 1920 RAW8 bytes x1080 rows -> RGB5651920x1080, internal cam_clk74400kHz +/-1%, CAMERA, no errors",
            "clock_scope":"Receiver clock versus parallel hardware divide2 branch: shares pin/input buffer and related IO resources; not an oscilloscope or fully independent physical pin measurement"}
def summarize_identity(lines):
    joined = "\n".join(lines)
    cfg = {int(a,16):int(v,16) for a,v in re.findall(r"CFG register=([0-9A-Fa-f]+) value=([0-9A-Fa-f]+)", joined)}
    versions = set(re.findall(r"\bDVP (R21|R22) HOST MODES\b", joined))
    checks = {"banner":len(versions) == 1, "sensor_id":bool(re.search(r"OV1 ID=0*5640\b", joined)),
              "raw30_mode":bool(re.search(r"nominal_camera_fps_milli=29977 assumed_pclk_khz=74400 RAW8_BGGR=1 filter_clocks=16", joined)),
              "all_config_readbacks":all(cfg.get(a) == v for a,v in EXPECTED_CFG.items())}
    return {"identity_gate_pass":all(checks.values()), "checks":checks,
            "firmware_version":next(iter(versions)) if len(versions) == 1 else None,
            "scope":"UART startup identity/readback only; does not cryptographically prove the programmed bitstream"}
def complete_records(lines, warmup):
    # Keep a CAM and all its diagnostics together. A timed capture may end
    # midway through the last record; that trailing fragment is not a failure.
    rows, diagnostics = [], []
    pending, block, index, incomplete = None, [], 0, 0
    for line in lines:
        row = parse(line)
        if row is not None:
            if pending is not None and index > warmup:
                incomplete += 1
            index += 1
            pending, block = row, []
        elif pending is not None:
            block.append(line)
            if re.search(r"RECOVER total=", line):
                if index > warmup:
                    rows.append(pending)
                    diagnostics.extend(block)
                pending, block = None, []
    return rows, diagnostics, incomplete, pending is not None

def main():
    import serial
    from serial.tools import list_ports
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port")
    ap.add_argument("--seconds", type=float, default=600)
    ap.add_argument("--warmup", type=int, default=5)
    ap.add_argument("--output", type=Path)
    a = ap.parse_args()
    if a.seconds < 30 or a.warmup < 0:
        ap.error("seconds>=30 and warmup>=0 are required")
    if not a.port:
        ports = [p.device for p in list_ports.comports() if "CP210" in p.description.upper()]
        if len(ports) != 1:
            ap.error("Specify --port; no unique CP210x board UART was found")
        a.port = ports[0]
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    report = a.output or P / "reports" / f"camera_uart_{stamp}.json"
    report.parent.mkdir(parents=True, exist_ok=True)
    raw = report.with_suffix(".log")
    all_lines = []
    deadline = time.monotonic() + a.seconds
    print("Read-only R21/R22 UART measurement. Capture startup with KEY0, then select the algorithm combination to measure and keep it steady.", flush=True)
    print("A fresh, consistent R21 or R22 startup banner and all CFG readbacks are required. No UART commands are sent.", flush=True)
    with serial.Serial(a.port, 115200, timeout=1) as uart, raw.open("w", encoding="utf-8") as log:
        while time.monotonic() < deadline:
            line = uart.readline().decode("ascii", "replace").strip()
            if not line:
                continue
            print(line, flush=True)
            log.write(line + "\n")
            log.flush()
            all_lines.append(line)
    rows, diagnostics, incomplete, trailing = complete_records(all_lines, a.warmup)
    result = summarize(rows)
    result["diagnostics"] = summarize_diagnostics(diagnostics, len(rows))
    result["identity"] = summarize_identity(all_lines)
    result["raw_counter_gate_pass"] = result["counter_gate_pass"]
    result["counter_gate_pass"] = result["counter_gate_pass"] and result["diagnostics"]["diagnostic_gate_pass"] and result["identity"]["identity_gate_pass"]
    result["incomplete_middle_records"] = incomplete
    result["trailing_partial_record_ignored"] = trailing
    if incomplete:
        result["counter_gate_pass"] = False
        result["reason"] = "missing diagnostics inside capture"
    expected_seconds = max(10, a.seconds - a.warmup - 10)
    if result.get("sample_seconds", 0) < expected_seconds:
        result["counter_gate_pass"] = False
        result["reason"] = "insufficient steady-state counter coverage"
    night = re.findall(r"NIGHT status=([0-9A-Fa-f]+) frames=([0-9A-Fa-f]+) sum_v=([0-9A-Fa-f]+)", "\n".join(all_lines))
    result["night_records"] = [{"requested": bool(int(st,16)&2), "statistics_valid": bool(int(st,16)&4), "display_slot_curve": (int(st,16)>>7)&15, "target_curve": (int(st,16)>>3)&15, "frames": int(fr,16), "sum_v": int(su,16)} for st,fr,su in night]
    result["night_diagnostics_present"] = bool(night)
    result["counter_gate_pass"] = result["counter_gate_pass"] and bool(night)
    report.write_text(json.dumps({"port":a.port, "mode":"raw8_30", "physical_1080p30_counter_pass":result["counter_gate_pass"],
                                 "physical_image_acceptance":"pending user observation", "requested_seconds":a.seconds,
                                 "warmup_records":a.warmup, "rows":rows, "summary":result}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    print("Report:", report)
    return 0 if result["counter_gate_pass"] else 1
if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print("ERROR:", exc)
        sys.exit(1)
