"""Клиент официального мобильного flow Steam: вход по паролю и привязка Guard.

Использует ту же последовательность запросов, что и мобильное приложение Steam
и Steam Desktop Authenticator, к публичному WebAPI api.steampowered.com.
"""

import base64
import time

import requests

from .crypto import generate_device_id, generate_guard_code, rsa_encrypt_password
from .errors import AddAuthenticatorError, LoginError, RateLimitError
from .protobuf import Message, Writer

API_BASE = "https://api.steampowered.com"

# EAuthSessionGuardType
GUARD_NONE = 1
GUARD_EMAIL_CODE = 2
GUARD_DEVICE_CODE = 3
GUARD_DEVICE_CONFIRMATION = 4
GUARD_EMAIL_CONFIRMATION = 5

# EResult (только те коды, что реально встречаются в этом flow)
ERESULT_OK = 1
ERESULT_INVALID_PASSWORD = 5
ERESULT_RATE_LIMIT = 84
ERESULT_TWO_FACTOR_MISMATCH = 88
ERESULT_GUARD_CODE_MISMATCH = 65

PLATFORM_MOBILE_APP = 3
MOBILE_WEBSITE_ID = "Mobile"
USER_AGENT = "Steam App / Android"


class SteamAuthClient:
    def __init__(self, account_name: str, timeout: int = 30):
        self.account_name = account_name
        self.timeout = timeout
        self.session = requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT
        self.steamid = 0
        self.client_id = 0
        self.request_id = b""
        self.access_token = ""
        self.refresh_token = ""
        self._time_offset = 0

    # --- транспорт -------------------------------------------------------
    def _call(self, interface, method, request_bytes, *, http="POST", access_token=None):
        url = f"{API_BASE}/{interface}/{method}/v1/"
        encoded = base64.b64encode(request_bytes).decode("ascii")
        params = {}
        if access_token:
            params["access_token"] = access_token
        if http == "GET":
            params["input_protobuf_encoded"] = encoded
            resp = self.session.get(url, params=params, timeout=self.timeout)
        else:
            resp = self.session.post(
                url, params=params,
                data={"input_protobuf_encoded": encoded}, timeout=self.timeout,
            )
        eresult = int(resp.headers.get("x-eresult", "0") or "0")
        error_msg = resp.headers.get("x-error_message", "")
        return resp.content, eresult, error_msg

    # --- шаг 0: серверное время -----------------------------------------
    def sync_time(self) -> int:
        body, _, _ = self._call("ITwoFactorService", "QueryTime", b"")
        server_time = Message(body).get_int(2)  # field 2: server_time
        self._time_offset = server_time - int(time.time())
        return server_time

    def current_time(self) -> int:
        return int(time.time()) + self._time_offset

    # --- шаг 1: RSA-ключ -------------------------------------------------
    def _get_rsa_key(self):
        req = Writer().string(1, self.account_name).build()
        body, eresult, msg = self._call(
            "IAuthenticationService", "GetPasswordRSAPublicKey", req, http="GET"
        )
        if eresult not in (0, ERESULT_OK):
            raise LoginError(f"GetPasswordRSAPublicKey: EResult {eresult} {msg}")
        m = Message(body)
        return m.get_str(1), m.get_str(2), m.get_int(3)  # mod, exp, timestamp

    # --- шаг 2: начать сессию входа --------------------------------------
    def begin_login(self, password: str):
        modulus, exponent, ts = self._get_rsa_key()
        encrypted = rsa_encrypt_password(password, modulus, exponent)

        device_details = (
            Writer()
            .string(1, "Steam Mafile Binder")
            .varint(2, PLATFORM_MOBILE_APP)
            .varint(3, -500)  # os_type: Android
        )
        req = (
            Writer()
            .string(1, "Steam Mafile Binder")
            .string(2, self.account_name)
            .string(3, encrypted)
            .varint(4, ts)
            .bool(5, True)
            .varint(6, PLATFORM_MOBILE_APP)
            .message(9, device_details)
            .string(8, MOBILE_WEBSITE_ID)
            .build()
        )
        body, eresult, msg = self._call(
            "IAuthenticationService", "BeginAuthSessionViaCredentials", req
        )
        if eresult == ERESULT_INVALID_PASSWORD:
            raise LoginError("Неверный логин или пароль")
        if eresult == ERESULT_RATE_LIMIT:
            raise RateLimitError("Steam ограничил попытки входа, подождите")
        if eresult not in (0, ERESULT_OK):
            raise LoginError(f"BeginAuthSession: EResult {eresult} {msg}")

        m = Message(body)
        self.client_id = m.get_int(1)
        self.request_id = m.get_bytes(2)
        self.steamid = m.get_int(5)
        confirmations = []
        for conf in m.get_messages(4):
            confirmations.append(conf.get_int(1))
        return confirmations  # список EAuthSessionGuardType

    # --- шаг 3: подтвердить кодом с почты --------------------------------
    def submit_email_code(self, code: str, code_type: int = GUARD_EMAIL_CODE):
        req = (
            Writer()
            .varint(1, self.client_id)
            .fixed64(2, self.steamid)
            .string(3, code.strip().upper())
            .varint(4, code_type)
            .build()
        )
        body, eresult, msg = self._call(
            "IAuthenticationService", "UpdateAuthSessionWithSteamGuardCode", req
        )
        if eresult in (ERESULT_TWO_FACTOR_MISMATCH, ERESULT_GUARD_CODE_MISMATCH):
            raise LoginError("Неверный код Steam Guard из письма")
        if eresult not in (0, ERESULT_OK):
            raise LoginError(f"UpdateAuthSession: EResult {eresult} {msg}")

    # --- шаг 4: получить токены -----------------------------------------
    def poll_for_tokens(self, attempts: int = 5, interval: float = 2.0):
        req = (
            Writer()
            .varint(1, self.client_id)
            .bytes(2, self.request_id)
            .build()
        )
        for _ in range(attempts):
            body, eresult, msg = self._call(
                "IAuthenticationService", "PollAuthSessionStatus", req
            )
            if eresult not in (0, ERESULT_OK):
                raise LoginError(f"PollAuthSession: EResult {eresult} {msg}")
            m = Message(body)
            refresh = m.get_str(3)
            access = m.get_str(4)
            if refresh:
                self.refresh_token = refresh
                self.access_token = access or refresh
                return True
            time.sleep(interval)
        raise LoginError("Вход не подтверждён (нет токена после опроса)")

    # --- шаг 5: привязать аутентификатор ---------------------------------
    def add_authenticator(self) -> dict:
        device_id = generate_device_id()
        req = (
            Writer()
            .fixed64(1, self.steamid)
            .varint(2, self.current_time())
            .varint(4, 1)            # authenticator_type: 1 = мобильный
            .string(5, device_id)    # device_identifier
            .varint(9, 2)            # version
            .build()
        )
        body, eresult, msg = self._call(
            "ITwoFactorService", "AddAuthenticator", req,
            access_token=self.access_token,
        )
        if eresult not in (0, ERESULT_OK):
            raise AddAuthenticatorError(f"AddAuthenticator: EResult {eresult} {msg}")
        m = Message(body)
        status = m.get_int(10)
        if status != 1:
            raise AddAuthenticatorError(
                f"AddAuthenticator вернул status={status}. "
                "Обычно значит, что к аккаунту не привязан телефон "
                "(его нужно добавить в настройках Steam)."
            )
        return {
            "shared_secret": base64.b64encode(m.get_bytes(1)).decode("ascii"),
            "serial_number": str(m.get_int(2)),
            "revocation_code": m.get_str(3),
            "uri": m.get_str(4),
            "server_time": m.get_int(5),
            "account_name": m.get_str(6),
            "token_gid": m.get_str(7),
            "identity_secret": base64.b64encode(m.get_bytes(8)).decode("ascii"),
            "secret_1": base64.b64encode(m.get_bytes(9)).decode("ascii"),
            "phone_number_hint": m.get_str(11),
            "device_id": device_id,
        }

    # --- шаг 6: завершить привязку кодом активации -----------------------
    def finalize_authenticator(self, shared_secret: str, activation_code: str,
                               max_tries: int = 30) -> None:
        want_more = True
        tries = 0
        while want_more and tries < max_tries:
            ts = self.current_time()
            guard_code = generate_guard_code(shared_secret, ts)
            req = (
                Writer()
                .fixed64(1, self.steamid)
                .string(2, guard_code)
                .varint(3, ts)
                .string(4, activation_code.strip())
                .build()
            )
            body, eresult, msg = self._call(
                "ITwoFactorService", "FinalizeAddAuthenticator", req,
                access_token=self.access_token,
            )
            if eresult == ERESULT_TWO_FACTOR_MISMATCH:
                raise AddAuthenticatorError("Неверный код активации (SMS/почта)")
            if eresult not in (0, ERESULT_OK):
                raise AddAuthenticatorError(
                    f"FinalizeAddAuthenticator: EResult {eresult} {msg}"
                )
            m = Message(body)
            success = bool(m.get_int(1))
            want_more = bool(m.get_int(2))
            if success and not want_more:
                return
            tries += 1
            if want_more:
                time.sleep(30 - (ts % 30) + 1)  # дождаться следующего окна TOTP
        raise AddAuthenticatorError("Не удалось завершить привязку аутентификатора")
