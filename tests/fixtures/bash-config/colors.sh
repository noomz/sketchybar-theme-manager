#!/usr/bin/env bash
# Fixture: a typical colors.sh. stm rewrites the values in place and must
# preserve indentation, quoting style, trailing comments and unrelated vars.

# --- core palette ---------------------------------------------------------
export BLACK=0xff181926
export WHITE=0xffcad3f5
export RED=0xffed8796            # accent red
export GREEN=0xffa6da95
export BLUE="0xff8aadf4"
export YELLOW=0xffeed49f
export ORANGE=0xfff5a97f
export MAGENTA=0xffc6a0f6
export GREY=0xff939ab7

# --- surfaces -------------------------------------------------------------
export BG1=0xff24273a
  export BG2=0xff363a4f          # indented on purpose
export BAR_BG=0x0024273a
export BAR_BORDER=0xff494d64
export POPUP_BG=0xc024273a
export POPUP_BORDER=0xff939ab7

# --- user extras that stm must NOT touch ---------------------------------
export ACCENT=0xffb7bdf8
export TRANSPARENT=0x00000000
export ICON_FONT="Hack Nerd Font:Bold:16.0"
export BAR_HEIGHT=40

# --- hazards --------------------------------------------------------------
# 10 hex digits: NOT a valid 0xAARRGGBB literal. A naive regex that matches the
# first 8 digits would corrupt this into "<new>44". Must be left byte-identical.
export LONGHEX=0xff11223344
# A palette key spelled in lower case is not a shell colour var; leave it.
export black=0xdeadbeef
# Same key twice — a real-world config smell. Both occurrences get rewritten.
export WHITE=0xffcad3f5
