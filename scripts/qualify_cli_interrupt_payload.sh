#!/bin/sh
set -eu
exec env MIX_ENV=test mix run scripts/qualify_cli_interrupt.exs
