# Homebrew cask for Coda.
#
# This is the CANONICAL copy. It lives here (in the public source repo) so the
# cask is versioned alongside the code. `scripts/release.sh` rewrites the
# `version`/`sha256` lines below, then copies this file into the PUBLIC tap repo
# (IsaacArnold/homebrew-coda) at Casks/coda.rb, which is what `brew tap` clones.
#
# Colleagues install with (no GitHub auth — tap + release are public):
#   brew tap isaacarnold/coda
#   brew trust isaacarnold/coda    # one-time; Homebrew 6+ gates non-official taps
#   brew install --cask coda
# and update later with (no re-trust needed):
#   brew upgrade --cask coda
cask "coda" do
  version "0.1.12"
  sha256 "810eafc917e76aaaf4ea18d4df9ddb89671f9b4455847795bcc1d41bf6be12ec"

  url "https://github.com/IsaacArnold/coda/releases/download/v#{version}/Coda-#{version}.dmg",
      verified: "github.com/IsaacArnold/coda/"
  name "Coda"
  desc "Native macOS terminal workspace for running Claude Code across git worktrees"
  homepage "https://github.com/IsaacArnold/coda"

  depends_on macos: :ventura

  app "Coda.app"

  # `brew uninstall --cask coda` removes the app. `--zap` additionally clears
  # these. Note: Coda also stores config + git worktrees under ~/.coda; that is
  # deliberately NOT trashed here, because ~/.coda/worktrees can hold checked-out
  # branches with uncommitted work. Remove ~/.coda by hand if you really mean to.
  zap trash: [
    "~/Library/Preferences/net.branchoutonline.coda.plist",
    "~/Library/Saved Application State/net.branchoutonline.coda.savedState",
  ]
end
