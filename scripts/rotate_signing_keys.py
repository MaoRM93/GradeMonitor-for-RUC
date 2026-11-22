#!/usr/bin/env python3
"""Rotate GradeMonitor signing keys and create an encrypted recovery backup.

The recovery passphrase is read from the controlling terminal only.  It never
appears in command-line arguments, environment variables, or the backup name.
"""
from __future__ import annotations

import getpass
import json
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path
from tempfile import TemporaryDirectory


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "backend" / "bin" / "keychain_secret"
SERVICE = "GradeMonitorSigning"
KEYS = {
    "control-signing-ed25519-v2": "control",
    "release-signing-ed25519-v2": "release",
}


def run_openssl(args: list[str], *, input_data: bytes | None = None) -> bytes:
    result = subprocess.run(
        ["openssl", *args], input=input_data, capture_output=True, timeout=60
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


def public_b64(pem: bytes) -> str:
    # Ed25519 SubjectPublicKeyInfo DER is a fixed 12-byte header followed by
    # the raw 32-byte public key.  Use the macOS-bundled OpenSSL so this tool
    # works even when the system Python lacks the project's dependencies.
    import base64

    der = run_openssl(["pkey", "-pubout", "-outform", "DER"], input_data=pem)
    if len(der) != 44 or der[:12] != bytes.fromhex("302a300506032b6570032100"):
        raise RuntimeError("OpenSSL 返回了意外的 Ed25519 公钥格式")
    return base64.b64encode(der[12:]).decode("ascii")


def write_keychain(account: str, pem: bytes) -> None:
    import subprocess

    result = subprocess.run(
        [str(HELPER), "write", SERVICE, account],
        input=pem,
        capture_output=True,
        timeout=60,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(detail or f"无法写入钥匙串条目 {account}")


def encrypted_backup(destination: Path, payload: bytes, passphrase: str) -> None:
    # `openssl enc` derives the key with PBKDF2 and never receives the
    # passphrase on argv.  The result is its standard salted binary format.
    with TemporaryDirectory(prefix="gm-signing-") as temporary_dir:
        plaintext = Path(temporary_dir) / "keys.json"
        plaintext.write_bytes(payload)
        os.chmod(plaintext, 0o600)
        result = subprocess.run(
            ["openssl", "enc", "-aes-256-cbc", "-salt", "-pbkdf2", "-iter", "600000", "-pass", "fd:0", "-in", str(plaintext)],
            input=passphrase.encode("utf-8"), capture_output=True, timeout=60,
        )
        if result.returncode != 0:
            raise RuntimeError(result.stderr.decode("utf-8", errors="replace").strip())
        data = result.stdout
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_name(f".{destination.name}.{secrets.token_hex(6)}.tmp")
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, destination)
        os.chmod(destination, 0o600)
    finally:
        if temporary.exists():
            temporary.unlink()


def main() -> int:
    if not HELPER.is_file() or not os.access(HELPER, os.X_OK):
        raise RuntimeError(f"缺少钥匙串助手：{HELPER}")
    if shutil.which("openssl") is None:
        raise RuntimeError("系统缺少 openssl，无法安全生成与备份密钥")
    default = Path.home() / "Desktop" / "GradeMonitor-signing-keys.backup.enc"
    arguments = sys.argv[1:]
    stdin_passphrase = "--stdin-passphrase" in arguments
    arguments = [argument for argument in arguments if argument != "--stdin-passphrase"]
    destination = Path(arguments[0]).expanduser() if len(arguments) == 1 else default
    if len(arguments) > 1:
        raise SystemExit(
            f"用法：{Path(sys.argv[0]).name} [加密备份路径] [--stdin-passphrase]"
        )

    if stdin_passphrase:
        # Automation may supply the recovery phrase over a private pipe.  It is
        # deliberately not accepted through argv or an environment variable.
        passphrase = sys.stdin.buffer.readline().rstrip(b"\r\n").decode("utf-8")
        confirmation = passphrase
    else:
        passphrase = getpass.getpass("恢复备份口令：")
        confirmation = getpass.getpass("再次输入恢复备份口令：")
    if not passphrase or passphrase != confirmation:
        raise RuntimeError("两次口令不一致或为空；未做任何更改")

    generated = {
        account: run_openssl(["genpkey", "-algorithm", "ED25519"])
        for account in KEYS
    }
    public = {name: public_b64(generated[account]) for account, name in KEYS.items()}
    payload = json.dumps(
        {
            "format": "GradeMonitor-signing-private-keys-v1",
            "keys": {account: pem.decode("utf-8") for account, pem in generated.items()},
        },
        separators=(",", ":"),
    ).encode("utf-8")
    encrypted_backup(destination, payload, passphrase)
    for account, pem in generated.items():
        write_keychain(account, pem)

    print(json.dumps({"backup": str(destination), "public_keys": public}, indent=2))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"轮换失败：{error}", file=sys.stderr)
        raise SystemExit(1)
