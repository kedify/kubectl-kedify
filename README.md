# kubectl-kedify plugin

Simple TUI based shell script for installing and interfacing with Kedify.


[![Watch the full asciicast](./demo.gif)](https://asciinema.org/a/668253)
([pauseable demo](https://asciinema.org/a/668253))

## Quick start

Having krew [installed](https://krew.sigs.k8s.io/docs/user-guide/setup/install/), just run:

```bash
kubectl krew install --manifest-url=https://github.com/kedify/kubectl-kedify/raw/main/.krew.yaml
```

```bash
# output:
Installing plugin: kedify
Installed plugin: kedify
\
 | Use this plugin:
 | 	kubectl kedify
 | Documentation:
 | 	https://github.com/kedify/kubectl-kedify
/
```
### Usage

```bash
k kedify --version
```

### Update

```
kubectl kedify -v
kubectl krew uninstall kedify && kubectl krew install --manifest-url=https://github.com/kedify/kubectl-kedify/raw/main/.krew.yaml
kubectl kedify -v
```

### Requirements

This plugin requires couple of binaries to work properly. `kubecolor` is optional, but recommended.

Mac:
```bash
brew install bat curl figlet fzf kubecolor yq jq
```

Linux:

```bash
yum install bat curl figlet fzf jq
```

or

```bash
apt-get install bat curl figlet fzf jq
```

and for `yq` consult the [readme](https://github.com/mikefarah/yq#install).

## Development and Testing

### Local Testing

This project includes a cross-platform test script that automatically detects and validates all bash scripts.

```bash
# Run default tests (full on Mac/Linux, smoke on others)
./test-cross-platform.sh

# Run smoke tests only (basic syntax, function loading - works on all platforms)
./test-cross-platform.sh smoke

# Run full tests (includes shellcheck, platform-specific features - Mac/Linux only)
./test-cross-platform.sh full
```

### Running as kubectl plugin vs locally

The script automatically detects whether it's running as a kubectl plugin (via krew) or locally in development:

- **As kubectl plugin**: Uses scripts from the krew store (`~/.krew/store/kedify/`)
- **Locally**: Uses scripts from the project directory

This allows for seamless development and testing of unreleased features.
