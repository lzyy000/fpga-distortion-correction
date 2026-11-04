"""Gate R21 publication on exact sources, ROM, RTL/host checks and timing."""
from pathlib import Path
import argparse
import datetime
import hashlib
import json
import re
import shutil

P = Path(__file__).resolve().parents[1]
I = P / "pnr_camera_r21_modes"
FROZEN = P / "reports/r21_frozen_inputs.json"
RELEASE = P / "reports/r21_modes_release.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def project_tree(path):
    # Unlike balanced S-expressions alone, PDS also requires ordered metadata
    # fields for every source entry. A missing timespec makes PDS reject it.
    tokens = iter(re.findall(r'"(?:\\.|[^"\\])*"|[()]|[^\s()]+',
                             path.read_text(encoding="utf-8")))

    def group():
        items = []
        for token in tokens:
            if token == ")":
                if items and items[0] == "_file":
                    fields = [item for item in items[2:] if isinstance(item, list) and item]
                    assert fields and fields[0][0] == "_format", "PDS _file missing _format: " + str(items[:2])
                    assert len(fields) >= 2 and fields[1][0] == "_timespec" and len(fields[1]) == 2, "PDS _file missing _timespec: " + str(items[:2])
                return items
            items.append(group() if token == "(" else token)
        raise AssertionError("PDS unclosed group")

    roots = []
    for token in tokens:
        assert token == "(", "PDS unexpected token outside group: " + token
        roots.append(group())
    assert len(roots) == 1 and roots[0] and roots[0][0] == "_flow", "PDS requires one _flow root"
    return roots


def project_sha(path):
    ignored = {"_comment", "_timespec", "_gci_state", "_db_output", "_output"}
    def canonical(items):
        result = []
        for item in items:
            if isinstance(item, list):
                if item and item[0] in ignored:
                    continue
                item = canonical(item)
            result.append(item)
        return result
    value = json.dumps(canonical(project_tree(path)), separators=(",", ":"), ensure_ascii=False)
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def write(path, value):
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def sources():
    files = {I / "camera_1080p30_raw8.pds", I / "camera_1080p_top.fdc",
             I / "night_gain.hex", I / "firmware_camera.hex", P / "rtl/night_gain.hex"}
    project = (I / "camera_1080p30_raw8.pds").read_text(encoding="utf-8")
    for name in re.findall(r'(?:_file|_ip_source_item|_ip) "([^"\n]+)"', project):
        path = (I / name).resolve()
        if path.suffix.lower() in {".v", ".vp", ".vh", ".idf", ".fdc", ".hex"}:
            assert path.is_file() and path.is_relative_to(P), str(path)
            files.add(path)
    files.update(P / "night/firmware" / name for name in
                 ("camera_r21_main.c", "camera_r21_tuning.h", "snapshot_service_r21.h"))
    files.update(path for path in (P / "firmware").glob("*")
                 if path.suffix in {".h", ".S", ".lds"})
    # PDS does not enumerate quoted includes, such as calibration constants
    # and the Ethernet checksum helper. Freeze those dependencies as well.
    pending = list(files)
    visited = set()
    while pending:
        source = pending.pop()
        if source in visited or source.suffix not in {".v", ".vp", ".vh", ".c", ".h", ".S"}:
            continue
        visited.add(source)
        for name in re.findall(r'^\s*[#`]include\s*"([^"\n]+)"',
                               source.read_text(encoding="utf-8-sig", errors="replace"), re.M):
            candidates = [source.parent / name, P / "firmware" / name,
                          P / "rtl" / name, P / "night/firmware" / name,
                          P / "baseline_r13_snapshot/reuse/ethernet/source" / name]
            include = next((path.resolve() for path in candidates if path.is_file()), None)
            assert include and include.is_relative_to(P), "Missing include: " + str(source) + ": " + name
            if include not in files:
                files.add(include)
                pending.append(include)
    return {path.relative_to(P).as_posix():
            (project_sha(path) if path.suffix == ".pds" else sha(path))
            for path in sorted(files)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepare", action="store_true")
    parser.add_argument("--publish", action="store_true")
    parser.add_argument("--check-inputs", action="store_true")
    args = parser.parse_args()
    current = sources()
    if args.check_inputs:
        image = (P / "firmware/camera_r21_build/firmware.bin").read_bytes()
        rom = b"".join(int(word, 16).to_bytes(4, "little") for word in
                       (I / "firmware_camera.hex").read_text().split())
        expected = bytearray(32768)
        expected[4096:4096 + len(image)] = image
        assert rom == expected and b"R21 HOST MODES" in image, "Firmware ROM mismatch"
        timing = I / "report_timing/camera_1080p_top.rtr"
        timing_pass = timing.exists() and "Design Summary : All Constraints Met." in timing.read_text(errors="replace")
        frozen = json.loads(FROZEN.read_text(encoding="utf-8")) if FROZEN.exists() else {}
        timing_current = current == frozen.get("files")
        print("PASS R21 project inputs:", len(current), "; firmware ROM matches")
        print("Final timing:", ("PASS" if timing_pass else "NOT PASSED") if timing_current
              else "STALE: current sources differ from the previous build freeze; rebuild required")
        print("Existing timing report:", "all constraints met" if timing_pass else "constraints violated")
        for report_name in ("r21_modes_units.json", "r21_concurrent.json", "r21_host_validation.json"):
            path = P / "reports" / report_name
            if path.exists():
                item = json.loads(path.read_text(encoding="utf-8"))
                hashes = item.get("source_sha256", {})
                matches = bool(hashes) and all((P / name).is_file() and sha(P / name) == digest
                                                for name, digest in hashes.items())
                print(report_name + ":", "matches current sources" if matches else "STALE; rerun before publication")
        print("Published R21 release:", "present" if RELEASE.exists() else "not published")
        return
    if args.prepare:
        write(FROZEN, {"time": datetime.datetime.now().astimezone().isoformat(),
                       "project_hash": "inputs-and-options-without-PDS-run-metadata",
                       "files": current})
        print("Frozen R21 inputs", len(current))
        return
    if not args.publish:
        report = json.loads(RELEASE.read_text(encoding="utf-8"))
        assert current == report["source_sha256"]
        assert sha(Path(report["bitstream"])) == report["bitstream_sha256"]
        print("PASS R21 source and bitstream identity; physical", report["physical_acceptance"])
        return
    frozen = json.loads(FROZEN.read_text(encoding="utf-8"))
    assert current == frozen["files"], "R21 input changed during build"
    units = json.loads((P / "reports/r21_modes_units.json").read_text(encoding="utf-8"))
    concurrent = json.loads((P / "reports/r21_concurrent.json").read_text(encoding="utf-8"))
    host = json.loads((P / "reports/r21_host_validation.json").read_text(encoding="utf-8"))
    assert units["pass"] and concurrent["pass"] and host["pass"]
    required_cases = {"original_tap", "raw_capture", "dual_dma", "views", "night_right", "top_modes",
                      "read_routes", "write_routes", "temporal_zero", "frame_schedule", "network_recovery",
                      "remap_small", "remap_small_wide", "remap_small_zero", "remap_small_dark", "remap_small_stress",
                      "snapshot_ram_identity", "snapshot_ram_half", "snapshot_ram_dark", "snapshot_ram_zero", "ghe_stream", "ghe_builder"}
    assert required_cases <= units["cases"].keys() and host["tests"] >= 32
    for report in (units, concurrent, host):
        for file, digest in report["source_sha256"].items():
            assert sha(P / file) == digest, "Stale verification: " + file
    image = (P / "firmware/camera_r21_build/firmware.bin").read_bytes()
    rom = b"".join(int(word, 16).to_bytes(4, "little") for word in
                   (I / "firmware_camera.hex").read_text().split())
    expected = bytearray(32768)
    expected[4096:4096 + len(image)] = image
    assert rom == expected and b"R21 HOST MODES" in image, "Firmware ROM mismatch"
    timing = I / "report_timing/camera_1080p_top.rtr"
    assert "Design Summary : All Constraints Met." in timing.read_text(errors="replace"), "Timing failed"
    log = (P / "reports/pds_r21_modes_build.log").read_text(
        encoding="utf-8-sig", errors="replace")
    assert not re.search(r"^E:|Program Error Out", log, re.M)
    assert 'Process "Generate Bitstream" done.' in log
    bit = I / "generate_bitstream/camera_1080p_top.sbit"
    assert bit.stat().st_size > 1000000
    assert bit.stat().st_mtime >= datetime.datetime.fromisoformat(frozen["time"]).timestamp()
    published = P / "bitstream/camera_1080p30_raw8_r21_host_modes.sbit"
    shutil.copy2(bit, published)
    digest = sha(published)
    seed = re.search(r'_option gplace_seed \(_integer (\d+)\)',
                     (I / "camera_1080p30_raw8.pds").read_text(encoding="utf-8"))
    assert seed, "Missing placement seed"
    write(RELEASE, {"implementation": I.name, "placement_seed": int(seed[1]),
                    "project_hash": "inputs-and-options-without-PDS-run-metadata",
                    "candidate": "R21 host modes and pristine-left split",
                    "time": datetime.datetime.now().astimezone().isoformat(),
                    "bitstream": str(published), "bitstream_sha256": digest,
                    "source_sha256": current, "unit_cases": units["cases"],
                    "host_tests": host["tests"],
                    "remap_cycles_with_snapshot": concurrent["remap_cycles_with_snapshot"],
                    "final_timing_pass": True, "timing_sha256": sha(timing),
                    "firmware_rom_match": True,
                    "physical_acceptance": "PENDING", "board_programmed_by_agent": False})
    (P / "bitstream/SHA256SUMS_r21.txt").write_text(
        digest + "  " + published.name + "\n", encoding="ascii")
    print("PASS published R21 candidate", published)


if __name__ == "__main__":
    main()
