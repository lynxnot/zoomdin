# zoomdin

## Setup

Clone the repository with submodules:

```sh
git clone --recurse-submodules https://github.com/lynxnot/zoomdin.git
cd zoomdin
```

If you've already cloned without submodules, initialize them:

```sh
git submodule update --init --recursive
```

## Building and Running

This project uses [Just](https://github.com/casey/just) for task automation.

- `just build` — compile the project
- `just run` — build and run the application
