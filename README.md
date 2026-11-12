# Lantern

A minimal macOS web browser. A single ~900 KB app bundle, no dependencies, no bundled
engine, no background services.

Lantern renders with the WebKit already resident in macOS, It prioritizes low memory usage, native speed, and local privacy without the bloat of background updaters, telemetry daemons, or extension hosts.

## What actually makes it light

**1. No engine of its own.** Rendering is `WKWebView`, i.e. the same Safari engine
already loaded in the OS and shared with every other app. Lantern's own UI process
measures ~30 MB. There is no updater, no telemetry, no extension host, no sync.

**2. Tabs that really sleep.** A background tab idle for 5 minutes has its WebKit
content process *destroyed*, not throttled. What survives is the URL, the title and
`interactionState` — a WebKit blob holding the full back/forward list and scroll
position, a couple of KB. Click the tab and it comes back where you left it. 

Sleeping also happens immediately when macOS reports memory pressure, so Lantern
gives memory back to the system instead of competing for it.

**3. Ad and tracker blocking in the network layer.** 214 domain rules are compiled
once into a WebKit bytecode program that runs inside the networking process, so
blocked requests never reach the renderer at all. This is cheaper *and* stronger
than an extension: no JS, no per-request callback, nothing to run per page. Verified
with `tools/run-blocktest.sh`.

**4. A new tab costs nothing.** The new-tab page is drawn with AppKit, so an empty
tab allocates no web process. Restoring a session is lazy too — a 20-tab window
comes back with exactly one live renderer.

Autoplay is off, which removes most background CPU and video decode memory.

### Compare it against your own browser

```sh
./tools/kmem                 # Lantern, Chrome and Safari side by side, right now
./tools/bench.sh             # the full comparison above, reproduced
```

Heavy sites cost what they cost — that is the page, not the browser. The win is
that you only pay for the tab you are actually looking at.

## Install

### Download the built app

Grab `Lantern.zip` from [Releases](../../releases), unzip, and drag `Lantern.app`
to `/Applications`.

Lantern is ad-hoc signed and **not notarized by Apple**, so the first launch needs
one extra step — macOS quarantines anything downloaded from the internet:

```sh
xattr -dr com.apple.quarantine /Applications/Lantern.app
open /Applications/Lantern.app
```

(Or right-click the app → **Open** → **Open** in the dialog.) Without this you get
*"Lantern is damaged"* or *"Apple could not verify..."* — that is Gatekeeper, not a
broken build. Notarizing would require a paid Apple Developer account.

### Or build it yourself

```sh
./build.sh /Applications      # compile, bundle, ad-hoc sign, install
open /Applications/Lantern.app
```

Requires only the Xcode Command Line Tools. Build takes a few seconds, and a
locally built app needs no quarantine step.

To make it your default browser: **Lantern → Make Lantern the Default Browser**.

## Keyboard

| | |
|---|---|
| `⌘L` | address bar (history/bookmark autocomplete, no network suggestions) |
| `⌘T` / `⌘W` | new tab / close tab |
| `⌘⇧T` | reopen the tab you just closed |
| `⌘N` / `⌘⇧N` | new window / new private window |
| `^⇥` / `^⇧⇥` | next / previous tab (also `⌘⌥←` / `⌘⌥→`) |
| `⌘1`–`⌘9` | jump to tab |
| `⌘[` / `⌘]` | back / forward (or two-finger swipe) |
| `⌘R` / `⌘.` | reload / stop |
| `⌘F` / `⌘G` / `⌘⇧G` | find, find next, find previous |
| `⌘D` | bookmark |
| `⌘+` / `⌘-` / `⌘0` | zoom |
| `⌘⇧H` | put all background tabs to sleep now |
| `⌘⇧J` | open Downloads folder |
| `⌘,` | settings |

**Mouse.** Middle-click or ⌘-click a link opens it in a background tab.
Middle-click a tab closes it. **Drag a tab** to reorder it. **Right-click a tab** for
reload, duplicate, copy address, put-to-sleep, close and close-others. Double-click
empty space in the tab strip for a new tab. Right-click a page → Inspect Element
opens Web Inspector.

Tabs shrink to fit however many you have open, so the last tab and the `+` button
stay reachable instead of sliding off the edge of the window.

Sleeping tabs are dimmed in the strip and say so in their tooltip, so a tab
reloading when you return to it is never a surprise. The pill on the right of the
toolbar is live total memory across every Lantern process, plus how many tabs are
currently asleep — hover it for the per-process breakdown.

## Configuration

`~/Library/Application Support/Lantern/config.json` — edited with `⌘,`, applied on
restart.

| key | default | |
|---|---|---|
| `searchTemplate` | Google | `%s` is the query; e.g. `https://duckduckgo.com/?q=%s` |
| `hibernateAfterMinutes` | `5` | `0` disables sleeping |
| `hibernateOnMemoryPressure` | `true` | sleep everything when macOS says it is low |
| `blockAdsAndTrackers` | `true` | also the shield button in the toolbar |
| `restoreSessionOnLaunch` | `true` | |
| `showMemoryReadout` | `true` | |
| `enableDeveloperTools` | `true` | |

Same folder holds `blocked-domains.txt` (one domain per line, `#` comments — add
your own and restart), `history.json`, `bookmarks.json` and `session.json`. All
plain files; nothing is a database.

## Layout

| | |
|---|---|
| `Sources/Tab.swift` | tab model, hibernate/wake, WebKit delegates |
| `Sources/BrowserWindowController.swift` | window , tab switching, timers |
| `Sources/ContentBlocker.swift` | domain list → compiled WebKit rule list |
| `Sources/MemoryMonitor.swift` | per-process footprint, Activity-Monitor-style attribution |
| `Sources/TabStrip.swift` | hand-drawn tab strip, tab context menu |
| `Sources/Controls.swift` | toolbar buttons, address bar, status pill |
| `Sources/StartView.swift` | native new-tab page |
| `Sources/Store.swift` | history, bookmarks, session (flat JSON) |
| `tools/run-blocktest.sh` | functional test: are trackers actually blocked? |
| `tools/kmem` | footprint of Lantern / Chrome / Safari, right now |
| `tools/bench.sh` | the full Chrome comparison, reproducible |
| `tools/bench-table.py` | turns raw results into the table above |
| `tools/waitwindow.swift` | cold-launch timing via the window server |

## Known limits

- **Not a new engine.** Site compatibility is Safari's. The rare site that only
  works in Chrome will not work here.
- **No extension support.** Ad blocking is built in; anything else is not available.
- **Multi-window sessions**: only the last window to close is restored.
- **Not notarized** (ad-hoc signed, built locally). Gatekeeper may ask on first
  launch; right-click → Open.
- Cosmetic ad rules are deliberately conservative, so some blocked slots leave a gap.

## Credits

Lantern is a fork of [Kestrel](https://github.com/bishosilwal/kestrel-browser), a
minimal, low-memory macOS browser on system WebKit by Bisho Silwal. The original
project is MIT licensed, and that license carries over to this fork.

## License

MIT — see [LICENSE](LICENSE).
