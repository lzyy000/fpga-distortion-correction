"""R21 mode protocol and actual control layout; no board required."""
import sys
import unittest
from pathlib import Path

from tuning import StrengthControl, MODE_BITS
from transport import SnapshotClient
from test_r20_host import NightBoard

P = Path(__file__).resolve().parents[2]


def reply(cmd, modes=0, applied=0, night=100, denoise=100):
    return (f"TUNE v=21 cmd={cmd:08X} night={night} denoise={denoise} "
            f"night_q8={(night*256+50)//100} denoise_q8={(denoise*256+50)//100} "
            f"night_on={bool(modes&8):d} denoise_on={bool(modes&4):d} "
            f"modes={modes} applied={applied}")


class ModeProtocolTests(unittest.TestCase):
    def setUp(self):
        self.events = []
        self.control = StrengthControl(lambda kind, value: self.events.append((kind, value)))
        self.assertEqual(self.control.tick(0), b"\xf0")
        self.assertTrue(self.control.receive(reply(240)))

    def test_four_independent_mode_bits_and_combined_ack(self):
        for key in ('correct','split','denoise','night'):
            self.assertTrue(self.control.request_mode(key, True, .1))
        self.assertIsNone(self.control.tick(.2))
        self.assertEqual(self.control.tick(.3), b"\x7f")
        self.assertFalse(self.control.receive(reply(127, modes=7)))
        self.assertTrue(self.control.receive(reply(127, modes=15, applied=15)))
        self.assertEqual(self.events[-1][1]["modes"], 15)
        self.assertEqual(self.events[-1][1]["applied_modes"], 15)
        self.assertEqual(self.control.tick(.4), None)

    def test_disable_one_mode_preserves_other_three(self):
        self.control.request_mode("correct", True, .1)
        self.control.request_mode("split", True, .1)
        self.control.request_mode("denoise", True, .1)
        self.control.request_mode("night", True, .1)
        self.assertEqual(self.control.tick(.3), b"\x7f")
        self.assertTrue(self.control.receive(reply(127, modes=15)))
        self.control.request_mode("night", False, .4)
        self.assertEqual(self.control.tick(.6), b"\x77")
        self.assertTrue(self.control.receive(reply(119, modes=7, applied=7)))
        self.assertEqual(self.control.confirmed_modes, 7)

    def test_strength_does_not_change_modes(self):
        self.control.request_mode("night", True, .1)
        self.assertEqual(self.control.tick(.3), b"\x78")
        self.assertTrue(self.control.receive(reply(120, modes=8)))
        self.control.request("night", 35, .4)
        self.assertEqual(self.control.tick(.6), bytes([163]))
        self.assertTrue(self.control.receive(reply(163, modes=8, night=35)))
        self.assertEqual(self.control.confirmed_modes, 8)

    def test_legacy_board_rejects_mode_writes(self):
        old = StrengthControl(lambda *_: None)
        self.assertEqual(old.tick(0), b"\xf0")
        self.assertTrue(old.receive(reply(240).replace("v=21", "v=20").split(" modes=")[0]))
        self.assertFalse(old.request_mode("night", True, .1))
        self.assertIsNone(old.tick(.3))


class ModeGuiTests(unittest.TestCase):
    def test_buttons_and_conditional_strength_controls(self):
        args = sys.argv
        sys.argv = [str(P / "host/camera_console/console.py")]
        import console
        sys.argv = args
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
        app = console.CameraConsole(root,discover=False)
        try:
            app.emit("tune_ack", dict(night=100, denoise=100, night_on=False,
                                      denoise_on=False, modes=0, applied_modes=0,
                                      firmware_version=21, first=True))
            app.poll_events()
            self.assertEqual(set(app.mode_buttons), set(MODE_BITS))
            self.assertTrue(all("disabled" not in app.mode_buttons[key].state() for key in ("correct","split","denoise","night")))
            tab = app.tuning_canvas.master
            root.geometry("1060x720")
            root.deiconify()
            tab.master.select(tab)
            root.update()
            self.assertFalse(app.strength_scales["night"].winfo_ismapped())
            app.mode_clicked("night")
            self.assertEqual(app.tuning_requests.get_nowait(), ("mode", "night", True))
            root.update()
            self.assertTrue(app.strength_scales["night"].winfo_ismapped())
            self.assertFalse(app.strength_scales["denoise"].winfo_ismapped())
            app.emit("tune_ack", dict(night=100, denoise=100, night_on=True,
                                      denoise_on=False, modes=8, applied_modes=8,
                                      firmware_version=21, first=False))
            app.poll_events()
            self.assertFalse(app.mode_pending)
            self.assertEqual(app.mode_buttons["night"].cget("text"), "关闭")
        finally:
            app.closing = True
            app.serial_stop.set()
            for token in root.tk.call("after", "info"):
                root.after_cancel(token)
            root.destroy()


class R21SnapshotCompatibilityTests(unittest.TestCase):
    def test_host_mode_capability_labels_fpga_snapshot(self):
        pixels = b"\x10\x42" * (64 * 8)
        board = NightBoard(pixels, (64, 8))
        board.host_modes = True
        client = SnapshotClient("127.0.0.1", "127.0.0.1", 0, board.port, (64, 8))
        try:
            info = client.hello(timeout=1)
            self.assertIn("host_modes", info["capabilities"])
            result = client.capture(timeout=3, retry_interval=.15)
            self.assertEqual(result["pixels"], pixels)
            self.assertEqual(result["processing"], "fpga_frame_night_follow_host_mode")
        finally:
            client.close()
            board.close()


if __name__ == "__main__":
    unittest.main()
