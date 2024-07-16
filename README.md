# kubectl-kedify plugin

Simple TUI based shell script for installing and interfacing with Kedify.


[![Watch the full asciicast](./demo.gif)](https://asciinema.org/a/668253)
([pauseable demo](https://asciinema.org/a/668253))

## Quick start

Having krew [installed](https://krew.sigs.k8s.io/docs/user-guide/setup/install/), just run:

```bash
kubectl krew install --manifest-url=https://github.com/jkremser/kubectl-kedify/raw/main/.krew.yaml
```

```bash
# output:
Installing plugin: kedify
Installed plugin: kedify
\
 | Use this plugin:
 | 	kubectl kedify
 | Documentation:
 | 	https://github.com/jkremser/kubectl-kedify
/
```
### Usage

```bash
k kedify --version
```

### Requirements

This plugin requires couple of binaries to work properly.

Mac:
```bash
brew install bat curl figlet fzf yq jq
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

### Update

```
kubectl kedify -v
kubectl krew uninstall kedify && kubectl krew install --manifest-url=https://github.com/jkremser/kubectl-kedify/raw/main/.krew.yaml
kubectl kedify -v
```
