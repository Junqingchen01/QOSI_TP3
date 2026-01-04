import subprocess

IPS = [
    "192.168.2.50",
    "192.168.2.51",
    "192.168.2.52",
    "192.168.2.53",
    
]

USER = "root"


for ip in IPS:
    subprocess.Popen([
        "cmd", "/c", "start", "cmd", "/k",
        f"ssh {USER}@{ip}"
    ])
