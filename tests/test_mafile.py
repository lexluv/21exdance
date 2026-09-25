import json
import os
import stat

from steam_mafile.mafile import build_mafile, save_mafile


ADD_RESULT = {
    "shared_secret": "c2hhcmVk",
    "serial_number": "123456789",
    "revocation_code": "R12345",
    "uri": "otpauth://totp/Steam:foo?secret=...",
    "server_time": 1700000000,
    "account_name": "foo",
    "token_gid": "abcd",
    "identity_secret": "aWRlbnRpdHk=",
    "secret_1": "c2VjcmV0MQ==",
    "phone_number_hint": "89",
    "device_id": "android:11111111-1111-1111-1111-111111111111",
}


def test_build_mafile_shape():
    mf = build_mafile(ADD_RESULT, 76561198000000000, "refresh", "access")
    assert mf["shared_secret"] == "c2hhcmVk"
    assert mf["revocation_code"] == "R12345"
    assert mf["account_name"] == "foo"
    assert mf["device_id"].startswith("android:")
    assert mf["Session"]["SteamID"] == 76561198000000000
    assert mf["Session"]["RefreshToken"] == "refresh"
    assert mf["Session"]["AccessToken"] == "access"
    # "secret_1" не должен подменять revocation code (нередкая путаница)
    assert mf["secret_1"] != mf["revocation_code"]


def test_save_mafile_writes_valid_json(tmp_path):
    mf = build_mafile(ADD_RESULT, 76561198000000000)
    path = save_mafile(mf, str(tmp_path))
    assert path.endswith("foo.maFile")
    with open(path, encoding="utf-8") as f:
        loaded = json.load(f)
    assert loaded["account_name"] == "foo"
    # права доступа только для владельца
    mode = stat.S_IMODE(os.stat(path).st_mode)
    assert mode == 0o600


def test_save_mafile_sanitizes_filename(tmp_path):
    mf = build_mafile({**ADD_RESULT, "account_name": "ac/../count name"}, 1)
    path = save_mafile(mf, str(tmp_path))
    assert os.path.dirname(path) == str(tmp_path)  # без выхода из каталога
    assert "/" not in os.path.basename(path)[:-len(".maFile")].replace(".", "")
