"""Проверка конечного автомата клиента через подменённый транспорт (без сети)."""

import base64

import pytest

from steam_mafile.client import (
    GUARD_EMAIL_CODE, ERESULT_INVALID_PASSWORD, ERESULT_OK, SteamAuthClient,
)
from steam_mafile.errors import AddAuthenticatorError, LoginError
from steam_mafile.protobuf import Message, Writer


def make_client(responses):
    """responses: dict (interface, method) -> (bytes, eresult, msg) или список таких."""
    client = SteamAuthClient("tester")
    calls = []

    def fake_call(interface, method, request_bytes, *, http="POST", access_token=None):
        calls.append((interface, method, Message(request_bytes), access_token))
        entry = responses[(interface, method)]
        if isinstance(entry, list):
            return entry.pop(0)
        return entry

    client._call = fake_call
    client._calls = calls
    return client


def rsa_key_response():
    # Настоящий по размеру модуль (512 бит), чтобы шифрование пароля прошло.
    # Само шифрование детально проверяется в test_crypto.
    n = (0xa970654f01a27ae2e8ba456afd3cc7afb61ce648f6b5579986340356d3285e85
         * 0x9b79e8092b3e2660b79b687b9f24227b528f1e38d8d1e33220d09330d9781203)
    body = Writer().string(1, format(n, "x")).string(2, "10001").varint(3, 111).build()
    return body, ERESULT_OK, ""


def test_begin_login_parses_confirmations_and_ids():
    begin = (
        Writer()
        .varint(1, 42)                       # client_id
        .bytes(2, b"reqid")                   # request_id
        .fixed64(5, 76561198000000000)        # steamid
        .message(4, Writer().varint(1, GUARD_EMAIL_CODE))
        .build()
    )
    client = make_client({
        ("IAuthenticationService", "GetPasswordRSAPublicKey"): rsa_key_response(),
        ("IAuthenticationService", "BeginAuthSessionViaCredentials"):
            (begin, ERESULT_OK, ""),
    })
    confs = client.begin_login("pw")
    assert confs == [GUARD_EMAIL_CODE]
    assert client.client_id == 42
    assert client.request_id == b"reqid"
    assert client.steamid == 76561198000000000


def test_begin_login_invalid_password():
    client = make_client({
        ("IAuthenticationService", "GetPasswordRSAPublicKey"): rsa_key_response(),
        ("IAuthenticationService", "BeginAuthSessionViaCredentials"):
            (b"", ERESULT_INVALID_PASSWORD, ""),
    })
    with pytest.raises(LoginError, match="пароль"):
        client.begin_login("bad")


def test_submit_email_code_sends_upper_and_type():
    client = make_client({
        ("IAuthenticationService", "UpdateAuthSessionWithSteamGuardCode"):
            (b"", ERESULT_OK, ""),
    })
    client.client_id = 7
    client.steamid = 99
    client.submit_email_code("abcde", GUARD_EMAIL_CODE)
    _, _, req, _ = client._calls[0]
    assert req.get_str(3) == "ABCDE"
    assert req.get_int(4) == GUARD_EMAIL_CODE


def test_poll_waits_then_returns_token():
    empty = Writer().build()
    ready = Writer().string(3, "refresh_tok").string(4, "access_tok").build()
    client = make_client({
        ("IAuthenticationService", "PollAuthSessionStatus"):
            [(empty, ERESULT_OK, ""), (ready, ERESULT_OK, "")],
    })
    ok = client.poll_for_tokens(attempts=3, interval=0)
    assert ok
    assert client.refresh_token == "refresh_tok"
    assert client.access_token == "access_tok"


def test_add_authenticator_success_and_error_status():
    ok_body = (
        Writer()
        .bytes(1, b"shared")
        .varint(2, 555)
        .string(3, "R55555")
        .string(4, "otpauth://x")
        .varint(5, 1700000000)
        .string(6, "tester")
        .string(7, "gid")
        .bytes(8, b"identity")
        .bytes(9, b"secret1")
        .varint(10, 1)               # status == 1 -> успех
        .string(11, "77")
        .build()
    )
    client = make_client({
        ("ITwoFactorService", "AddAuthenticator"): (ok_body, ERESULT_OK, ""),
    })
    client.access_token = "tok"
    res = client.add_authenticator()
    assert res["revocation_code"] == "R55555"
    assert res["shared_secret"] == base64.b64encode(b"shared").decode()
    assert res["phone_number_hint"] == "77"
    # access_token должен уходить в запрос
    assert client._calls[0][3] == "tok"

    bad = Writer().varint(10, 2).build()  # status 2 -> нет телефона
    client2 = make_client({
        ("ITwoFactorService", "AddAuthenticator"): (bad, ERESULT_OK, ""),
    })
    client2.access_token = "tok"
    with pytest.raises(AddAuthenticatorError, match="телефон"):
        client2.add_authenticator()


def test_finalize_success_first_try():
    secret = base64.b64encode(b"\x00" * 20).decode()
    done = Writer().varint(1, 1).varint(2, 0).build()  # success=1, want_more=0
    client = make_client({
        ("ITwoFactorService", "FinalizeAddAuthenticator"): (done, ERESULT_OK, ""),
    })
    client.access_token = "tok"
    client.steamid = 5
    client.finalize_authenticator(secret, "12345")
    _, _, req, tok = client._calls[0]
    assert req.get_str(4) == "12345"     # activation_code
    assert len(req.get_str(2)) == 5      # сгенерированный TOTP-код
    assert tok == "tok"
