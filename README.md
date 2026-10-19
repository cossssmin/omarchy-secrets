# Secrets

Omarchy plugin for keeping env secrets (API keys, tokens, database URLs) encrypted in your own private git repo, with a floating window to search, copy and edit them.

![Secrets window](preview.png)

Every `project/env` pair is a dotenv file encrypted with [age](https://github.com/FiloSottile/age), so the repo only ever holds ciphertext. You unlock once with a passphrase, and every change is committed and pushed for you.

## Features

- Secrets grouped by `project/env`, e.g. `acme-api/production`
- Search across envs and key names as you type
- Copy a value, a key name, or the whole `KEY=value` line
- Add, edit, rename and delete, all from the keyboard if you like
- Paste `MY_VAR=1234` (or `export MY_VAR="1234"`) into the key field and it's split into name and value for you
- Deleting always asks for confirmation first
- Stays unlocked until you lock it or reboot, or for as long as you configure
- Every change is a git commit, pushed to your remote in the background
- A `secrets` CLI that does everything the window does, plus `secrets run` to start a command with an env loaded

## Requirements

- `age` - not installed by default: `omarchy pkg add age`
- `keyctl` (keyutils), `jq`, `git`, `wl-clipboard` and `script` (util-linux), which a stock Omarchy install already has

## Install

```sh
omarchy plugin add https://github.com/cossssmin/omarchy-secrets.git --enable
```

The lock icon appears in the bar's right section. Click it to open the window.

The window is a regular window rather than a bar popup, so clicking elsewhere doesn't close it. Hyprland would tile it though, so float it with a rule in `~/.config/hypr/hyprland.lua`:

```lua
o.window({ class = "^org.quickshell$", title = "^Secrets$" }, { float = true, center = true, size = { 460, 560 } })
```

To open it with a key, bind the toggle in `~/.config/hypr/bindings.lua`. For example, `SUPER + SHIFT + S`, which is Google Maps on a stock install:

```lua
hl.unbind("SUPER + SHIFT + S")
o.bind("SUPER + SHIFT + S", "Secrets", "omarchy-shell -q shell toggle cossssmin.secrets")
```

For the CLI, link it somewhere on your `PATH`:

```sh
ln -s ~/.config/omarchy/plugins/cossssmin.secrets/bin/secrets ~/.local/bin/secrets
```

## Setup

Open the window and pick a passphrase. That creates:

- your age identity, passphrase-protected, at `~/.config/secrets/identity.age`
- the secrets repo at `~/.local/share/secrets`, with your public key in `.age-recipients`

There's no way to recover the passphrase, so keep it somewhere safe.

Then point the repo at a **private** GitHub repo and push it once:

```sh
git -C ~/.local/share/secrets remote add origin git@github.com:you/secrets.git
secrets sync
```

From then on, every change is pushed for you.

Tip: also create an offline backup key. Everything gets re-encrypted to it as well, so a lost passphrase or laptop doesn't mean lost secrets:

```sh
secrets backup-key ~/backup.txt
```

Print it or put it on a USB stick, then delete it from your machine.

## Usage

| Action | Copies |
|--------|--------|
| Click the key name | the name |
| Click the `••••••••` dots, or anywhere else on the row | the value |
| `Enter` | the value |
| `Shift + Enter` | the name |
| `Ctrl + Enter` | the `KEY=value` line |

The pencil on a row edits that key. The pencil on a group header renames the group. The trash icon deletes the key, after you confirm.

### Keyboard

| Key | Action |
|-----|--------|
| `↑` / `↓` | Move the selection |
| `Ctrl + N` | Add a secret |
| `Ctrl + E` or `Insert` | Edit the selected key |
| `Ctrl + D` or `Delete` | Delete the selected key (after you confirm) |
| `F2` | Rename the selected key's group |
| `Tab` / `Shift + Tab` | Move between fields in the editor |
| `Esc` | Leave the editor, rename or dialog, then close the window |

`Delete` only deletes a key when there's nothing for it to delete in the search field, so typing a search never removes anything by accident. The confirm dialog opens with **Cancel** selected, so a reflexive `Enter` doesn't delete either.

### CLI

```sh
secrets status                                 # locked or unlocked
secrets unlock                                 # asks for your passphrase
secrets ls                                     # list envs
secrets keys acme-api/production               # list key names
secrets get acme-api/production STRIPE_KEY     # print a value
secrets set acme-api/production STRIPE_KEY     # prompts for the value
secrets rm acme-api/production STRIPE_KEY      # remove a key (or the whole env, without a KEY)
secrets mv acme-api/staging acme-api/preview   # rename an env
secrets export acme-api/production > .env     # dump an env as dotenv
secrets run acme-api/production -- npm start   # run a command with the env loaded
secrets lock
```

Run `secrets help` for the full list, including `backup-key`, `rotate` and `rekey`.

## Configure

**Repo** - the encrypted files live in `~/.local/share/secrets` by default. To keep them somewhere else, say next to your other projects, set it in `~/.config/secrets/config`:

```sh
SECRETS_DIR=~/Work/secrets
```

Both the window and the CLI read that file, so it's the one place to change it. `SECRETS_IDENTITY` and `SECRETS_TTL` (in seconds) work there too, and environment variables with the same names win over the file.

**Auto-lock** - minutes until an unlock from the window expires. `0` (the default) keeps it unlocked until you lock it or reboot. Set it in the bar's widget settings UI, or in the widget's entry in `~/.config/omarchy/shell.json`:

```json
{ "id": "cossssmin.secrets", "ttlMinutes": 480 }
```

The widget also has a **Secrets repo** setting, which overrides `SECRETS_DIR` for the window. Note that it only applies when you open the window from the bar, not from a keybinding, so the config file is usually the better place.

## How it works

- Each env is a dotenv file, encrypted with age to every public key in `.age-recipients`. Adding or rotating a key re-encrypts everything.
- `unlock` decrypts your identity into the kernel keyring (`keyctl`), never to disk. Locking drops it, and a reboot clears it.
- The window hands passphrases and values to the CLI over stdin, never as command-line arguments where other processes could see them. In a terminal, `secrets set` and `secrets unlock` prompt for them for the same reason.
- Commits are signed if your git config signs commits, and pushed in the background. If a push fails (say, you're offline), the header shows how many commits are waiting and the sync button retries.

Note that while it's unlocked, **any process running as you can decrypt your secrets**, including scripts and AI agents. Lock it when that matters.

A few more things to know:

- Copied values end up in Omarchy's clipboard history like anything else you copy.
- Values are single-line, so multi-line values like PEM keys aren't supported yet.
- Commit messages include env names, like `update acme-api/production`, but never keys or values.

## Remove

```sh
omarchy plugin remove cossssmin.secrets
```

Then delete the float rule and keybinding from your Hyprland config, and the CLI link if you made one. Your repo and identity stay where they are; delete `~/.local/share/secrets` (or your `SECRETS_DIR`) and `~/.config/secrets` too if you're done with them.

## License

MIT
