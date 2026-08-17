# Homebrew formula for stm.
#
# Local install:  brew install --formula ./Formula/sketchybar-theme-manager.rb
# From a tap:     brew install noomz/tap/sketchybar-theme-manager
class SketchybarThemeManager < Formula
  desc "Theme manager for SketchyBar"
  homepage "https://github.com/noomz/sketchybar-theme-manager"
  url "https://github.com/noomz/sketchybar-theme-manager/archive/refs/tags/v0.2.0.tar.gz"
  sha256 "12f73eee39cd1c8637f325f271091eab1d33c92825773ab442f6f6e14c558bfa"
  license "MIT"
  head "https://github.com/noomz/sketchybar-theme-manager.git", branch: "main"

  depends_on :macos

  def install
    bin.install "bin/stm"

    # bin/stm resolves its bundled palettes by walking up from the *resolved*
    # location of the script: it looks for ../palettes, then ../share/stm/palettes,
    # then the two Homebrew prefixes. Installing to share/"stm/palettes" satisfies
    # both the ../share/stm/palettes probe (relative to the Cellar bin/) and the
    # absolute /opt/homebrew/share/stm/palettes probe (via the linked prefix).
    (share/"stm/palettes").install Dir["palettes/*.toml"]
  end

  def caveats
    <<~EOS
      stm writes colors_generated.lua (Lua configs) or rewrites colors.sh in
      place (Bash configs). For Lua, wire it into your own colors.lua with:

          local ok, generated = pcall(require, "colors_generated")
          if ok and type(generated) == "table" then
            for k, v in pairs(generated) do defaults[k] = v end
          end

      Then run:  stm list && stm apply catppuccin-mocha

      Or adopt an existing bar in one step:  stm adopt && stm apply nord
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/stm version")

    # The bundled palettes must be findable from the installed location.
    listing = shell_output("#{bin}/stm list --porcelain")
    assert_match "tokyo-night", listing

    preview = shell_output("#{bin}/stm preview --porcelain tokyo-night")
    assert_match "0xff1a1b26", preview

    # Applying against a scratch Lua config must produce a loadable module and
    # must not touch the user's own colors.lua.
    (testpath/"cfg").mkpath
    (testpath/"cfg/colors.lua").write("return {}\n")
    system bin/"stm", "--dir", testpath/"cfg", "--no-reload", "apply", "nord"
    assert_predicate testpath/"cfg/colors_generated.lua", :exist?
    assert_match "0xff2e3440", (testpath/"cfg/colors_generated.lua").read
    assert_equal "return {}\n", (testpath/"cfg/colors.lua").read
  end
end
