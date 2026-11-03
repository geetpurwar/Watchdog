# Watchdog

Menu bar dot that tells you whether this Mac is about to freeze.

- **Green**: memory, swap and disk have room.
- **Orange**: warning. Kernel memory pressure warning, swapping out at 20 MB/s or more, swap above 4 GB, disk under 15 GB or under 5%, or memory used above 93%.
- **Red**: danger. Kernel memory pressure urgent or critical, swapping out at 100 MB/s or more, swap up 1 GB in two minutes, swap above 8 GB, or disk under 6 GB or under 1.5%. Pause or quit something.

Click the dot for details, every Claude Code session with what it and its tools use, and the biggest processes. A session can be paused, resumed or quit from its submenu.

## Auto mode

On by default (menu toggle, stored as `autoMode`). When the dot has been red for two readings **because of memory** (kernel pressure, swapping, swap growth or memory used; never the disk alone, and not the static swap level, which paused sessions can never bring down), Watchdog pauses the heaviest Claude Code session together with everything it spawned, and notifies you. While it stays red it pauses the next heaviest every 30 s. Once memory has been calm for a minute (no red memory signal, no swapping, no swap growth; a kernel warning, the lingering swap level and the disk are ignored) it resumes them one at a time, most recently paused first, 30 s apart. If red returns, resuming stops and pausing starts again. The list of paused sessions is saved, so a restart of Watchdog still resumes them.

Pausing stops the session's parent shell first and resumes it last. Verified on zsh: a plain stop makes the shell take the terminal back and the resumed job then dies or re-stops on its next keyboard read; with the shell frozen alongside, the job carries on in the foreground as if nothing happened. "Resume every session Watchdog paused" and the per-session Resume undo it by hand.

Every reading is written to `~/Library/Logs/Watchdog/samples.csv` (one row every 10 s, including swap-out speed and disk write speed/latency) and level changes to `events.log`. While the colour is orange or red every row is forced to the flash (F_FULLFSYNC), so the minutes before a freeze survive a forced power-off. A raw binary run outside the bundle logs to `$TMPDIR/WatchdogDev` instead, or to `$WATCHDOG_LOG_DIR`.

## Build and install

    scripts/build_app.sh --install

Installs `/Applications/Watchdog.app` and a LaunchAgent (`com.geetpurwar.watchdog`, RunAtLoad + KeepAlive) so it starts at login and restarts if it dies.

## Check from the terminal

    /Applications/Watchdog.app/Contents/MacOS/Watchdog --status

## Tune the limits

    defaults write com.geetpurwar.watchdog swapOrangeGB 3

Keys: swapOrangeGB, swapRedGB, swapOutOrangeMBps, swapOutRedMBps, swapGrowthRedGB, diskOrangeGB, diskRedGB, diskOrangePercent, diskRedPercent, usedOrangePercent, loadOrangePerCore (0 = load never changes the colour). Restart the app after changing them.

## Test the colours without starving the Mac

    WATCHDOG_FAKE_PRESSURE=2 .build/release/Watchdog   # orange
    WATCHDOG_FAKE_PRESSURE=4 .build/release/Watchdog   # red
