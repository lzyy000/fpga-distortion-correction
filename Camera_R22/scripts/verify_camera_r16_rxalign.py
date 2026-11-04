"""Compatibility command filename; verifies the current R21 project."""
from pathlib import Path
import runpy
if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).with_name('verify_camera_r21_modes.py')), run_name='__main__')
