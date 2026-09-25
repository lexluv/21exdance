"""Сборка и сохранение .maFile в формате Steam Desktop Authenticator."""

import json
import os
import re


def build_mafile(add_result: dict, steamid: int, refresh_token: str = "",
                 access_token: str = "") -> dict:
    """Собирает словарь .maFile из ответа AddAuthenticator."""
    return {
        "shared_secret": add_result["shared_secret"],
        "serial_number": add_result["serial_number"],
        "revocation_code": add_result["revocation_code"],
        "uri": add_result["uri"],
        "server_time": add_result["server_time"],
        "account_name": add_result["account_name"],
        "token_gid": add_result["token_gid"],
        "identity_secret": add_result["identity_secret"],
        "secret_1": add_result["secret_1"],
        "status": 1,
        "device_id": add_result["device_id"],
        "fully_enrolled": True,
        "Session": {
            "SteamID": steamid,
            "AccessToken": access_token,
            "RefreshToken": refresh_token,
            "SessionID": "",
            "WebCookie": "",
            "OAuthToken": "",
        },
    }


def _safe_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", name)
    return cleaned or "account"


def save_mafile(mafile: dict, out_dir: str, filename: str | None = None) -> str:
    os.makedirs(out_dir, exist_ok=True)
    if not filename:
        filename = f"{_safe_name(mafile.get('account_name', 'account'))}.maFile"
    path = os.path.join(out_dir, filename)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(mafile, f, indent=2, ensure_ascii=False)
    os.chmod(path, 0o600)  # секреты — только владельцу
    return path
