# Template for Casks/velvet.rb in subhashhhhhh/homebrew-velvet. scripts/release.sh
# fills in version and sha256 in the tap's copy on each release.
cask "velvet" do
  arch arm: "AppleSilicon", intel: "Intel"

  version "1.0"
  sha256 arm:   "0000000000000000000000000000000000000000000000000000000000000000",
         intel: "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/subhashhhhhh/Velvet/releases/download/v#{version}/Velvet-#{version}-#{arch}.dmg"
  name "Velvet"
  desc "Native, low-memory YouTube client"
  homepage "https://github.com/subhashhhhhh/Velvet"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sequoia

  app "Velvet.app"

  # Velvet isn't notarized; clearing the flag spares Homebrew users the Gatekeeper prompt.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Velvet.app"]
  end

  uninstall quit: "com.subhash.Velvet"

  zap trash: [
    "~/Library/Application Support/Velvet",
    "~/Library/Application Support/com.subhash.Velvet",
    "~/Library/Caches/com.subhash.Velvet",
    "~/Library/Caches/VelvetUpdate",
    "~/Library/HTTPStorages/com.subhash.Velvet",
    "~/Library/Preferences/com.subhash.Velvet.plist",
    "~/Library/Saved Application State/com.subhash.Velvet.savedState",
  ]
end
