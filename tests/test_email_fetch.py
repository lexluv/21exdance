import pytest

from steam_mafile.email_fetch import (
    IMAP_PRESETS, extract_steam_code, imap_settings_for,
)
from steam_mafile.errors import SteamMafileError


def _raw(from_addr, subject, body, content_type="text/plain; charset=utf-8"):
    return (
        f"From: {from_addr}\r\n"
        f"Subject: {subject}\r\n"
        f"Content-Type: {content_type}\r\n"
        f"\r\n"
        f"{body}"
    ).encode("utf-8")


def test_imap_preset_outlook():
    assert imap_settings_for("someone@outlook.com") == ("outlook.office365.com", 993)
    assert imap_settings_for("someone@hotmail.com") == ("outlook.office365.com", 993)


def test_imap_explicit_host_wins():
    assert imap_settings_for("x@corp.local", host="mail.corp", port=143) == \
        ("mail.corp", 143)


def test_imap_unknown_domain_raises():
    with pytest.raises(SteamMafileError, match="IMAP"):
        imap_settings_for("x@unknown-domain-xyz.tld")


def test_all_presets_have_port():
    for host, port in IMAP_PRESETS.values():
        assert isinstance(host, str) and host
        assert port == 993


def test_extract_plaintext_login_code():
    body = ("Here is the Steam Guard code you need to login:\r\n\r\n"
            "  K7M9P\r\n\r\nThis email was generated because ...")
    raw = _raw("Steam <noreply@steampowered.com>", "Your Steam account", body)
    assert extract_steam_code(raw) == "K7M9P"


def test_extract_html_login_code():
    body = ('<html><body><p>Login Code</p>'
            '<div style="font-size:32px">R2T4W</div></body></html>')
    raw = _raw("noreply@steampowered.com", "Access from new device", body,
               content_type="text/html; charset=utf-8")
    assert extract_steam_code(raw) == "R2T4W"


def test_ignores_non_steam_sender():
    body = "Your code is K7M9P"
    raw = _raw("phish@evil.example", "Steam code", body)
    assert extract_steam_code(raw) is None


def test_prefers_code_near_keyword():
    # Случайный 5-символьный токен раньше настоящего кода, но код у ключевого слова.
    body = ("Ref: VWXYB somewhere unrelated.\r\n"
            "Login Code: M3N4P\r\n")
    raw = _raw("noreply@steampowered.com", "Steam Guard", body)
    assert extract_steam_code(raw) == "M3N4P"


def test_returns_none_when_no_code():
    raw = _raw("noreply@steampowered.com", "Newsletter", "No codes here, thanks!")
    assert extract_steam_code(raw) is None
