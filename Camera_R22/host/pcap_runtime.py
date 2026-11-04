"""Find an installed Npcap/WinPcap runtime, including its dependent DLLs."""
import ctypes
import os
from pathlib import Path

INSTALL_HINT = ('Install or repair Npcap from https://npcap.com/#download . '
                'Select "Install Npcap in WinPcap API-compatible Mode". '
                'Npcap includes a driver; copying wpcap.dll alone is insufficient.')

def load_pcap(system_root=None, loader=None, add_directory=None):
    system_root = Path(system_root or os.environ.get('SystemRoot', r'C:\Windows'))
    loader = loader or ctypes.CDLL  # libpcap functions use cdecl.
    if add_directory is None:
        add_directory = getattr(os, 'add_dll_directory', None)
    system = system_root / 'System32'
    candidates = [system / 'Npcap' / 'wpcap.dll', system / 'wpcap.dll']
    errors = []
    found = False
    for dll in candidates:
        if not dll.is_file():
            continue
        found = True
        handle = None
        try:
            if add_directory:
                handle = add_directory(str(dll.parent))
            library = loader(str(dll))
            library._capture_dll_path = str(dll)
            # Keep the search directory available during the library lifetime.
            library._capture_directory_handle = handle
            return library
        except OSError as error:
            if handle is not None:
                handle.close()
            errors.append(f'{dll}: {error}')
    if not found:
        raise RuntimeError('Npcap/WinPcap runtime is not installed in a standard system location. ' + INSTALL_HINT)
    raise RuntimeError('Npcap/WinPcap DLL was found but could not load (dependency or Python/DLL architecture mismatch). '
                       + INSTALL_HINT + '\n' + '\n'.join(errors))

def version(library):
    library.pcap_lib_version.argtypes = []
    library.pcap_lib_version.restype = ctypes.c_char_p
    return library.pcap_lib_version().decode('utf-8', errors='replace')
