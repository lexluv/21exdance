"""Интерактивный CLI: логин+пароль -> код с почты -> готовый .maFile.

Запуск:  python -m steam_mafile [--out DIR] [--login ИМЯ]
"""

import argparse
import getpass
import sys

from .client import (
    GUARD_DEVICE_CODE, GUARD_DEVICE_CONFIRMATION, GUARD_EMAIL_CODE,
    SteamAuthClient,
)
from .errors import SteamMafileError
from .mafile import build_mafile, save_mafile


def _prompt(text: str) -> str:
    try:
        return input(text).strip()
    except EOFError:
        raise SteamMafileError("Ввод прерван")


def bind_account(login: str | None, out_dir: str) -> str:
    login = login or _prompt("Логin Steam: ")
    if not login:
        raise SteamMafileError("Логин не задан")
    password = getpass.getpass("Пароль (не отображается): ")
    if not password:
        raise SteamMafileError("Пароль не задан")

    client = SteamAuthClient(login)
    print("Синхронизирую время со Steam...")
    client.sync_time()

    print("Выполняю вход...")
    confirmations = client.begin_login(password)

    if GUARD_EMAIL_CODE in confirmations:
        code = _prompt("Введите код Steam Guard из письма на почте: ")
        client.submit_email_code(code, GUARD_EMAIL_CODE)
    elif GUARD_DEVICE_CODE in confirmations or GUARD_DEVICE_CONFIRMATION in confirmations:
        raise SteamMafileError(
            "На аккаунте уже включён мобильный аутентификатор. "
            "Повторная привязка возможна только после его отвязки "
            "(нужен revocation code от текущего)."
        )
    # если подтверждений нет — Steam Guard выключен, продолжаем сразу

    print("Получаю сессионные токены...")
    client.poll_for_tokens()

    print("Привязываю мобильный аутентификатор...")
    add_result = client.add_authenticator()

    # Сохраняем ДО финализации — чтобы secret и revocation code не потерялись,
    # даже если код активации введён с ошибкой.
    mafile = build_mafile(add_result, client.steamid,
                          client.refresh_token, client.access_token)
    mafile["fully_enrolled"] = False
    tmp_path = save_mafile(mafile, out_dir)

    print()
    print("=" * 60)
    print("  REVOCATION CODE (сохрани обязательно!): "
          f"{add_result['revocation_code']}")
    print("=" * 60)
    hint = add_result.get("phone_number_hint")
    if hint:
        print(f"  Код активации отправлен по SMS на телефон ***{hint}")
    print(f"  Черновик maFile: {tmp_path}")
    print()

    activation_code = _prompt("Введите код активации (SMS/почта): ")
    print("Завершаю привязку...")
    client.finalize_authenticator(add_result["shared_secret"], activation_code)

    mafile["fully_enrolled"] = True
    mafile["status"] = 1
    path = save_mafile(mafile, out_dir)
    print(f"Готово. maFile сохранён: {path}")
    print(f"Revocation code: {add_result['revocation_code']}")
    return path


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="Автопривязка Steam Guard и создание .maFile"
    )
    parser.add_argument("--login", help="имя аккаунта Steam")
    parser.add_argument("--out", default="maFiles",
                        help="каталог для .maFile (по умолчанию ./maFiles)")
    args = parser.parse_args(argv)
    try:
        bind_account(args.login, args.out)
        return 0
    except SteamMafileError as e:
        print(f"Ошибка: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nПрервано пользователем", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
