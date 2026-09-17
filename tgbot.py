"""Telegram bot for managing reality users.

The bot runs inside the `tgbot` container that reality.sh generates, and
that container bind-mounts the whole reality directory at /opt/reality.
The local copy of the installer script is therefore used directly instead of
re-downloading it from GitHub for every single command (the previous behaviour,
which was also the reason the bot stopped working entirely while offline).

The image pins python-telegram-bot 22.x, so the asyncio API is used throughout:
`Application` plus `async def` handlers. Nothing may block the event loop,
because reality.sh legitimately runs for minutes (compose restarts, certificate
work ...), so every call into it goes through asyncio.create_subprocess_exec
rather than subprocess.run.

BOT_ADMIN lists the people allowed to drive the bot, as Telegram usernames or as
numeric user ids; see parse_admins and is_admin.
"""

import asyncio
import html
import io
import os
import re
import sys
from functools import wraps

import qrcode
from telegram import InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import (
    Application,
    CallbackQueryHandler,
    CommandHandler,
    MessageHandler,
    filters,
)

REALITY_PATH = os.environ.get('REALITY_PATH', '/opt/reality')
LOCAL_SCRIPT = os.path.join(REALITY_PATH, 'reality.sh')
SCRIPT_CACHE = '/tmp/reality.sh'
# Download fallback only: used when the script is not bind-mounted into the
# container. It points at this project's own repository, and can be overridden
# to self-host through REALITY_SCRIPT_URL.
REMOTE_SCRIPT = os.environ.get(
    'REALITY_SCRIPT_URL',
    'https://raw.githubusercontent.com/dakerclaw/reality/main/reality.sh',
)

BOT_TOKEN = os.environ.get('BOT_TOKEN', '').strip()

# Every BOT_ADMIN entry is either a Telegram username (@name) or the numeric id
# of the account (123456789). The numeric form is the only way to authorise an
# account that never picked a username, and unlike a username it can neither be
# renamed nor recycled by somebody else.
# Same upper bound the installer's regex uses. The installer also demands four
# digits there, but that is a typo guard for interactive input, so anything the
# config file happens to hold is still honoured here.
NATIVE_ID_RE = re.compile(r'^[0-9]{1,15}$')


def parse_admins(raw):
    """Split the BOT_ADMIN list into (usernames, numeric ids).

    Usernames are lowercased on purpose: Telegram echoes a username back exactly
    as its owner typed it, so a list holding `DakerJie` would otherwise never
    match the configured `dakerjie`.
    """
    usernames = set()
    ids = set()
    for entry in raw.split(','):
        entry = entry.strip().lstrip('@').strip()
        if not entry:
            continue
        if NATIVE_ID_RE.match(entry):
            ids.add(int(entry))
        else:
            usernames.add(entry.lower())
    return usernames, ids


BOT_ADMINS, BOT_ADMIN_IDS = parse_admins(os.environ.get('BOT_ADMIN', ''))

USERNAME_RE = re.compile(r'^[a-zA-Z0-9]+$')
# Same filter the previous shell pipeline used to pick configuration lines out
# of the `--show-user` output.
CONFIG_LINE_RE = re.compile(r'://|^\{"dns"')
IPV6_RE = re.compile(r'"server":"[0-9a-fA-F:]+"')

COMMAND_TIMEOUT = 300
TELEGRAM_CAPTION_LIMIT = 1024


class RealityError(RuntimeError):
    """reality.sh exited with a non-zero status."""


def decode_output(raw):
    """Decode a byte stream produced by a child process.

    Decoding never raises: reality.sh is allowed to print anything, including
    bytes that are not valid UTF-8, and a mangled log line must not take the
    bot down.
    """
    return (raw or b'').decode('utf-8', errors='replace')


async def resolve_script():
    """Return the script to execute, downloading it once if it is not mounted."""
    if os.path.isfile(LOCAL_SCRIPT):
        return LOCAL_SCRIPT
    if not os.path.isfile(SCRIPT_CACHE):
        try:
            process = await asyncio.create_subprocess_exec(
                'curl', '-fsSL', '-m', '30', REMOTE_SCRIPT, '-o', SCRIPT_CACHE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
            )
        except OSError:  # curl itself is missing from the image
            raise RealityError(
                'reality.sh is neither mounted nor downloadable, '
                'check the container volumes and network'
            )
        await process.communicate()
        if process.returncode != 0:
            raise RealityError(
                'reality.sh is neither mounted nor downloadable, '
                'check the container volumes and network'
            )
    return SCRIPT_CACHE


async def run_reality(*arguments, timeout=COMMAND_TIMEOUT):
    """Run reality.sh and return its stdout.

    The arguments are passed as an argv list and never interpolated into a shell
    string, so a username coming from a callback button can not inject commands.
    The call is awaited, never blocking the event loop: a single slow
    `--delete-user` must not freeze the bot for every other admin.
    """
    script = await resolve_script()
    process = await asyncio.create_subprocess_exec(
        '/bin/bash', script, *arguments,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    try:
        stdout, stderr = await asyncio.wait_for(process.communicate(), timeout)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        raise RealityError(f'reality.sh timed out after {timeout}s')
    if process.returncode != 0:
        detail = decode_output(stderr or stdout).strip().splitlines()
        raise RealityError(detail[-1] if detail else f'exit status {process.returncode}')
    return decode_output(stdout)


async def get_users():
    """Return the existing usernames, ignoring unrelated banner output."""
    users = []
    for line in (await run_reality('--list-users')).splitlines():
        line = line.strip()
        if USERNAME_RE.match(line):
            users.append(line)
    return users


async def get_configs(username):
    """Return the client configuration strings printed by `--show-user`."""
    configs = []
    for line in (await run_reality('--show-user', username)).splitlines():
        line = line.strip()
        if CONFIG_LINE_RE.search(line):
            configs.append(line)
    return configs


async def add_user_via_script(username):
    await run_reality('--add-user', username)


async def delete_user_via_script(username):
    await run_reality('--delete-user', username)


def is_ipv6_config(config):
    return config.endswith('-ipv6') or bool(IPV6_RE.search(config))


def render_qr(config):
    """Render `config` as a PNG QR code and rewind the buffer.

    Pure CPU work, so it is pushed onto a worker thread by send_config instead
    of stalling the event loop.
    """
    image = io.BytesIO()
    qrcode.make(config).save(image, 'PNG')
    image.seek(0)
    return image


async def send_menu(context, chat_id, text, keyboard):
    await context.bot.send_message(
        chat_id=chat_id, text=text, reply_markup=InlineKeyboardMarkup(keyboard)
    )


async def send_config(context, chat_id, config, username, reply_markup):
    """Send one client configuration as a QR code plus its textual form."""
    label = f'IPv6 config for "{username}"' if is_ipv6_config(config) else f'Config for "{username}"'
    image = await asyncio.to_thread(render_qr, config)
    # <pre> keeps the string copyable and html.escape stops the '&' and '<'
    # characters inside the URI from breaking Telegram's HTML parser.
    caption = f'{label}:\n<pre>{html.escape(config)}</pre>'
    if len(caption) <= TELEGRAM_CAPTION_LIMIT:
        await context.bot.send_photo(
            chat_id=chat_id,
            photo=image,
            caption=caption,
            parse_mode='HTML',
            reply_markup=reply_markup,
        )
        return
    # The shadowtls configuration is a JSON document, far longer than the 1024
    # character caption limit, so the photo and the text are sent separately.
    await context.bot.send_photo(
        chat_id=chat_id, photo=image, caption=label, reply_markup=reply_markup
    )
    await context.bot.send_message(
        chat_id=chat_id, text=f'<pre>{html.escape(config)}</pre>', parse_mode='HTML'
    )


def is_admin(chat):
    """True when the chat belongs to an authorised admin.

    Both forms are compared: the numeric id first, then the username. A private
    chat is the only place where `chat.id` is the user id and `chat.username` is
    the user's own name, which is what makes the id lookup -- and therefore an
    admin without a username -- work at all.
    """
    if chat is None:
        return False
    if chat.id in BOT_ADMIN_IDS:
        return True
    username = (chat.username or '').lower()
    return bool(username) and username in BOT_ADMINS


def restricted(handler):
    """Reject non-admins and turn command failures into readable messages.

    Handlers are coroutines in python-telegram-bot 22.x, so this wrapper is one
    too and awaits the handler it guards.
    """

    @wraps(handler)
    async def wrapper(update, context, *args, **kwargs):
        chat = update.effective_chat
        message = update.effective_message
        if chat is None or message is None:
            return None
        if not is_admin(chat):
            await context.bot.send_message(
                chat_id=chat.id, text='You are not authorized to use this bot.'
            )
            return None
        try:
            return await handler(update, context, *args, **kwargs)
        except RealityError as error:
            await context.bot.send_message(
                chat_id=chat.id, text=f'reality failed: {error}'
            )
        except Exception as error:  # noqa: BLE001 - a bad command must not stop polling
            await context.bot.send_message(chat_id=chat.id, text=f'Unexpected error: {error}')
        return None

    return wrapper


@restricted
async def start(update, context):
    keyboard = [
        [InlineKeyboardButton('Show User', callback_data='show_user')],
        [InlineKeyboardButton('Add User', callback_data='add_user')],
        [InlineKeyboardButton('Delete User', callback_data='delete_user')],
    ]
    await send_menu(
        context,
        update.effective_chat.id,
        'Reality User Management Bot\n\nChoose an option:',
        keyboard,
    )


@restricted
async def users_list(update, context, text, callback):
    keyboard = [
        [InlineKeyboardButton(user, callback_data=f'{callback}!{user}')]
        for user in await get_users()
    ]
    keyboard.append([InlineKeyboardButton('Back', callback_data='start')])
    await send_menu(context, update.effective_chat.id, text, keyboard)


@restricted
async def show_user(update, context, username):
    chat_id = update.effective_chat.id
    configs = await get_configs(username)
    if not configs:
        await send_menu(
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
        await send_config(context, chat_id, config, username, reply_markup)


@restricted
async def delete_user(update, context, username):
    chat_id = update.effective_chat.id
    if len(await get_users()) == 1:
        await send_menu(
            context,
            chat_id,
            'You cannot delete the only user.\nAt least one user is needed.\n'
            'Create a new user, then delete this one.',
            [[InlineKeyboardButton('Back', callback_data='start')]],
        )
        return
    await send_menu(
        context,
        chat_id,
        f'Are you sure to delete "{username}"?',
        [
            [InlineKeyboardButton('Delete', callback_data=f'approve_delete!{username}')],
            [InlineKeyboardButton('Cancel', callback_data='delete_user')],
        ],
    )


@restricted
async def add_user(update, context):
    context.user_data['expected_input'] = 'username'
    await send_menu(
        context,
        update.effective_chat.id,
        'Enter the username:',
        [[InlineKeyboardButton('Cancel', callback_data='cancel')]],
    )


@restricted
async def approve_delete(update, context, username):
    await delete_user_via_script(username)
    await send_menu(
        context,
        update.effective_chat.id,
        f'User {username} has been deleted.',
        [[InlineKeyboardButton('Back', callback_data='start')]],
    )


@restricted
async def cancel(update, context):
    context.user_data.pop('expected_input', None)
    await start(update, context)


@restricted
async def button(update, context):
    query = update.callback_query
    try:
        await query.answer()
    except Exception:  # noqa: BLE001 - expired callback queries are harmless
        pass
    action, _, argument = query.data.partition('!')
    if not argument:
        if action == 'start':
            await start(update, context)
        elif action == 'cancel':
            await cancel(update, context)
        elif action == 'show_user':
            await users_list(update, context, 'Select user to view config:', 'show_user')
        elif action == 'delete_user':
            await users_list(update, context, 'Select user to delete:', 'delete_user')
        elif action == 'add_user':
            await add_user(update, context)
        else:
            await context.bot.send_message(
                chat_id=update.effective_chat.id, text=f'Button pressed: {action}'
            )
        return
    if action == 'show_user':
        await show_user(update, context, argument)
    elif action == 'delete_user':
        await delete_user(update, context, argument)
    elif action == 'approve_delete':
        await approve_delete(update, context, argument)


@restricted
async def user_input(update, context):
    if context.user_data.pop('expected_input', None) != 'username':
        return
    username = (update.message.text or '').strip()
    if not USERNAME_RE.match(username):
        await update.message.reply_text(
            'Username can only contains A-Z, a-z and 0-9, try another username.'
        )
        await add_user(update, context)
        return
    if username in await get_users():
        await update.message.reply_text(f'User "{username}" exists, try another username.')
        await add_user(update, context)
        return
    await add_user_via_script(username)
    await update.message.reply_text(f'User "{username}" is created.')
    await show_user(update, context, username)


def main():
    if not BOT_TOKEN:
        print('BOT_TOKEN environment variable is not set.', file=sys.stderr)
        return 1
    if not BOT_ADMINS and not BOT_ADMIN_IDS:
        print('BOT_ADMIN environment variable is not set.', file=sys.stderr)
        return 1
    application = Application.builder().token(BOT_TOKEN).build()
    application.add_handler(CommandHandler('start', start))
    application.add_handler(CallbackQueryHandler(button))
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, user_input))
    # Drop updates queued while the container was down instead of replaying them.
    # run_polling() blocks: it installs the signal handlers and owns the loop.
    application.run_polling(drop_pending_updates=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
