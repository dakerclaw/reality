"""Telegram bot for managing reality-ezpz users.

The bot runs inside the `tgbot` container that reality-ezpz.sh generates, and
that container bind-mounts the whole reality-ezpz directory at /opt/reality-ezpz.
The local copy of the installer script is therefore used directly instead of
re-downloading it from GitHub for every single command (the previous behaviour,
which was also the reason the bot stopped working entirely while offline).

The image pins python-telegram-bot 13.x, so the synchronous Updater/Dispatcher
API is used on purpose.
"""

import html
import io
import os
import re
import subprocess
import sys
from functools import wraps

import qrcode
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    CallbackQueryHandler,
    CommandHandler,
    Filters,
    MessageHandler,
    Updater,
)

REALITY_PATH = os.environ.get('REALITY_PATH', '/opt/reality-ezpz')
LOCAL_SCRIPT = os.path.join(REALITY_PATH, 'reality-ezpz.sh')
SCRIPT_CACHE = '/tmp/reality-ezpz.sh'
# Download fallback only: used when the script is not bind-mounted into the
# container. It points at this project's own repository, and can be overridden
# to self-host through REALITY_SCRIPT_URL.
REMOTE_SCRIPT = os.environ.get(
    'REALITY_SCRIPT_URL',
    'https://raw.githubusercontent.com/dakerclaw/reality/main/reality-ezpz.sh',
)

BOT_TOKEN = os.environ.get('BOT_TOKEN', '').strip()
BOT_ADMINS = {
    name.strip().lstrip('@')
    for name in os.environ.get('BOT_ADMIN', '').split(',')
    if name.strip()
}

USERNAME_RE = re.compile(r'^[a-zA-Z0-9]+$')
# Same filter the previous shell pipeline used to pick configuration lines out
# of the `--show-user` output.
CONFIG_LINE_RE = re.compile(r'://|^\{"dns"')
IPV6_RE = re.compile(r'"server":"[0-9a-fA-F:]+"')

COMMAND_TIMEOUT = 300
TELEGRAM_CAPTION_LIMIT = 1024


class EzpzError(RuntimeError):
    """reality-ezpz.sh exited with a non-zero status."""


def resolve_script():
    """Return the script to execute, downloading it once if it is not mounted."""
    if os.path.isfile(LOCAL_SCRIPT):
        return LOCAL_SCRIPT
    if not os.path.isfile(SCRIPT_CACHE):
        try:
            subprocess.run(
                ['curl', '-fsSL', '-m', '30', REMOTE_SCRIPT, '-o', SCRIPT_CACHE],
                check=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except (OSError, subprocess.CalledProcessError):
            raise EzpzError(
                'reality-ezpz.sh is neither mounted nor downloadable, '
                'check the container volumes and network'
            )
    return SCRIPT_CACHE


def run_ezpz(*arguments):
    """Run reality-ezpz.sh and return its stdout.

    The arguments are passed as an argv list and never interpolated into a shell
    string, so a username coming from a callback button can not inject commands.
    """
    try:
        result = subprocess.run(
            ['/bin/bash', resolve_script(), *arguments],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            errors='replace',
            timeout=COMMAND_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        raise EzpzError(f'reality-ezpz.sh timed out after {COMMAND_TIMEOUT}s')
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or '').strip().splitlines()
        raise EzpzError(detail[-1] if detail else f'exit status {result.returncode}')
    return result.stdout


def get_users():
    """Return the existing usernames, ignoring unrelated banner output."""
    users = []
    for line in run_ezpz('--list-users').splitlines():
        line = line.strip()
        if USERNAME_RE.match(line):
            users.append(line)
    return users


def get_configs(username):
    """Return the client configuration strings printed by `--show-user`."""
    configs = []
    for line in run_ezpz('--show-user', username).splitlines():
        line = line.strip()
        if CONFIG_LINE_RE.search(line):
            configs.append(line)
    return configs


def add_user_ezpz(username):
    run_ezpz('--add-user', username)


def delete_user_ezpz(username):
    run_ezpz('--delete-user', username)


def is_ipv6_config(config):
    return config.endswith('-ipv6') or bool(IPV6_RE.search(config))


def send_menu(context, chat_id, text, keyboard):
    context.bot.send_message(
        chat_id=chat_id, text=text, reply_markup=InlineKeyboardMarkup(keyboard)
    )


def send_config(context, chat_id, config, username, reply_markup):
    """Send one client configuration as a QR code plus its textual form."""
    label = f'IPv6 config for "{username}"' if is_ipv6_config(config) else f'Config for "{username}"'
    image = io.BytesIO()
    qrcode.make(config).save(image, 'PNG')
    image.seek(0)
    # <pre> keeps the string copyable and html.escape stops the '&' and '<'
    # characters inside the URI from breaking Telegram's HTML parser.
    caption = f'{label}:\n<pre>{html.escape(config)}</pre>'
    if len(caption) <= TELEGRAM_CAPTION_LIMIT:
        context.bot.send_photo(
            chat_id=chat_id,
            photo=image,
            caption=caption,
            parse_mode='HTML',
            reply_markup=reply_markup,
        )
        return
    # The shadowtls configuration is a JSON document, far longer than the 1024
    # character caption limit, so the photo and the text are sent separately.
    context.bot.send_photo(
        chat_id=chat_id, photo=image, caption=label, reply_markup=reply_markup
    )
    context.bot.send_message(
        chat_id=chat_id, text=f'<pre>{html.escape(config)}</pre>', parse_mode='HTML'
    )


def restricted(handler):
    """Reject non-admins and turn command failures into readable messages."""

    @wraps(handler)
    def wrapper(update, context, *args, **kwargs):
        chat = update.effective_chat
        message = update.effective_message
        if chat is None or message is None:
            return None
        if message.chat.username not in BOT_ADMINS:
            context.bot.send_message(
                chat_id=chat.id, text='You are not authorized to use this bot.'
            )
            return None
        try:
            return handler(update, context, *args, **kwargs)
        except EzpzError as error:
            context.bot.send_message(
                chat_id=chat.id, text=f'reality-ezpz failed: {error}'
            )
        except Exception as error:  # noqa: BLE001 - a bad command must not stop polling
            context.bot.send_message(chat_id=chat.id, text=f'Unexpected error: {error}')
        return None

    return wrapper


@restricted
def start(update, context):
    keyboard = [
        [InlineKeyboardButton('Show User', callback_data='show_user')],
        [InlineKeyboardButton('Add User', callback_data='add_user')],
        [InlineKeyboardButton('Delete User', callback_data='delete_user')],
    ]
    send_menu(
        context,
        update.effective_chat.id,
        'Reality-EZPZ User Management Bot\n\nChoose an option:',
        keyboard,
    )


@restricted
def users_list(update, context, text, callback):
    keyboard = [
        [InlineKeyboardButton(user, callback_data=f'{callback}!{user}')]
        for user in get_users()
    ]
    keyboard.append([InlineKeyboardButton('Back', callback_data='start')])
    send_menu(context, update.effective_chat.id, text, keyboard)


@restricted
def show_user(update, context, username):
    chat_id = update.effective_chat.id
    configs = get_configs(username)
    if not configs:
        send_menu(
            context,
            chat_id,
            f'No configuration found for "{username}".',
            [[InlineKeyboardButton('Back', callback_data='start')]],
        )
        return
    reply_markup = InlineKeyboardMarkup(
        [[InlineKeyboardButton('Back', callback_data='show_user')]]
    )
    for config in configs:
        send_config(context, chat_id, config, username, reply_markup)


@restricted
def delete_user(update, context, username):
    chat_id = update.effective_chat.id
    if len(get_users()) == 1:
        send_menu(
            context,
            chat_id,
            'You cannot delete the only user.\nAt least one user is needed.\n'
            'Create a new user, then delete this one.',
            [[InlineKeyboardButton('Back', callback_data='start')]],
        )
        return
    send_menu(
        context,
        chat_id,
        f'Are you sure to delete "{username}"?',
        [
            [InlineKeyboardButton('Delete', callback_data=f'approve_delete!{username}')],
            [InlineKeyboardButton('Cancel', callback_data='delete_user')],
        ],
    )


@restricted
def add_user(update, context):
    context.user_data['expected_input'] = 'username'
    send_menu(
        context,
        update.effective_chat.id,
        'Enter the username:',
        [[InlineKeyboardButton('Cancel', callback_data='cancel')]],
    )


@restricted
def approve_delete(update, context, username):
    delete_user_ezpz(username)
    send_menu(
        context,
        update.effective_chat.id,
        f'User {username} has been deleted.',
        [[InlineKeyboardButton('Back', callback_data='start')]],
    )


@restricted
def cancel(update, context):
    context.user_data.pop('expected_input', None)
    start(update, context)


@restricted
def button(update, context):
    query = update.callback_query
    try:
        query.answer()
    except Exception:  # noqa: BLE001 - expired callback queries are harmless
        pass
    action, _, argument = query.data.partition('!')
    if not argument:
        if action == 'start':
            start(update, context)
        elif action == 'cancel':
            cancel(update, context)
        elif action == 'show_user':
            users_list(update, context, 'Select user to view config:', 'show_user')
        elif action == 'delete_user':
            users_list(update, context, 'Select user to delete:', 'delete_user')
        elif action == 'add_user':
            add_user(update, context)
        else:
            context.bot.send_message(
                chat_id=update.effective_chat.id, text=f'Button pressed: {action}'
            )
        return
    if action == 'show_user':
        show_user(update, context, argument)
    elif action == 'delete_user':
        delete_user(update, context, argument)
    elif action == 'approve_delete':
        approve_delete(update, context, argument)


@restricted
def user_input(update, context):
    if context.user_data.pop('expected_input', None) != 'username':
        return
    username = (update.message.text or '').strip()
    if not USERNAME_RE.match(username):
        update.message.reply_text(
            'Username can only contains A-Z, a-z and 0-9, try another username.'
        )
        add_user(update, context)
        return
    if username in get_users():
        update.message.reply_text(f'User "{username}" exists, try another username.')
        add_user(update, context)
        return
    add_user_ezpz(username)
    update.message.reply_text(f'User "{username}" is created.')
    show_user(update, context, username)


def main():
    if not BOT_TOKEN:
        print('BOT_TOKEN environment variable is not set.', file=sys.stderr)
        return 1
    if not BOT_ADMINS:
        print('BOT_ADMIN environment variable is not set.', file=sys.stderr)
        return 1
    updater = Updater(BOT_TOKEN, use_context=True)
    dispatcher = updater.dispatcher
    dispatcher.add_handler(CommandHandler('start', start))
    dispatcher.add_handler(CallbackQueryHandler(button))
    dispatcher.add_handler(MessageHandler(Filters.text & ~Filters.command, user_input))
    # Drop updates queued while the container was down instead of replaying them.
    updater.start_polling(drop_pending_updates=True)
    updater.idle()
    return 0


if __name__ == '__main__':
    sys.exit(main())
