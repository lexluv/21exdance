class SteamMafileError(Exception):
    """Базовая ошибка привязки аутентификатора."""


class LoginError(SteamMafileError):
    """Не удалось выполнить вход (неверный пароль, ошибка Guard-кода и т.п.)."""


class RateLimitError(LoginError):
    """Steam временно ограничил попытки входа для этого аккаунта/IP."""


class AddAuthenticatorError(SteamMafileError):
    """AddAuthenticator/FinalizeAddAuthenticator вернул ошибку."""
