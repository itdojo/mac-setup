# mac-setup

Rebuild a Mac the way the course did: one script, every change recorded and reversible.

This is the take-home version of the tool that set up the machines in class. It installs a working development environment, meaning a shell, a terminal, editors, fonts, command-line tools, and the applications the course used. Then it writes down everything it did, so you can read the list later and undo any part of it.

You do not need to have been in the class, and you do not need to remember anything about it.

## Before you start

**Apple Silicon only.** M1 or later. Homebrew installs to a different place on Intel Macs, and rather than guess, this refuses to run.

**macOS 26 or newer, and 30 GB of free disk.** It checks both before installing anything. If either fails it tells you what to fix, which beats finding out halfway through.

**About 4.2 GB of downloads.** Measured 2026-09-09 on macOS 26.5.2, Apple Silicon: 4.16 GB, almost all of it Homebrew fetching applications and command-line tools. Docker Desktop alone is most of a gigabyte. Your number will drift as versions move, and roughly three quarters of it is the applications, so if you already have Chrome or VS Code or Obsidian, expect less.

**It stops for you twice.** Once for your name and email, which go into your Git config. Once to add an SSH key to your GitHub account, which needs a browser and takes a paste. It also asks for your password once, early, because installing applications requires it.

Set aside half an hour, most of it waiting.

## Install it

```bash
curl -fLO https://raw.githubusercontent.com/itdojo/mac-setup/main/bootstrap.sh
less bootstrap.sh
bash bootstrap.sh
```

**The middle line is not decoration.** It is the point. HTTPS proves the file came from GitHub. It says nothing at all about whether the bytes are worth running. So read it. It is a shell script with comments, written to be read, and if something in it looks wrong to you, do not run it. That is the correct outcome, and it is the whole reason you get the file instead of piping it into your shell.

For the same reason nothing here is ever `curl | bash`. Every later download is checked against a SHA-256 published beside it before anything is unpacked or run. A tool whose whole claim is that nothing is hidden cannot begin by asking you to run code you were given no chance to read.

Press `q` to leave `less`.

## What it installs

Nine Nerd Fonts, twenty command-line tools including `bat`, `eza`, `fzf`, `gh`, `git`, `go`, `jq`, `node`, `ripgrep`, `rust`, `tmux`, `uv`, `vim` and `zoxide`, and sixteen applications: Ghostty, Chrome, Obsidian, Signal, ChatGPT, Claude, Cursor, VS Code, Antigravity as both CLI and IDE, VLC, Rectangle, KeepingYouAwake, Docker Desktop, and the Claude Code and Codex command-line agents.

The two agents are installed and nothing more. Signing in to either happens in a browser against an account only you have, so the tool does not try, does not wait for you, and does not count it against the run. `claude` and `codex` will be on your PATH; logging in is your errand, whenever you want them.

Docker Desktop asks for Rosetta the first time it starts on an Apple Silicon Mac. The tool does not install it, because nothing here runs `softwareupdate` and one recommendation is a thin reason to teach it how. If Docker asks, or if you would rather it never had to:

```bash
softwareupdate --install-rosetta
```

Then it configures them. Zsh with Starship. Ghostty with a terminal theme. Real config files for `vim`, `nano` and `tmux` rather than defaults. A handful of macOS settings: where screenshots go, key-repeat speed, a plain black desktop, and a Dock with seven tiles plus your Applications folder on the right, drawn as a folder and opening as a grid. Whatever you already had on that side of the Dock stays where it is. It creates `~/vaults`, `~/projects` and `~/docker`, with `vlt`, `prj` and `dkr` to jump to them. It sets up your Git identity and a GitHub SSH key, and adds two SSH defaults: `IdentitiesOnly yes`, so a server that counts failed attempts is not offered every key you own, and `SetEnv TERM=xterm-256color`, because Ghostty calls itself `xterm-ghostty` and most servers have never heard of it.

## What it writes down

Everything lands in `~/.student-setup/`.

**`receipt.html`** is what this run changed, as a page you open in a browser. Every package, every file, every setting.

**`manual.html`** is what each piece is and why it is there. This is the part worth reading six months from now, when you have forgotten what `zoxide` was for.

**`ledger.jsonl`** is the machine-readable record, one line per change. It is what makes the undo commands work.

**`backups/`** holds the original of every file that got replaced.

The tool itself unpacks to `~/student-setup`. Note the missing dot: `~/.student-setup` is the record above, `~/student-setup` is the tool. Run it from the second one.

## Check it worked

```bash
cd ~/student-setup && uv run student-setup verify --profile profiles/takehome-core.toml
```

This re-runs every check and fixes nothing. It prints one line per check, then a count: `N checks, all passed — ready for labs.`, or how many failed. Run it whenever you like, not only after installing. It is how you find out what has drifted since.

## Undo it

Reverse one piece:

```bash
uv run student-setup remove dock
```

Reverse all of it:

```bash
uv run student-setup restore
```

`restore` puts the machine back, using the backups it took on the way in. It keeps the Ledger, the Receipt and the Manual on purpose. A record you lose when you undo something is not a record.

Module names are whatever the Receipt calls them: `fonts`, `formulae`, `casks`, `terminal`, `editors`, `dock`, `macos-defaults`, `git-identity`, `ssh-github`, and the rest.

## See what it would do first

```bash
bash bootstrap.sh --no-run
```

That unpacks the tool and stops, printing the command it would have run. Then:

```bash
cd ~/student-setup && uv run student-setup plan
```

`plan` prints everything a run would do and does none of it. If you want to know exactly what you are agreeing to before you agree to it, this is how.

`--yes` skips the confirmation prompt, for when you already know. `bash bootstrap.sh --help` lists the rest.

## If it stops

Run it again. The bootstrap script and the tool are both idempotent, so a second run duplicates nothing and picks up where the last one left off. If a run was interrupted, `uv run student-setup resume` continues it.
