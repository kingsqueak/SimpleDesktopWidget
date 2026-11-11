# SimpleDesktopWidget

A desktop widget for macOS: a big bold clock, a three-day forecast (Open-Meteo) and today's calendar events, sitting on the desktop with a drop shadow.

Personal, local-use app. macOS 15 or later.

## Build and install

```
./build.sh            # builds build/SimpleDesktopWidget.app
./build.sh install    # also copies it to ~/Applications and (re)starts it
```

The script signs with the local "Apple Development" identity when there is one, so the Calendar, Location, Screen Recording and Finder automation permissions survive rebuilds.

## Using it

- A clock icon in the menu bar (and right-click on the widget) has **Configure Widget…**, **Refresh Now** and **Quit**.
- While configuring, the widget floats above other windows and snaps to the screen edges (its top can go right up to the menu bar) with a dashed outline: drag it where you want it. **Done** locks it in place and drops it back to the desktop.
- The widget sits just above the desktop icons and below every normal window, on all Spaces.

### Settings

- **Appearance:** font (any installed family), clock and text weight, text and background colours, background opacity, whole-display opacity, text outline (halo, automatically dark for light text and light for dark text), drop-shadow strength, size.
- **Frosted glass:** the card shows a blurred copy of the wallpaper behind it, so desktop icons under the widget are covered instead of showing through. It captures only the system wallpaper window (never icons or other windows) and needs Screen Recording permission.
- **Keep icons clear:** Finder is scripted to move any desktop icon under the widget to the nearest free spot (when the widget is placed or resized, when something lands on the Desktop, when a disk mounts). Needs Automation permission for Finder and Finder's desktop "Sort By" set to None.
- **Clock:** 12/24-hour, seconds, date.
- **Weather:** Open-Meteo (free, no key). Location by search, current location, or saved coordinates. Refreshes every 30 minutes.
- **Alerts:** active National Weather Service warnings, watches and advisories for the location (api.weather.gov, US only, checked every 5 minutes), as coloured banners above the forecast.
- **Lightning:** live strikes from the Blitzortung.org volunteer network within a chosen radius (default 25 mi) over the last 30 minutes: nearest distance and direction, count, how long ago; red within 10 mi. The widget receives the worldwide strike stream and filters locally, so no location is sent. Free for personal use, no guarantees, not for safety decisions.
- **Calendar:** which calendars to show, hide finished events, how many to list.
- **Start at login.**

Settings live in `defaults read com.kingsqueak.SimpleDesktopWidget`.
