"""Read-only PC preflight for the isolated ATK OV1 1080p30 candidate."""
from pathlib import Path
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
SHARED = Path(r"D:\pango\pango100Pro\1080-30hz\Image_Undistort_100Pro_v1\tools")
PDS = Path(r"D:\pango\PDS_2022.2-SP6.4\bin")
SOURCE = Path(r"D:\pango\pango100Pro\video-720-30hz\Image_Undistort_100Pro_v1")


def check(label: str, present: bool, detail: object) -> bool:
    print("PASS" if present else "FAIL", label, detail)
    return present


def main() -> int:
    ok = True
    print("R7 integer-clock1080p30 candidate PC preflight; no board access or bitstream changes")
    print("Project:", ROOT)
    ok &= check("Python 3.12 x64", sys.version_info[:2] == (3, 12) and struct.calcsize("P") == 8, sys.executable)
    for name in ("pds.exe", "pds_shell.exe"):
        ok &= check("PDS", (PDS / name).is_file(), PDS / name)
    for relative in ("pnr_camera/camera_1080p30_intclk.pds", "pnr_camera/camera_1080p_top.fdc",
                     "rtl/camera_1080p_top.v", "firmware/camera_main.c"):
        ok &= check("camera source", (ROOT / relative).is_file(), relative)
    gcc = next((base / "riscv-gcc/bin/riscv-none-embed-gcc.exe" for base in (ROOT / "tools", SHARED)
                if (base / "riscv-gcc/bin/riscv-none-embed-gcc.exe").is_file()), None)
    ok &= check("RISC-V GCC", gcc is not None, gcc or "missing locally and in shared 1080-30hz tools")
    iverilog = next((base / "tools/iverilog/bin/iverilog.exe" for base in (ROOT, SOURCE)
                     if (base / "tools/iverilog/bin/iverilog.exe").is_file()), None)
    print("Icarus Verilog:", iverilog or "not needed for PDS build")
    candidate = ROOT / "bitstream/camera_1080p30_intclk_r7.sbit"
    print("Timing-gated candidate bitstream:", candidate if candidate.is_file() else "NOT RELEASED")
    sys.path[:0] = [str(ROOT / "tools/python_packages"), str(SHARED / "python_packages")]
    try:
        import serial
        from serial.tools import list_ports
        print("PASS pyserial", serial.VERSION)
        ports = [(p.device, p.description) for p in list_ports.comports() if "CP210" in p.description.upper()]
        print("CP210x UART:", ports or "not connected; reconnect USB_UART before measuring")
    except (ImportError, OSError) as exc:
        print("FAIL pyserial", exc)
        ok = False
    print("PC preflight:", "PASS" if ok else "FAIL")
    print("This does not verify camera wiring, J20 voltage, HDMI image, or live frame rate.")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
