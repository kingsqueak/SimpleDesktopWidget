# SimpleDesktopWidget

A desktop widget for macOS: a big bold clock, a three-day forecast (Windy or Open-Meteo) and today's calendar events, sitting on the desktop with a drop shadow.

Personal, local-use app. macOS 15 or later.

## Build and install

```
./build.sh            # builds build/SimpleDesktopWidget.app
./build.sh install    # also copies it to ~/Applications and (re)starts it
```

The script signs with the local "Apple Development" identity when there is one, so the Calendar, Location and Screen Recording permissions survive rebuilds.

## Using it

- A clock icon in the menu bar (and right-click on the widget) has **Configure Widget…**, **Refresh Now** and **Quit**.
- While configuring, the widget floats above other windows with a dashed outline: drag it where you want it. **Done** locks it in place and drops it back to the desktop.
- The widget sits just above the desktop icons and below every normal window, on all Spaces.

### Settings

- **Appearance:** font (any installed family), clock and text weight, text and background colours, background opacity, whole-display opacity, drop-shadow strength, size.
- **Frosted glass:** the card shows a blurred copy of the wallpaper behind it, so desktop icons under the widget are covered instead of showing through. It captures only the system wallpaper window (never icons or other windows) and needs Screen Recording permission.
- **Clock:** 12/24-hour, seconds, date.
- **Weather:** Windy Point Forecast API (needs an API key from api.windy.com/keys; the free "testing" key returns scrambled data) or Open-Meteo (free, no key). Location by search, current location, or saved coordinates. Refreshes every 30 minutes.
- **Calendar:** which calendars to show, hide finished events, how many to list.
- **Start at login.**

Settings live in `defaults read com.kingsqueak.SimpleDesktopWidget`.
