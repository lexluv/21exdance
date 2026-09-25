"""Автовыгрузка кода Steam Guard из почты по IMAP (Outlook и не только).

Только для почты, доступ к которой у вас есть. Разбор письма вынесен отдельно
от подключения, чтобы его можно было тестировать без сети.
"""

import email
import imaplib
import re
import time
from email.header import decode_header, make_header
from email.message import Message as EmailMessage

from .errors import SteamMafileError

# Пресеты IMAP по популярным доменам почты.
IMAP_PRESETS = {
    "outlook.com": ("outlook.office365.com", 993),
    "hotmail.com": ("outlook.office365.com", 993),
    "live.com": ("outlook.office365.com", 993),
    "office365.com": ("outlook.office365.com", 993),
    "gmail.com": ("imap.gmail.com", 993),
    "googlemail.com": ("imap.gmail.com", 993),
    "yahoo.com": ("imap.mail.yahoo.com", 993),
    "rambler.ru": ("imap.rambler.ru", 993),
    "mail.ru": ("imap.mail.ru", 993),
    "yandex.ru": ("imap.yandex.ru", 993),
    "yandex.com": ("imap.yandex.com", 993),
}

STEAM_SENDERS = ("steampowered.com", "steamcommunity.com")
# Код входа Steam Guard: ровно 5 символов из «безопасного» алфавита Steam
# (без 0/1/I/O/A/E/L/S/U/Z и т.п.). Тот же алфавит, что у мобильных кодов.
_TOKEN = r"[2-9BCDFGHJKMNPQRTVWXY]{5}"
_CODE_RE = re.compile(rf"\b({_TOKEN})\b")
# Код сразу после ключевого слова ("Login Code: XXXXX", "код: XXXXX").
_KEYWORD_CODE_RE = re.compile(
    rf"(?:login code|steam guard code|access code|\bcode|\bкод)[\s:>=\-]*\b({_TOKEN})\b",
    re.IGNORECASE,
)


def imap_settings_for(email_addr: str, host: str | None = None,
                      port: int | None = None) -> tuple[str, int]:
    """Возвращает (host, port) по домену почты либо явно заданные значения."""
    if host:
        return host, port or 993
    domain = email_addr.rsplit("@", 1)[-1].lower()
    if domain in IMAP_PRESETS:
        h, p = IMAP_PRESETS[domain]
        return h, (port or p)
    raise SteamMafileError(
        f"Не знаю IMAP-сервер для домена '{domain}'. "
        "Укажите его явно параметром --imap-host."
    )


def _body_text(msg: EmailMessage) -> str:
    """Достаёт текст письма (предпочитая text/plain), из multipart тоже."""
    parts = []
    if msg.is_multipart():
        for part in msg.walk():
            ctype = part.get_content_type()
            if ctype in ("text/plain", "text/html") and \
                    "attachment" not in str(part.get("Content-Disposition", "")):
                payload = part.get_payload(decode=True)
                if payload:
                    charset = part.get_content_charset() or "utf-8"
                    parts.append(payload.decode(charset, errors="replace"))
    else:
        payload = msg.get_payload(decode=True)
        if payload:
            charset = msg.get_content_charset() or "utf-8"
            parts.append(payload.decode(charset, errors="replace"))
    return "\n".join(parts)


def _strip_html(text: str) -> str:
    text = re.sub(r"(?is)<(script|style).*?</\1>", " ", text)
    text = re.sub(r"(?s)<[^>]+>", " ", text)
    return re.sub(r"\s+", " ", text)


def extract_steam_code(raw_bytes: bytes) -> str | None:
    """Извлекает 5-значный код Steam Guard из сырого письма (RFC822).

    Возвращает код или None, если это не письмо Steam с кодом.
    """
    msg = email.message_from_bytes(raw_bytes)
    sender = str(msg.get("From", "")).lower()
    if not any(s in sender for s in STEAM_SENDERS):
        return None

    text = _strip_html(_body_text(msg))
    subject = str(make_header(decode_header(msg.get("Subject", ""))))
    haystack = f"{subject}\n{text}"

    # Сначала код, стоящий сразу после ключевого слова ("Login Code: XXXXX").
    m = _KEYWORD_CODE_RE.search(haystack)
    if m:
        return m.group(1)
    # Иначе — первый подходящий 5-символьный токен в теле письма.
    m = _CODE_RE.search(text)
    return m.group(1) if m else None


class EmailCodeFetcher:
    """Ждёт письмо Steam Guard в ящике по IMAP и возвращает код."""

    def __init__(self, email_addr: str, password: str,
                 host: str | None = None, port: int | None = None,
                 mailbox: str = "INBOX"):
        self.email_addr = email_addr
        self.password = password
        self.host, self.port = imap_settings_for(email_addr, host, port)
        self.mailbox = mailbox

    def _connect(self) -> imaplib.IMAP4_SSL:
        try:
            conn = imaplib.IMAP4_SSL(self.host, self.port)
            conn.login(self.email_addr, self.password)
        except imaplib.IMAP4.error as e:
            raise SteamMafileError(
                f"IMAP-вход не удался ({e}). Для Outlook/Office365 включите "
                "IMAP и используйте app password (basic-auth по паролю часто "
                "отключён)."
            )
        except OSError as e:
            raise SteamMafileError(f"Не удалось подключиться к {self.host}:{self.port} ({e})")
        return conn

    def fetch_code(self, timeout: int = 120, poll_interval: int = 5,
                   started_at: float | None = None) -> str:
        """Опрашивает ящик, пока не появится код Steam Guard или не выйдет timeout."""
        started_at = started_at or time.time()
        conn = self._connect()
        try:
            deadline = time.time() + timeout
            seen_ids: set[bytes] = set()
            while time.time() < deadline:
                conn.select(self.mailbox)
                # Свежие письма от Steam; ищем среди последних, новые вперёд.
                typ, data = conn.search(None, "FROM", "steampowered.com")
                ids = data[0].split() if data and data[0] else []
                for msg_id in reversed(ids):
                    if msg_id in seen_ids:
                        continue
                    seen_ids.add(msg_id)
                    typ, msg_data = conn.fetch(msg_id, "(RFC822)")
                    if typ != "OK" or not msg_data or not msg_data[0]:
                        continue
                    raw = msg_data[0][1]
                    code = extract_steam_code(raw)
                    if code:
                        return code
                time.sleep(poll_interval)
        finally:
            try:
                conn.logout()
            except Exception:
                pass
        raise SteamMafileError(
            "Код Steam Guard не пришёл на почту за отведённое время"
        )
