# tmpfs-symlink

Two scripts used to either set up TMPFS, or set up symlinked practice maps for MCSR on linux.

- **tmpfs.sh** - Symlink instance saves into a tmpfs RAM disk for faster resets
- **symlink.sh** - Symlink practice maps into instance saves folders (no tmpfs needed)
> [!NOTE]
> Only use tmpfs.sh if you have RAM to spare while resetting (not at 70-80%+ usage).

> [!WARNING]
> # A.7.8.a) If SeedQueue is used and 5 previous world files must be sent, all world files generated after the run must also be submitted. 

> [!NOTE]
> If you are on Nixos, instead check out an example setup of TMPFS from [my flake](https://github.com/flammablebunny/flake/blob/8f3dbf4ce35629ca68bfb43210b8eadb7fd3790e/hosts/pc/default.nix#L127)

## Download

```bash
curl -Lo ~/Downloads/tmpfs.sh https://raw.githubusercontent.com/flammablebunny/tmpfs-symlink/main/tmpfs.sh
curl -Lo ~/Downloads/symlink.sh https://raw.githubusercontent.com/flammablebunny/tmpfs-symlink/main/symlink.sh
chmod +x ~/Downloads/tmpfs.sh ~/Downloads/symlink.sh
```

## Usage

Edit the variables at the top of each script, then:

```bash
# tmpfs.sh - full TMPFS setup
./tmpfs.sh setup    # mount tmpfs, link instances, install services
./tmpfs.sh status   # check current state
./tmpfs.sh teardown # undo everything

# symlink.sh - just practice maps
./symlink.sh link   # symlink maps into all instances
./symlink.sh status # check current state
./symlink.sh unlink # remove symlinks
```

Run `./tmpfs.sh help` or `./symlink.sh help` for all commands.
