from pathlib import Path
import sys, struct, subprocess, base64, json
# A patch extracted as a nested folder must use the original project's packages.
PATCH_ROOT=Path(__file__).resolve().parents[1]
ROOT=next((p for p in (PATCH_ROOT,*list(PATCH_ROOT.parents)[:3])
           if (p/'host/common.py').is_file()
           and (p/'host/calibrate_network.py').is_file()
           and (p/'09_Calibrate_And_Upload.cmd').is_file()),None)
if ROOT is None:
    sys.exit('ERROR: Original project not found. This is a patch, not a complete project.\n'
             'Extract it inside the original project and run Apply_PC_Fix.cmd first.')
sys.path.insert(0,str(ROOT/'tools/python_packages'))
from pcap_runtime import load_pcap,version

def main():
    errors=[]
    print('Project:',ROOT)
    if ROOT!=PATCH_ROOT:
        print('NOTICE: Running from a nested patch folder. Run Apply_PC_Fix.cmd first,')
        print('then run 11 and 09 from the PROJECT folder printed above.')
    print('Python:',sys.executable)
    print('Version:',sys.version.split()[0], 'bits:',struct.calcsize('P')*8)
    if sys.version_info[:2]!=(3,12) or struct.calcsize('P')!=8:
        errors.append('Use Python 3.12 x64 for the bundled numpy/OpenCV libraries.')
    for name in ('serial','numpy','cv2'):
        try:
            module=__import__(name)
            print('PASS package:',name,getattr(module,'__version__','available'))
        except (ImportError,OSError) as e:
            errors.append(f'Package {name}: {e}')
    try:
        lib=load_pcap()
        print('PASS capture DLL:',lib._capture_dll_path)
        print('Capture version:',version(lib))
    except RuntimeError as e:
        errors.append(str(e))
    try:
        from serial.tools import list_ports
        for port in list_ports.comports():
            print('Serial:',port.device,port.description, 'CP210x' if port.vid==0x10c4 else '')
    except (ImportError,OSError):pass
    # Base64 keeps PowerShell's localized console encoding out of the transport.
    command=("$d=[ordered]@{drivers=@(Get-Service npcap,npf -ErrorAction SilentlyContinue | "
             "ForEach-Object { @{name=$_.Name;status=$_.Status.ToString()} }); "
             "ips=@(Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq '192.168.1.105' | Select-Object IPAddress,InterfaceIndex); "
             "adapters=@(Get-NetAdapter | Select-Object ifIndex,Status,LinkSpeed)}; "
             "$j=$d | ConvertTo-Json -Depth 4 -Compress; [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($j))")
    r=subprocess.run(['powershell.exe','-NoProfile','-Command',command],capture_output=True,text=True,encoding='ascii',errors='replace')
    if r.returncode:
        print('Could not inspect Windows services/network; driver and IP need manual checking.')
    else:
        data=json.loads(base64.b64decode(r.stdout.strip()).decode('utf-8'))
        for driver in data['drivers']:print('Capture driver:',driver['name'],driver['status'])
        for ip in data['ips']:print('Target local IPv4:',ip['IPAddress'],'interface:',ip['InterfaceIndex'])
        if not data['ips']:print('NOTICE: 192.168.1.105 is not assigned; configure the board-facing Ethernet adapter before 09.')
        for adapter in data['adapters']:print('Adapter:',adapter['ifIndex'],adapter['Status'],adapter['LinkSpeed'])
    if errors:
        for error in errors:print('ERROR:',error)
        return 1
    print('Runtime checks passed. For 09: close SSCOM/NetAssist, use Ethernet 192.168.1.105/24 and 1Gbps.')
    print('A DLL check does not prove the capture driver can open the target Ethernet interface.')
    return 0
if __name__=='__main__':sys.exit(main())
