#!/usr/bin/env just --justfile

set shell := ["bash", "-c"]

default: build

build:
    odin build . -out:zoomdin

run: build
    ./zoomdin
