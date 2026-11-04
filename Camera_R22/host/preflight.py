import sys,serial,json
from serial.tools import list_ports
ports=[p for p in list_ports.comports() if 'CP210' in p.description.upper()]
if '--json' in sys.argv:
    print(json.dumps([p.device for p in ports]))
else:
    print(sys.version)
    print('PASS pyserial',serial.__version__)
    print('CP210x UART:',[(p.device,p.description) for p in ports])
    print('Read-only enumeration; no UART or board connection attempted')
