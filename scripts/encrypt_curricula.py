"""把培养方案加密为仅 GradeMonitor 本地服务可解密的资源。"""
from pathlib import Path
import os
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "assets" / "curricula"
KEY = b"SnShSAul5176K4h4hufxCrmSs7zUfvbo"
SOURCES = {
    "2024": Path("/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/此电脑/A-专业学习/2024级本科生培养方案.pdf"),
    "2025": Path("/Users/admin/Library/Mobile Documents/com~apple~CloudDocs/此电脑/A-专业学习/大二/大二上/骐骥计划/2025培养方案（全校）.pdf"),
    "2026": ROOT / "2026级大类培养方案.pdf",
}

OUT.mkdir(parents=True, exist_ok=True)
for grade, source in SOURCES.items():
    data = source.read_bytes()
    nonce = os.urandom(12)
    payload = b"GMCP1" + nonce + AESGCM(KEY).encrypt(nonce, data, grade.encode())
    target = OUT / f"{grade}.pdf.enc"
    target.write_bytes(payload)
    print(f"{grade}: {len(data)} -> {len(payload)} bytes")
