"""R21 host protocol, legacy compatibility, GUI and snapshot regression."""
from pathlib import Path
import hashlib
import json
import sys
import unittest

P = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(P / "host/camera_console"))
import test_tuning
import test_transport
import test_r20_host
import test_r21_modes
import test_ghe

suite = unittest.TestSuite()
for module in (test_tuning, test_transport, test_r20_host, test_r21_modes, test_ghe):
    suite.addTests(unittest.defaultTestLoader.loadTestsFromModule(module))
result = unittest.TextTestRunner(verbosity=1).run(suite)
files = ["host/camera_console/console.py", "host/camera_console/tuning.py",
         "host/camera_console/transport.py", "host/camera_console/storage.py",
         "host/camera_console/test_tuning.py", "host/camera_console/test_transport.py",
         "host/camera_console/test_r20_host.py",
         "host/camera_console/test_r21_modes.py", "host/camera_console/test_ghe.py"]
report = {"pass": result.wasSuccessful(), "tests": result.testsRun,
          "failures": len(result.failures), "errors": len(result.errors),
          "real_board_test": False,
          "source_sha256": {f: hashlib.sha256((P / f).read_bytes()).hexdigest() for f in files}}
(P / "reports/r21_host_validation.json").write_text(
    json.dumps(report, indent=2) + "\n", encoding="utf-8")
sys.exit(0 if result.wasSuccessful() else 1)
